import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 形状 / 文字作品的磁盘契约。Linux 用假图片，不代替 Apple 再导出像素。
final class ShapeWorkPersistenceTests: XCTestCase {
    func testPhotoFingerprintAndV1LayoutStayUnchanged() throws {
        let photo = sampleLayout(["a", "b", "c"])
        XCTAssertNil(photo.shapeManifest)
        XCTAssertTrue(photo.canPersistShape)
        XCTAssertTrue(WorkFingerprint.of(photo).hasPrefix("s2-"))
        let data = try JSONEncoder().encode(photo)
        let back = try JSONDecoder().decode(MosaicLayout.self, from: data)
        XCTAssertEqual(back.formatVersion, 1)
        XCTAssertNil(back.shapeManifest)
        XCTAssertNil(back.shapeFrame)
        XCTAssertEqual(WorkFingerprint.of(back), WorkFingerprint.of(photo))
    }

    func testShapeAndTextRoundTripFreezeTheMaskAndNullOutsideCells() throws {
        let shape = try persistedLayout(source: .preset(.heart), background: .black)
        let shapeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shape)) as? [String: Any]
        XCTAssertEqual(shapeJSON?["formatVersion"] as? Int, 2)
        XCTAssertEqual(shapeJSON?["mode"] as? String, "shape")
        XCTAssertEqual((shapeJSON?["mask"] as? [String: Any])?["encoding"] as? String, "bits-v1")
        let shapeCells = try XCTUnwrap(shapeJSON?["cells"] as? [Any])
        XCTAssertTrue(shapeCells[1] is NSNull)
        let shapeBack = try JSONDecoder().decode(MosaicLayout.self, from: JSONEncoder().encode(shape))
        XCTAssertEqual(shapeBack.shapeManifest, shape.shapeManifest)
        XCTAssertEqual(shapeBack.shapeFrame?.mask, shape.shapeManifest?.mask)
        XCTAssertEqual(shapeBack.cellAssignments[1].localIdentifier, "")
        XCTAssertTrue(WorkFingerprint.of(shape).hasPrefix("sh1-"))
        XCTAssertNotEqual(WorkFingerprint.of(shape), WorkFingerprint.of(sampleLayout(["in", ""])))

        var text = try persistedLayout(source: .text(lines: ["生日快乐", "宝贝"]), background: .white)
        text.params.density = "fine"
        let textJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(text)) as? [String: Any]
        XCTAssertEqual(textJSON?["mode"] as? String, "text")
        XCTAssertEqual(WorkFingerprint.of(text), WorkFingerprint.of(text))
        var recolored = text
        recolored.shapeManifest = ShapeManifest(spec: ShapeSpec(source: .text(lines: ["生日快乐", "宝贝"]),
                                                                palette: .blue, background: .white),
                                                mask: try XCTUnwrap(text.shapeManifest).mask)
        XCTAssertNotEqual(WorkFingerprint.of(text), WorkFingerprint.of(recolored))
    }

    func testDiskSaveReloadsInAFreshStoreAndRejectsFillOrABadMask() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images)
        let layout = try persistedLayout(source: .text(lines: ["LOVE"]), background: .black)
        let first = try await store.save(WorkDraft(layout: layout, target: try smallTarget(), overlayAlpha: 0.2,
                                                   origin: .savedManually))
        XCTAssertEqual(first.outcome, .inserted)
        XCTAssertNil(first.summary.meta.targetFile, "不存合成目标图")
        XCTAssertEqual(first.summary.meta.overlayAlpha, 0)
        let again = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0, origin: .savedManually))
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.summary.id, first.summary.id)

        let fresh = FileWorksStore(directory: dir, images: FakeWorkImages())
        let loaded = try await fresh.load(first.summary.id)
        XCTAssertEqual(loaded.layout.shapeManifest, layout.shapeManifest)
        XCTAssertEqual(loaded.layout.shapeFrame?.background, .black)
        XCTAssertEqual(loaded.layout.cellAssignments[0].localIdentifier, "in")
        XCTAssertEqual(loaded.layout.cellAssignments[1].localIdentifier, "")
        XCTAssertNil(loaded.targetURL)

        var otherColor = layout
        otherColor.shapeManifest = ShapeManifest(spec: ShapeSpec(source: .text(lines: ["LOVE"]), palette: .gold, background: .black),
                                                 mask: try XCTUnwrap(layout.shapeManifest).mask)
        let second = try await fresh.save(WorkDraft(layout: otherColor, target: nil, overlayAlpha: 0, origin: .savedManually))
        XCTAssertEqual(second.outcome, .inserted)
        XCTAssertNotEqual(second.summary.id, first.summary.id)

        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var filled = otherColor
        filled.cellAssignments[0].fill = CellColor(r: 1, g: 2, b: 3)
        do {
            _ = try await fresh.save(WorkDraft(layout: filled, target: nil, overlayAlpha: 0, origin: .savedManually))
            XCTFail("fc 仍不能写盘")
        } catch let error as WorksError {
            XCTAssertEqual(error, .unsupportedFilledCells)
        }
        var runtimeOnly = layout
        runtimeOnly.shapeManifest = nil
        do {
            _ = try await fresh.save(WorkDraft(layout: runtimeOnly, target: nil, overlayAlpha: 0, origin: .savedManually))
            XCTFail("只有运行时掩码不能写盘")
        } catch let error as WorksError {
            XCTAssertEqual(error, .unsupportedShapeSave)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), before)

        let broken = try await fresh.load(first.summary.id)
        let layoutURL = dir.appendingPathComponent(broken.id.directoryName).appendingPathComponent("layout.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: layoutURL)) as? [String: Any])
        var mask = try XCTUnwrap(object["mask"] as? [String: Any])
        mask["encoding"] = "bits-v2"
        object["mask"] = mask
        try JSONSerialization.data(withJSONObject: object).write(to: layoutURL)
        do {
            _ = try await fresh.load(broken.id)
            XCTFail("坏掩码不能当成打开成功")
        } catch let error as WorksStoreError {
            XCTAssertEqual(error, .corrupted)
        }
    }

    private func persistedLayout(source: ShapeSource, background: ShapeBackground) throws -> MosaicLayout {
        let mask = try CellMask(columns: 2, rows: 1, bitsV1: [0b0000_0001])
        let manifest = ShapeManifest(spec: ShapeSpec(source: source, palette: .warmRed, background: background), mask: mask)
        return MosaicLayout(cols: 2, rows: 1,
                            cellAssignments: [MosaicLayout.CellAssignment(localIdentifier: "in"),
                                              MosaicLayout.CellAssignment(localIdentifier: "out")],
                            targetSize: .init(width: 8, height: 4),
                            targetCrop: CropRect(x: 0, y: 0, width: 8, height: 4),
                            params: .init(overlayAlpha: 0, density: "fine", seed: 4),
                            shapeFrame: ShapeFrame(background: background, mask: mask),
                            shapeManifest: manifest)
    }
}

@MainActor
final class ShapeWorkRemakeTests: XCTestCase {
    func testSavedShapeRemakeRestoresTextModeAndFineDensity() async {
        let manifest = ShapeManifest(spec: ShapeSpec(source: .text(lines: ["生日快乐", "宝贝"]), palette: .warmRed, background: .white),
                                     mask: try! CellMask(columns: 2, rows: 1, bitsV1: [0b0000_0001]))
        let h = CoordinatorHarness(assets: 4)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.startNewFromWorkTapped(workID: nil, savedShape: manifest, densityName: "coarse")
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertEqual(c.state.flow.shape?.usesText, true)
        XCTAssertEqual(c.state.flow.shape?.textLines, ["生日快乐", "宝贝"])
        XCTAssertEqual(c.state.flow.shape?.palette, .warmRed)
        XCTAssertEqual(c.state.flow.settings.density, .fine, "文字再拼固定细档")
        XCTAssertTrue(c.state.flow.isFreshShapeConfig)
        c.stop()
    }
}
