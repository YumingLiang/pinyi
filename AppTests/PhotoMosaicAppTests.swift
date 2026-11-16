import CoreGraphics
import ImageIO
import Photos
import XCTest
import MosaicCore
import MosaicAppCore
@testable import PhotoMosaic

/// iOS 模拟器上的冒烟测试：注入的内核与参考实现结果一致；适配器的纯映射部分。
/// 逻辑本身（状态机 / 索引 / 计时）由 MosaicAppCoreTests 覆盖（Linux + 模拟器都跑）。
final class PhotoMosaicAppTests: XCTestCase {
    func testInjectedKernelMatchesReference() throws {
        var rng = SplitMix64(seed: 1)
        let rows = (0..<500).map { _ in (0..<12).map { _ in rng.nextUnitFloat() } }
        let lib = try FeatureMatrix(dimension: 12, rows: rows)
        let queries = try FeatureMatrix(dimension: 12, rows: Array(rows.prefix(20)))
        let injected = try KernelProvider.make().topK(queries: queries, candidates: lib, k: 8)
        let reference = try ScalarSIMDKernel().topK(queries: queries, candidates: lib, k: 8)
        XCTAssertEqual(injected.indices, reference.indices)
    }

    func testAssignmentRunsOnDevice() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        var rng = SplitMix64(seed: 2)
        let lib = try FeatureMatrix(dimension: 12, rows: (0..<300).map { _ in (0..<12).map { _ in rng.nextUnitFloat() } })
        let cells = try FeatureMatrix(dimension: 12, rows: (0..<100).map { _ in (0..<12).map { _ in rng.nextUnitFloat() } })
        let a = try GreedyAssigner(kernel: KernelProvider.make()).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertEqual(a.tiles.count, 100)
    }

    func testAuthorizationMapping() {
        XCTAssertEqual(PhotoKitLibrary.map(.notDetermined), .notDetermined)
        XCTAssertEqual(PhotoKitLibrary.map(.restricted), .restricted)
        XCTAssertEqual(PhotoKitLibrary.map(.denied), .denied)
        XCTAssertEqual(PhotoKitLibrary.map(.authorized), .authorized)
        XCTAssertEqual(PhotoKitLibrary.map(.limited), .limited)
    }

    /// 透明像素合成到白底（评审 O2）。
    func testOpaqueSRGBCompositesOnWhite() throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 4, height: 4))
        let img = ctx.makeImage()!
        let pb = try XCTUnwrap(ImagePixels.opaqueSRGB(img))
        let px = pb.rgb(x: 1, y: 1)
        XCTAssertEqual(px.r, 255); XCTAssertEqual(px.g, 255); XCTAssertEqual(px.b, 255)
    }

    /// 本地化：每个逻辑层 key 在 App bundle 里都能查到（不会回落成 key 本身）。
    func testAllKeysLocalizedInBundle() {
        let bundle = Bundle.main   // TEST_HOST = App，main bundle 即 App
        for k in L10nKey.allUsed {
            XCTAssertNotEqual(bundle.localizedString(forKey: k.rawValue, value: "§", table: nil), "§", k.rawValue)
        }
    }

    func testLocalizedLineFormatting() {
        let line = LocalizedLine(.scanProgress, ["1,234", "10,000"])
        XCTAssertTrue(line.localized.contains("1,234"))
        XCTAssertTrue(line.localized.contains("10,000"))
    }

    /// MF-2 / QA B-12：索引目录真的被标记为不进 iCloud/iTunes 备份（读回 resourceValues，而不是只看调用记录）。
    func testIndexDirectoryExcludedFromBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONIndexStore(directory: dir, backupExclusion: FileBackupExclusion())
        try store.prepare()
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    /// B-27：启动时清空 tmp/export。
    func testStaleExportsRemoved() throws {
        let dir = LiveMosaicExporter.exportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("old.jpg").path, contents: Data([1]))
        LiveMosaicExporter(thumbnails: PhotoKitThumbnails()).removeStaleExports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

}
