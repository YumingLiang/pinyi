import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

final class MosaicLayoutTests: XCTestCase {
    private func sample() -> MosaicLayout {
        MosaicLayout(cols: 3, rows: 2,
                     cellAssignments: ["a", "b", "a", "", "c", "b"].map { MosaicLayout.CellAssignment(localIdentifier: $0) },
                     targetSize: .init(width: 300, height: 220),
                     targetCrop: CropRect(x: 0, y: 10, width: 300, height: 200),
                     params: .init(overlayAlpha: 0.2, density: "coarse", seed: 42))
    }

    func testCodableRoundTripIsExact() throws {
        var l = sample()
        l.cellAssignments[4].crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let data = try JSONEncoder().encode(l)
        XCTAssertEqual(try JSONDecoder().decode(MosaicLayout.self, from: data), l)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"formatVersion\":1"))
    }

    func testValidityUniqueIDsAndCellLookup() {
        let l = sample()
        XCTAssertTrue(l.isValid)
        XCTAssertEqual(l.uniqueAssetIDs, ["a", "b", "c"])
        XCTAssertEqual(l.cell(col: 1, row: 1).localIdentifier, "c")
        var bad = l
        bad.cellAssignments.removeLast()
        XCTAssertFalse(bad.isValid)
    }

    func testBadCropRejected() {
        let json = #"{"formatVersion":1,"cols":1,"rows":1,"cells":[{"id":"a","crop":[0,0,1]}],"targetSize":{"width":1,"height":1},"targetCrop":[0,0,1,1],"params":{"overlayAlpha":0,"density":"coarse","seed":1}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(MosaicLayout.self, from: Data(json.utf8)))
    }

    func testFromProductMatchesAssignment() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let idx = PhotoIndex(directory: dir, library: FakePhotoLibrary(assetCount: 300), thumbnails: FakeThumbnails(),
                             backupExclusion: RecordingBackupExclusion(), configuration: smallConfig(batch: 100, concurrency: 16, minRows: 1000))
        await idx.load()
        _ = try await idx.synchronize()
        let snap = try await idx.snapshot(for: .allPhotos)
        let target = try PixelBuffer(width: 160, height: 120, bytes: [UInt8](repeating: 128, count: 160 * 120 * 4))
        let product = try await GenerationRunner().run(target: target, snapshot: snap,
                                                       settings: GenerationSettings(density: .coarse), seed: 7)
        let l = MosaicLayout(product: product, overlayAlpha: 0.1)
        XCTAssertTrue(l.isValid)
        XCTAssertEqual(l.cols, product.generation.layout.columns)
        XCTAssertEqual(l.rows, product.generation.layout.rows)
        XCTAssertEqual(l.cellAssignments.map(\.localIdentifier), product.cellAssetIDs.map { $0 ?? "" }, "每格分配完全一致")
        XCTAssertEqual(l.targetCrop, product.generation.layout.cropRect)
        XCTAssertEqual(l.targetSize, .init(width: 160, height: 120))
        XCTAssertEqual(l.params, .init(overlayAlpha: 0.1, density: "coarse", seed: 7))
        XCTAssertTrue(l.cellAssignments.allSatisfy { $0.crop == MosaicLayout.CellAssignment.fullSquare })
    }
}
