import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import MosaicCore
import MosaicAppCore
@testable import PhotoMosaic

/// 形状从「用形状拼」进入，不选用户目标图。fd3c7f0 上结果页仍出现，但 `AppModel.renderPreview` 和
/// `canExport` 都要求 `coordinator.target`，预览保持空白、导出保持禁用。
/// 这条测试走 AppModel 的生产构造（观察状态、画预览、同一套依赖），材料是合成缩略图。
@MainActor
final class ShapeResultScreenTests: XCTestCase {
    private let tile = (r: UInt8(20), g: UInt8(180), b: UInt8(40))

    func testShapeEntryShowsPreviewAndEnablesExportWithoutUserPhoto() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shape-screen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = SyntheticLibrary(count: 24)
        let thumbs = SolidThumbs(r: tile.r, g: tile.g, b: tile.b)
        var config = PhotoIndex.Configuration()
        config.batchSize = 24
        config.maxConcurrentRequests = 8
        config.minRowsPerCommit = 1
        config.minRowsForTimedCommit = 1
        config.commitDutyFactor = 0
        let dependencies = AppDependencies(
            library: library,
            thumbnails: thumbs,
            indexStore: JSONIndexStore(directory: root.appendingPathComponent("Index", isDirectory: true),
                                       backupExclusion: FileBackupExclusion()),
            clock: SystemClock(),
            lifecycle: QuietLifecycle(),
            preferences: OnboardedPreferences(),
            generator: GenerationRunner.production(pipeline: MosaicPipeline(assigner: GreedyAssigner(kernel: KernelProvider.make())),
                                                   perf: nil),
            exporter: LiveMosaicExporter(thumbnails: thumbs),
            memory: NullMemory(),
            perf: PerfRecorder(),
            indexConfiguration: config,
            initialSeed: 7)
        let model = AppModel(buildFlags: BuildFlags(internalTools: true), dependencies: dependencies,
                             detailThumbnails: PhotoKitThumbnails(),
                             worksDirectory: root.appendingPathComponent("Works", isDirectory: true),
                             lifecycle: AppLifecycle(), relay: ExportSuccessRelay())
        model.coordinator.start()
        await model.coordinator.settle()
        let ready = await waitUntil(model.coordinator.state.indexStatus.hasCompletedInitialScan && model.coordinator.state.indexStatus.available > 0)
        XCTAssertTrue(ready, "合成素材没有扫进索引")

        model.beginShape()
        XCTAssertNotNil(model.flow.shape)
        model.setDensity(.coarse)
        model.flowSend(.next)
        XCTAssertEqual(model.flow.step, .settings)
        await model.coordinator.generateTapped()
        await model.coordinator.settle()

        guard case .result = model.flow.generation.phase else {
            return XCTFail("没有进入结果页 \(model.flow.generation.phase)")
        }
        XCTAssertEqual(model.flow.step, .result)
        XCTAssertNotNil(model.coordinator.product?.shapeFrame)
        XCTAssertNil(model.coordinator.target, "这条路径没有用户目标图")
        XCTAssertFalse(model.allowsWorkSave)
        XCTAssertTrue(model.canExport, "结果已经生成，导出不应因为没有用户目标图而禁用")

        let product = try XCTUnwrap(model.coordinator.product)
        let mask = try XCTUnwrap(product.shapeFrame).mask
        let previewCell = MosaicPreviewRenderer.cellPixels(for: product.generation)
        let shown = await waitUntil(model.resultImage?.width == mask.columns * previewCell)
        let image = try XCTUnwrap(model.resultImage, "结果页没有可显示的预览")
        XCTAssertTrue(shown)
        XCTAssertEqual(image.height, mask.rows * previewCell)
        let previewBytes = try bitmap(image)
        let inside = try XCTUnwrap((0..<mask.cellCount).first { mask.isActive($0) })
        let previewPixel = pixelFromTop(previewBytes, width: image.width, columns: mask.columns, cellPixels: previewCell, index: inside)
        assertNear(previewPixel, tile, tolerance: 24, label: "预览内格")

        model.coordinator.shareTapped()
        await model.coordinator.settle()
        guard case .sharing(let url) = model.coordinator.state.export else {
            return XCTFail("导出没有产出文件 \(model.coordinator.state.export)")
        }
        defer { model.coordinator.shareFinished() }
        let jpeg = try XCTUnwrap(decodeJPEG(url))
        XCTAssertGreaterThan(jpeg.width, 8)
        let exportCell = jpeg.width / mask.columns
        XCTAssertEqual(jpeg.width, mask.columns * exportCell)
        let exportPixel = pixelFromTop(try bitmap(jpeg), width: jpeg.width, columns: mask.columns, cellPixels: exportCell, index: inside)
        assertNear(exportPixel, tile, tolerance: 36, label: "导出内格")
        model.coordinator.stop()
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, seconds: Double = 90) async -> Bool {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func pixelFromTop(_ bytes: [UInt8], width: Int, columns: Int, cellPixels: Int, index: Int) -> (UInt8, UInt8, UInt8) {
        let column = index % columns
        let row = index / columns
        let x = column * cellPixels + cellPixels / 2
        let y = row * cellPixels + cellPixels / 2
        let o = y * width * 4 + x * 4
        guard o >= 0, o + 2 < bytes.count else { return (0, 0, 0) }
        return (bytes[o], bytes[o + 1], bytes[o + 2])
    }

    private func assertNear(_ pixel: (UInt8, UInt8, UInt8), _ expected: (r: UInt8, g: UInt8, b: UInt8), tolerance: Int, label: String) {
        for pair in [(pixel.0, expected.r), (pixel.1, expected.g), (pixel.2, expected.b)] {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), tolerance, "\(label) \(pixel)")
        }
    }

    private func bitmap(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(ok)
        return bytes
    }

    private func decodeJPEG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

private final class SyntheticLibrary: PhotoLibraryClient, @unchecked Sendable {
    private let assets: [AssetMetadata]
    init(count: Int) {
        assets = (0..<count).map {
            AssetMetadata(id: "synth-\($0)", modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                          pixelWidth: 800, pixelHeight: 800)
        }
    }
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() async -> PhotoAuthorization { .authorized }
    func assetCount() async -> Int { assets.count }
    func assetMetadata(in range: Range<Int>) async -> [AssetMetadata] {
        let lo = max(0, range.lowerBound), hi = min(assets.count, range.upperBound)
        return lo < hi ? Array(assets[lo..<hi]) : []
    }
    func albums() async -> [AlbumInfo] { [] }
    func assetIDs(inAlbum albumID: String) async throws -> [String] { [] }
    func addOnlyAuthorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAddOnlyAuthorization() async -> PhotoAuthorization { .authorized }
    func saveImageToLibrary(fileURL: URL) async throws {
        XCTFail("形状界面测试不应写入系统相册")
    }
}

private struct SolidThumbs: ThumbnailProviding {
    var r: UInt8, g: UInt8, b: UInt8
    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
        }
        guard let tile = try? PixelBuffer(width: 8, height: 8, bytes: bytes) else { return .failed }
        return .image(tile)
    }
}

private struct QuietLifecycle: LifecycleEvents {
    func events() -> AsyncStream<LifecycleEvent> { AsyncStream { _ in } }
    @MainActor func beginBackgroundWork(_ work: BackgroundWork) {}
    @MainActor func endBackgroundWork(_ work: BackgroundWork) {}
}

private struct OnboardedPreferences: PreferenceStore {
    func bool(_ key: PreferenceKey) -> Bool { key == .onboardingCompleted }
    func set(_ value: Bool, for key: PreferenceKey) {}
}

private struct NullMemory: MemoryFootprintReading {
    func physFootprintBytes() -> UInt64? { nil }
}
