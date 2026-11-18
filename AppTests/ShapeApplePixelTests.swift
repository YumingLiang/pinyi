import CoreGraphics
import ImageIO
import Photos
import UniformTypeIdentifiers
import XCTest
import MosaicCore
import MosaicAppCore
@testable import PhotoMosaic

/// 模拟器上的真实预览和导出。走 `MosaicPreviewRenderer` 与 `LiveMosaicExporter`。
///
/// 实际执行 28 组，不是 10×5×2＝100。未跑的 72 组是除爱心以外的 9 个形状 × 除蓝以外的 4 个配色 × 黑白。
/// 夹具缩略图是固定的红 220,30,30，用来确认形状内画的是这张图，不是背景，也不是特征色块。
@MainActor
final class ShapeApplePixelTests: XCTestCase {
    private struct PixelCase: Equatable {
        var preset: ShapePresetID
        var palette: ShapePalette
        var background: ShapeBackground
    }

    /// 10 个形状只配蓝、黑白都导出；爱心再补其余 4 个配色的黑白导出。爱心×蓝不重复。
    private static func executedCases() -> [PixelCase] {
        var cases: [PixelCase] = []
        for preset in PresetShapes.registry.map(\.id) {
            for background in [ShapeBackground.white, ShapeBackground.black] {
                cases.append(PixelCase(preset: preset, palette: .blue, background: background))
            }
        }
        for palette in ShapePalette.allCases where palette != .blue {
            for background in [ShapeBackground.white, ShapeBackground.black] {
                cases.append(PixelCase(preset: .heart, palette: palette, background: background))
            }
        }
        return cases
    }

    func testExecutedMatrixIsTwentyEightNotOneHundred() {
        let cases = Self.executedCases()
        XCTAssertEqual(PresetShapes.registry.count * ShapePalette.allCases.count * 2, 100)
        XCTAssertEqual(cases.count, 28)
        XCTAssertEqual(Set(cases).count, 28)
        let whitePalettes = Set(cases.filter { $0.preset == .heart && $0.background == .white }.map(\.palette))
        XCTAssertEqual(whitePalettes, Set(ShapePalette.allCases))
    }

    func testExecutedCasesRenderPhotoInsideAndExport() async throws {
        for item in Self.executedCases() {
            try await check(preset: item.preset, palette: item.palette, background: item.background)
        }
    }

    /// 正对照走作品列表同一个 `ImageIOWorkImages.loadImage`，次数加 1。
    /// 随后 `limitedAccess` 只是内存标记，证明这条路径不会再调用 loadImage。这不是真机 PhotoKit，也不是设备上的旧预览 0 次。
    func testProbePositiveControlThenLimitedFlagDoesNotRead() async throws {
        PreviewReadProbe.reset()
        XCTAssertEqual(PreviewReadProbe.fileReadCount, 0)
        XCTAssertTrue(PreviewReadProbe.positiveControl())
        XCTAssertEqual(PreviewReadProbe.fileReadCount, 1, "正对照必须真的走进 loadImage")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shape-preview-read-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTinyJPEG(to: url)
        let meta = WorkMeta(id: WorkID(), createdAt: Date(), columns: 2, rows: 2, tier: nil, photoCount: 1,
                            missingCount: 0, overlayAlpha: 0, seed: 1, fingerprint: "x", origin: .savedManually,
                            previewFile: "preview.jpg", previewPixelWidth: 2, previewPixelHeight: 2, targetFile: nil)
        let summary = WorkSummary(meta: meta, previewURL: url)
        var state = WorksState()
        state.limitedAccess = true
        let skipped = state.decodePreview(for: summary) { ImageIOWorkImages.loadImage($0, maxPixel: 32) }
        XCTAssertNil(skipped)
        XCTAssertEqual(PreviewReadProbe.fileReadCount, 1, "保护路径没有再读；探针仍接着正对照的 1 次")

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let canConfirm = await PhotoKitExistenceChecker().canConfirmMissing()
        XCTAssertEqual(canConfirm, status == .authorized, "这只是模拟器当前授权，不是隐藏或受限场景")
    }

    private func check(preset: ShapePresetID, palette: ShapePalette, background: ShapeBackground) async throws {
        let product = try await shapeProduct(preset: preset, palette: palette, background: background)
        let mask = try XCTUnwrap(product.shapeFrame).mask
        let outside = try XCTUnwrap((0..<mask.cellCount).first { !mask.isActive($0) })
        let overlay = try solid(width: 32, height: 32, r: 0, g: 255, b: 0)
        let thumbs = CountingThumbs()

        let inside = try XCTUnwrap((0..<mask.cellCount).first { mask.isActive($0) })
        let blocks = try XCTUnwrap(MosaicPreviewRenderer.colorBlocks(product))
        let blockBytes = try bitmap(blocks)
        try assertCell(blockBytes, image: blocks, mask: mask, index: outside, background: background, tolerance: 2,
                       label: "\(preset.rawValue) \(palette) \(background) colorBlocks")
        let blockInside = sample(blockBytes, image: blocks, columns: mask.columns, rows: mask.rows,
                                 cellPixels: blocks.width / mask.columns, index: inside)

        let rendered = await MosaicPreviewRenderer.thumbnails(product, target: overlay, overlayAlpha: 0.3, thumbnails: thumbs)
        let preview = try XCTUnwrap(rendered)
        let previewBytes = try bitmap(preview)
        let cp = MosaicPreviewRenderer.cellPixels(for: product.generation)
        XCTAssertEqual(preview.width, mask.columns * cp)
        try assertCell(previewBytes, image: preview, mask: mask, index: outside, background: background, tolerance: 2,
                       label: "\(preset.rawValue) \(background) preview")
        if background == .black {
            assertNotTinted(previewBytes, image: preview, mask: mask, index: outside, label: "preview overlay")
        }
        try assertFetchesStayInside(thumbs.idsSnapshot(), product: product)
        let previewInside = sample(previewBytes, image: preview, columns: mask.columns, rows: mask.rows, cellPixels: cp, index: inside)
        assertPhotoSwatch(previewInside, tolerance: 12, label: "\(preset.rawValue) \(palette) \(background) preview inside")
        assertNotSame(previewInside, blockInside, label: "预览不是特征色块")

        let request = ExportRequest(product: product, target: overlay, overlayAlpha: 0.3, tier: .share)
        XCTAssertEqual(request.overlayAlpha, 0)
        thumbs.reset()
        let url = try await LiveMosaicExporter(thumbnails: thumbs).export(request) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }
        let jpeg = try XCTUnwrap(decodeJPEG(url))
        let plan = request.plan(availableMemoryBytes: LiveMosaicExporter.availableMemory())
        let jpegBytes = try bitmap(jpeg)
        XCTAssertEqual(jpeg.width, mask.columns * plan.cellPixels)
        try assertCell(jpegBytes, image: jpeg, mask: mask, index: outside, background: background, tolerance: 18,
                       label: "\(preset.rawValue) \(background) export")
        if background == .black {
            assertNotTinted(jpegBytes, image: jpeg, mask: mask, index: outside, label: "export overlay")
        }
        try assertFetchesStayInside(thumbs.idsSnapshot(), product: product)
        let exportInside = sample(jpegBytes, image: jpeg, columns: mask.columns, rows: mask.rows,
                                  cellPixels: plan.cellPixels, index: inside)
        assertPhotoSwatch(exportInside, tolerance: 28, label: "\(preset.rawValue) \(palette) \(background) export inside")
        if background == .black {
            let previewOutside = sample(previewBytes, image: preview, columns: mask.columns, rows: mask.rows, cellPixels: cp, index: outside)
            let exportOutside = sample(jpegBytes, image: jpeg, columns: mask.columns, rows: mask.rows,
                                       cellPixels: plan.cellPixels, index: outside)
            for pair in [(previewOutside.0, exportOutside.0), (previewOutside.1, exportOutside.1), (previewOutside.2, exportOutside.2)] {
                XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), 18, "预览和导出的形状外颜色应一致")
            }
        }
    }

    private func shapeProduct(preset: ShapePresetID, palette: ShapePalette, background: ShapeBackground) async throws -> GenerationProduct {
        let choice = ShapeChoice(preset: preset, palette: palette, background: background)
        let grid = try ShapeGenerationPlan.grid(choice, density: .coarse)
        let target = try ShapeGenerationPlan.target(choice, grid: grid, photoColors: [])
        let snap = try snapshot(count: 40)
        return try await GenerationRunner().run(target: target, snapshot: snap,
                                                settings: GenerationSettings(density: .coarse, overlayAlpha: 0.3),
                                                seed: 5, activeCells: grid.mask, shapeBackground: background)
    }

    private func snapshot(count: Int) throws -> IndexSnapshot {
        let records = (0..<count).map { i -> FeatureRecord in
            let l = Float(i % 20) / 20
            return FeatureRecord(vector: FeatureVector(uniform: SIMD3(l, 0.08, -0.02)), lightnessVariance: 0.02, aspectRatio: 1)
        }
        return IndexSnapshot(library: try LibrarySnapshot(table: FeatureTable(records: records)),
                             assetIDsByRow: (0..<count).map { "asset-\($0)" })
    }

    private func assertCell(_ bytes: [UInt8], image: CGImage, mask: CellMask, index: Int, background: ShapeBackground,
                            tolerance: Int, label: String) throws {
        let expected: UInt8 = background == .black ? 0 : 255
        let pixel = sample(bytes, image: image, columns: mask.columns, rows: mask.rows,
                           cellPixels: image.width / mask.columns, index: index)
        for channel in [pixel.0, pixel.1, pixel.2] {
            XCTAssertLessThanOrEqual(abs(Int(channel) - Int(expected)), tolerance, "\(label) \(pixel)")
        }
    }

    private func assertPhotoSwatch(_ pixel: (UInt8, UInt8, UInt8), tolerance: Int, label: String) {
        let swatch = (UInt8(220), UInt8(30), UInt8(30))
        for pair in [(pixel.0, swatch.0), (pixel.1, swatch.1), (pixel.2, swatch.2)] {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), tolerance, "\(label) \(pixel)")
        }
        XCTAssertGreaterThan(abs(Int(pixel.0) - 255) + abs(Int(pixel.1) - 255) + abs(Int(pixel.2) - 255), 80, "\(label) 不是白底")
        XCTAssertGreaterThan(Int(pixel.0) + Int(pixel.1) + Int(pixel.2), 80, "\(label) 不是黑底")
    }

    private func assertNotSame(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), label: String) {
        let delta = abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2))
        XCTAssertGreaterThan(delta, 40, label)
    }

    private func assertNotTinted(_ bytes: [UInt8], image: CGImage, mask: CellMask, index: Int, label: String) {
        let pixel = sample(bytes, image: image, columns: mask.columns, rows: mask.rows,
                           cellPixels: image.width / mask.columns, index: index)
        XCTAssertLessThan(Int(pixel.1), 40, "\(label) 形状外不应被绿色叠加染色 \(pixel)")
    }

    private func assertFetchesStayInside(_ ids: [String], product: GenerationProduct) throws {
        let mask = try XCTUnwrap(product.shapeFrame).mask
        var inside = Set<String>()
        for index in 0..<mask.cellCount {
            guard let id = product.cellAssetIDs[index] else { continue }
            if mask.isActive(index) { inside.insert(id) }
            else { XCTFail("形状外格子不应分配照片") }
        }
        XCTAssertFalse(inside.isEmpty)
        XCTAssertEqual(Set(ids), inside)
    }

    private func sample(_ bytes: [UInt8], image: CGImage, columns: Int, rows: Int, cellPixels: Int, index: Int) -> (UInt8, UInt8, UInt8) {
        let column = index % columns, row = index / columns
        let x = column * cellPixels + cellPixels / 2
        let y = image.height - (row + 1) * cellPixels + cellPixels / 2
        let o = y * image.width * 4 + x * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2])
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

    private func solid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
        }
        return try PixelBuffer(width: width, height: height, bytes: bytes)
    }

    private func decodeJPEG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func writeTinyJPEG(to url: URL) throws {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.2, 0.4, 0.6, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(ctx.makeImage())
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return XCTFail("写不出 jpeg")
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}

private final class CountingThumbs: ThumbnailProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private let tile: PixelBuffer

    init() {
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = 220
            bytes[i + 1] = 30
            bytes[i + 2] = 30
        }
        tile = try! PixelBuffer(width: 8, height: 8, bytes: bytes)
    }

    func idsSnapshot() -> [String] { withLock { ids } }
    func reset() { withLock { ids.removeAll() } }

    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        record(assetID)
        return .image(tile)
    }

    private func record(_ id: String) { withLock { ids.append(id) } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
