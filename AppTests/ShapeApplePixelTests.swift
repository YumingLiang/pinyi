import CoreGraphics
import ImageIO
import Photos
import UniformTypeIdentifiers
import XCTest
import MosaicCore
import MosaicAppCore
@testable import PhotoMosaic

/// 在 iOS 模拟器上走真正的 `MosaicPreviewRenderer` 和 `LiveMosaicExporter`。
///
/// 覆盖到：Core Graphics 预览位图、JPEG 导出文件、形状外黑白背景、形状模式不向掩码外取缩略图、叠加强制为 0。
/// 不覆盖：真机相册里的隐藏照片、受限访问授权弹窗、签名安装后的屏幕像素。那些仍要 QA 在设备上看。
@MainActor
final class ShapeApplePixelTests: XCTestCase {
    func testPreviewAndExportPaintOutsideMaskAndDoNotFetchThoseCells() async throws {
        for background in [ShapeBackground.white, .black] {
            let product = try await shapeProduct(background: background)
            let frame = try XCTUnwrap(product.shapeFrame)
            let mask = frame.mask
            XCTAssertFalse(mask.isActive(0), "圆形左上角应在形状外")
            XCTAssertGreaterThan(mask.activeCount, 0)

            let blocks = try XCTUnwrap(MosaicPreviewRenderer.colorBlocks(product))
            try assertOutside(blocks, product: product, cellPixels: 8, background: background, tolerance: 2,
                              label: "colorBlocks \(background)", expectPhotoColor: false)

            let thumbs = CountingThumbs()
            let target = try shapeTarget(background: background)
            let preview = try XCTUnwrap(await MosaicPreviewRenderer.thumbnails(product, target: target, overlayAlpha: 0.3, thumbnails: thumbs))
            let cp = MosaicPreviewRenderer.cellPixels(for: product.generation)
            try assertOutside(preview, product: product, cellPixels: cp, background: background, tolerance: 2,
                              label: "thumbnails \(background)", expectPhotoColor: true)
            try assertFetchesStayInside(thumbs.fetchedIDs(), product: product, label: "preview \(background)")

            let request = ExportRequest(product: product, target: target, overlayAlpha: 0.3, tier: .share)
            XCTAssertEqual(request.overlayAlpha, 0, "形状导出叠加强制为 0")
            let exporter = LiveMosaicExporter(thumbnails: thumbs)
            thumbs.reset()
            let url = try await exporter.export(request) { _ in }
            defer { try? FileManager.default.removeItem(at: url) }
            let jpeg = try XCTUnwrap(decodeJPEG(url))
            let plan = request.plan(availableMemoryBytes: LiveMosaicExporter.availableMemory())
            try assertOutside(jpeg, product: product, cellPixels: plan.cellPixels, background: background, tolerance: 18,
                              label: "export \(background)", expectPhotoColor: true)
            try assertFetchesStayInside(thumbs.fetchedIDs(), product: product, label: "export \(background)")
        }
    }

    /// 受限访问时，界面用来读预览的 `decodePreview` 不调用真正的 ImageIO 解码。
    /// 这里的「受限」是 `WorksState.limitedAccess`（与 `PhotoKitExistenceChecker.canConfirmMissing` 同一判断结果），
    /// 不是模拟器上弹出的系统授权框，也不能代替真机隐藏照片。
    func testLimitedAccessDoesNotDecodePreviewWithImageIO() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shape-preview-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("preview.jpg")
        try writeTinyJPEG(to: url)
        let meta = WorkMeta(id: WorkID(), createdAt: Date(), columns: 2, rows: 2, tier: nil, photoCount: 1,
                            missingCount: 0, overlayAlpha: 0, seed: 1, fingerprint: "x", origin: .savedManually,
                            previewFile: "preview.jpg", previewPixelWidth: 2, previewPixelHeight: 2, targetFile: nil)
        let summary = WorkSummary(meta: meta, previewURL: url)
        var state = WorksState()
        state.limitedAccess = true
        var reads = 0
        let images = ImageIOWorkImages(thumbnails: CountingThumbs())
        let decoded: PixelBuffer? = state.decodePreview(for: summary) { _ in
            reads += 1
            return nil
        }
        XCTAssertNil(decoded)
        XCTAssertEqual(reads, 0, "受限访问不进入解码闭包，因此不会调用 ImageIOWorkImages.readImage")
        XCTAssertEqual(state.previewDisplay(for: summary), .limitedAccess)

        state.limitedAccess = false
        let opened = try await images.readImage(at: url)
        XCTAssertEqual(opened.width, 2)
        XCTAssertEqual(reads, 0, "上面的直接读取是为了证明 ImageIO 解码器能读这个文件，不是列表路径")

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let checker = PhotoKitExistenceChecker()
        let canConfirm = await checker.canConfirmMissing()
        if status == .authorized {
            XCTAssertTrue(canConfirm)
        } else {
            XCTAssertFalse(canConfirm, "模拟器当前授权是 \(status.rawValue)，不能把它写成已经测过真机受限或隐藏照片")
        }
        let found = PhotoFetch.visibleImages(withLocalIdentifiers: ["not-a-real-asset"])
        XCTAssertTrue(found.isEmpty, "PhotoFetch.visibleImages 对不存在的 ID 返回空；没有在模拟器里制造隐藏照片")
    }

    private func shapeProduct(background: ShapeBackground) async throws -> GenerationProduct {
        let snap = try snapshot(count: 80)
        let target = try shapeTarget(background: background)
        return try await GenerationRunner().run(target: target, snapshot: snap,
                                                settings: GenerationSettings(density: .coarse, overlayAlpha: 0.3),
                                                seed: 5, activeCells: shapeGrid().mask, shapeBackground: background)
    }

    private func shapeGrid() throws -> ShapeLayoutRules.ShapeGrid {
        try ShapeGenerationPlan.grid(ShapeChoice(preset: .circle, palette: .blue, background: .white), density: .coarse)
    }

    private func shapeTarget(background: ShapeBackground) throws -> PixelBuffer {
        let grid = try shapeGrid()
        return try ShapeGenerationPlan.target(ShapeChoice(preset: .circle, palette: .blue, background: background),
                                              grid: grid, photoColors: [])
    }

    private func snapshot(count: Int) throws -> IndexSnapshot {
        let records = (0..<count).map { i -> FeatureRecord in
            let l = Float(i % 20) / 20
            return FeatureRecord(vector: FeatureVector(uniform: SIMD3(l, 0.02, -0.01)), lightnessVariance: 0.02, aspectRatio: 1)
        }
        return IndexSnapshot(library: try LibrarySnapshot(table: FeatureTable(records: records)),
                             assetIDsByRow: (0..<count).map { "asset-\($0)" })
    }

    private func assertOutside(_ image: CGImage, product: GenerationProduct, cellPixels: Int, background: ShapeBackground,
                               tolerance: Int, label: String, expectPhotoColor: Bool) throws {
        let mask = try XCTUnwrap(product.shapeFrame).mask
        let expected: UInt8 = background == .black ? 0 : 255
        XCTAssertEqual(image.width, mask.columns * cellPixels, label)
        XCTAssertEqual(image.height, mask.rows * cellPixels, label)
        let bytes = try bitmap(image, width: image.width, height: image.height)
        func sample(_ index: Int) -> (UInt8, UInt8, UInt8) {
            let column = index % mask.columns, row = index / mask.columns
            let x = column * cellPixels + cellPixels / 2
            let y = image.height - (row + 1) * cellPixels + cellPixels / 2
            let o = y * image.width * 4 + x * 4
            return (bytes[o], bytes[o + 1], bytes[o + 2])
        }
        let corner = sample(0)
        for channel in [corner.0, corner.1, corner.2] {
            XCTAssertLessThanOrEqual(abs(Int(channel) - Int(expected)), tolerance, "\(label) 左上角应是背景 \(corner)")
        }
        if background == .black {
            var backgroundCells = 0
            var photoCells = 0
            for index in 0..<mask.cellCount {
                let pixel = sample(index)
                let isBackground = [pixel.0, pixel.1, pixel.2].allSatisfy { abs(Int($0) - Int(expected)) <= tolerance }
                if isBackground { backgroundCells += 1 }
                if pixel.0 > 150 && pixel.1 < 90 && pixel.2 < 90 { photoCells += 1 }
            }
            XCTAssertEqual(backgroundCells, mask.cellCount - mask.activeCount, "\(label) 黑底格子数应等于形状外")
            if expectPhotoColor {
                XCTAssertGreaterThan(photoCells, 0, "\(label) 形状内应有注入的红色缩略图")
            }
        }
    }

    private func assertFetchesStayInside(_ ids: [String], product: GenerationProduct, label: String) throws {
        let mask = try XCTUnwrap(product.shapeFrame).mask
        var inside = Set<String>()
        for index in 0..<mask.cellCount {
            guard let id = product.cellAssetIDs[index] else { continue }
            if mask.isActive(index) {
                inside.insert(id)
            } else {
                XCTFail("\(label) 形状外格子不应分配照片 \(id)")
            }
        }
        XCTAssertFalse(inside.isEmpty, label)
        XCTAssertEqual(Set(ids), inside, "\(label) 只取形状内的照片")
    }

    /// 与渲染器相同的格子坐标：第 0 行在图的上方。上下文数据第 0 行是底边。
    private func bitmap(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(ok)
        return bytes
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
            XCTFail("写不出 jpeg")
            return
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

    func fetchedIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    func reset() {
        lock.lock()
        ids.removeAll()
        lock.unlock()
    }

    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        lock.lock()
        ids.append(assetID)
        lock.unlock()
        return .image(tile)
    }
}
