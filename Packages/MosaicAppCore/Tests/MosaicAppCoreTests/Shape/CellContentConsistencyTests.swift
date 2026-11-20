import XCTest
@testable import MosaicAppCore
import MosaicCore

/// 预览和再导出共用的格子决定，以及 `cd1-` 摘要。不写盘，也不用跳过代替像素。
/// 真实 JPEG 像素在 AppTests，Linux 上跑不到。
final class CellContentConsistencyTests: XCTestCase {
    private let insideFill = CellColor(r: 32, g: 96, b: 160)
    private let outsideFill = CellColor(r: 255, g: 0, b: 0)

    func testDigestSeparatesFillFromAbsenceAndIgnoresOverlayAndMask() throws {
        let plain = sampleLayout(["a", "b", "c"])
        var colored = plain
        colored.cellAssignments[1].fill = insideFill
        var black = plain
        black.cellAssignments[1].fill = CellColor(r: 0, g: 0, b: 0)
        var stronger = plain
        stronger.params.overlayAlpha = 0.3
        var shaped = plain
        shaped.shapeFrame = ShapeFrame(background: .black, mask: try CellMask(columns: plain.cols, rows: plain.rows, allActive: false))

        XCTAssertTrue(WorkContentDigest.of(plain).hasPrefix("cd1-"))
        XCTAssertTrue(WorkContentDigest.isCurrent(WorkContentDigest.of(plain)))
        XCTAssertEqual(WorkContentDigest.of(plain), WorkContentDigest.of(stronger), "强度不在摘要里")
        XCTAssertEqual(WorkContentDigest.of(plain), WorkContentDigest.of(shaped), "掩码不进 cd1，形状外由条带决定")
        XCTAssertNotEqual(WorkContentDigest.of(plain), WorkContentDigest.of(colored))
        XCTAssertNotEqual(WorkContentDigest.of(plain), WorkContentDigest.of(black), "没有 fc 不是黑色 fc")
        XCTAssertEqual(WorkFingerprint.of(plain), WorkFingerprint.of(colored), "旧指纹仍不看 fc，所以保存不能靠它区分")
    }

    func testShapeStripeBeatsFillAndFillBeatsFallback() throws {
        let mask = try CellMask(columns: 2, rows: 2, bitsV1: [0b0000_1101])
        XCTAssertTrue(mask.isActive(0))
        XCTAssertFalse(mask.isActive(1))
        let frame = ShapeFrame(background: .black, mask: mask)
        let cells = [
            MosaicLayout.CellAssignment(localIdentifier: "inside", fill: insideFill),
            MosaicLayout.CellAssignment(localIdentifier: "outside", fill: outsideFill),
            MosaicLayout.CellAssignment(localIdentifier: "keep"),
            MosaicLayout.CellAssignment(localIdentifier: ""),
        ]
        let layout = MosaicLayout(cols: 2, rows: 2, cellAssignments: cells,
                                  targetSize: .init(width: 20, height: 20),
                                  targetCrop: CropRect(x: 0, y: 0, width: 20, height: 20),
                                  params: .init(overlayAlpha: 0.2, density: "coarse", seed: 9),
                                  shapeFrame: frame)
        let steps = ShapeStripExport.steps(columns: 2, rows: 2, cellPixels: 8, shape: frame)
        func paint(_ index: Int, fallback: Bool) throws -> CellPaint {
            let step = try XCTUnwrap(steps.first { $0.index == index })
            return layout.cellPaint(at: index, outsideBackground: step.background, hasFallback: fallback)
        }
        XCTAssertEqual(try paint(0, fallback: true), .fill(insideFill))
        XCTAssertEqual(try paint(1, fallback: true), .shapeBackground(.black))
        XCTAssertEqual(try paint(2, fallback: false), .photo(id: "keep", crop: MosaicLayout.CellAssignment.fullSquare))
        XCTAssertEqual(try paint(2, fallback: true), .fallback)
        XCTAssertEqual(try paint(3, fallback: true), .fallback)
        XCTAssertEqual(try paint(3, fallback: false), .blank)

        var photo = sampleLayout(["a", "", "c"])
        photo.cellAssignments[1].fill = insideFill
        XCTAssertEqual(photo.cellPaint(at: 1, outsideBackground: nil, hasFallback: true), .fill(insideFill))
        XCTAssertEqual(photo.cellPaint(at: 0, outsideBackground: nil, hasFallback: false),
                       .photo(id: "a", crop: MosaicLayout.CellAssignment.fullSquare))
    }

    func testRejectingFillOrShapeLeavesAnEmptyDirectoryAndAnExistingWorkUntouched() async throws {
        let empty = makeTempDir()
        defer { try? FileManager.default.removeItem(at: empty) }
        let fresh = FileWorksStore(directory: empty, images: FakeWorkImages())
        try await rejectBoth(on: fresh, label: "空目录")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileWorksStore(directory: dir, images: FakeWorkImages())
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil,
                                                   overlayAlpha: 0.15, origin: .savedManually))
        XCTAssertEqual(saved.outcome, .inserted)
        let before = try snapshot(dir)
        XCTAssertFalse(before.isEmpty)
        try await rejectBoth(on: store, label: "已有照片作品")
        XCTAssertEqual(try snapshot(dir), before)
        let listed = await store.list()
        XCTAssertEqual(listed.map(\.id), [saved.summary.id])
    }

    private func rejectBoth(on store: FileWorksStore, label: String) async throws {
        var filled = sampleLayout(["a", "b", "c"])
        filled.cellAssignments[1].fill = insideFill
        do {
            _ = try await store.save(WorkDraft(layout: filled, target: nil, overlayAlpha: 0.15, origin: .savedManually))
            XCTFail("\(label) 带 fc 不能写盘")
        } catch let error as WorksError {
            XCTAssertEqual(error, .unsupportedFilledCells)
        }
        var shaped = sampleLayout(["a", "b", "c"])
        shaped.shapeFrame = ShapeFrame(background: .white, mask: try CellMask(columns: shaped.cols, rows: shaped.rows, allActive: true))
        do {
            _ = try await store.save(WorkDraft(layout: shaped, target: nil, overlayAlpha: 0.15, origin: .savedManually))
            XCTFail("\(label) 形状不能写盘")
        } catch let error as WorksError {
            XCTAssertEqual(error, .unsupportedShapeSave)
        }
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let root = directory.path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var out: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let key = url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
            out[key] = try Data(contentsOf: url)
        }
        return out
    }
}
