import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import MosaicCore
import MosaicAppCore

/// 「我的作品」的 Apple 侧适配器。逻辑（原子写、查重、缺失计数、删除确认）都在 MosaicAppCore（Linux 有测试）。
/// ⚠️ 盲写（Linux 只能 `swiftc -parse`），需真机核对。

enum WorksLocation {
    /// `Application Support/Works`。**不**设 `isExcludedFromBackup`：作品跟随 iCloud 备份（works-storage-v0.1），
    /// 与 `Application Support/Index`（排除备份）相反。
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Works", isDirectory: true)
    }
}

/// 原照片还在不在：`PhotoFetch.visibleImages(withLocalIdentifiers:)` 分批查（不联网，只查本机相册数据库）。
struct PhotoKitExistenceChecker: PhotoExistenceChecking {
    static let batch = 500

    func existingIdentifiers(among identifiers: [String]) async -> Set<String> {
        var found = Set<String>()
        var start = 0
        while start < identifiers.count {
            let chunk = Array(identifiers[start..<min(identifiers.count, start + Self.batch)])
            // 走 PhotoFetch.visibleImages：隐藏照片取不到，和已删除一样按缺图处理（design 5.1）
            for a in PhotoFetch.visibleImages(withLocalIdentifiers: chunk) {
                found.insert(a.localIdentifier)
            }
            start += chunk.count
        }
        return found
    }

    /// 扩充的返回值：在的 ID + 缺失原因（`PhotoFetch.classifyMissing`，只读元数据，不请求图像）。
    func availability(among identifiers: [String]) async -> PhotoAvailability {
        let present = await existingIdentifiers(among: identifiers)
        let missing = Set(identifiers.filter { !$0.isEmpty && !present.contains($0) })
        guard !missing.isEmpty else { return PhotoAvailability(present: present, missing: [:]) }
        return PhotoAvailability(present: present, missing: PhotoFetch.classifyMissing(missing))
    }

    /// 受限访问 / 无权限时没选进来的照片也取不到，不能当成被删 / 被隐藏去改写作品（只计数提示）。
    func canConfirmMissing() async -> Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }
}

/// 预览图 / 目标图副本：Core Graphics 绘制 + ImageIO 写 JPEG（质量 0.85，sRGB）。
///
/// 预览图按保存的显式布局逐格绘制（扫描用 128 px 缩略图；兜底格用旧预览裁出的小图 `.high` 插值放大填满，不取照片；
/// 都没有的格子留白；长边 2732，约 2732×2049×4 ≈ 22 MB 画布），
/// 再按 α 叠加目标图网格区域——与结果页预览、导出条带同一公式。不依赖 `GenerationProduct`，作品页也能重画。
struct ImageIOWorkImages: WorkImageEncoding {
    let thumbnails: any ThumbnailProviding
    static let quality = 0.85

    func writePreview(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, maxLongEdge: Int,
                      fallbacks: [Int: PixelBuffer], into directory: URL) async throws -> WorkImageFile {
        let cp = max(1, maxLongEdge / max(1, max(layout.cols, layout.rows)))
        let w = layout.cols * cp, h = layout.rows * cp
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportError.encodingFailed }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        let steps = ShapeStripExport.steps(columns: layout.cols, rows: layout.rows, cellPixels: cp, shape: layout.shapeFrame)
        for step in steps {
            guard let background = step.background else { continue }
            let (r, g, b) = background.srgb8
            ctx.setFillColor(CGColor(colorSpace: cs, components: [
                CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1,
            ])!)
            let cx = step.index % layout.cols, cy = step.index / layout.cols
            ctx.fill(CGRect(x: cx * cp, y: h - (cy + 1) * cp, width: cp, height: cp))
        }

        // 兜底格：不取照片，旧预览裁出的小图放大填满（双线性 / .high，不用最近邻）。形状外不画兜底图。
        ctx.interpolationQuality = .high
        let outside = Set(steps.compactMap { $0.background == nil ? nil : $0.index })
        for (cell, tile) in fallbacks where cell < layout.cellCount && !outside.contains(cell) {
            guard let img = ImagePixels.cgImage(tile) else { continue }
            let cx = cell % layout.cols, cy = cell / layout.cols
            ctx.draw(img, in: CGRect(x: cx * cp, y: h - (cy + 1) * cp, width: cp, height: cp))
        }
        ctx.interpolationQuality = .medium

        let ids: [String?] = layout.cellAssignments.enumerated().map { i, c in
            if outside.contains(i) { return nil }
            return c.localIdentifier.isEmpty || fallbacks[i] != nil ? nil : c.localIdentifier
        }
        let cols = layout.cols
        let thumbs = thumbnails
        try await ThumbnailPreviewPlan(cellAssetIDs: ids, maxConcurrent: 12).run(
            fetch: { id in await thumbs.thumbnail(for: id, request: .scan) }
        ) { group, pb in
            guard let img = ImagePixels.cgImage(pb) else { return }
            for cell in group.cells {
                let cx = cell % cols, cy = cell / cols
                ctx.draw(img, in: CGRect(x: cx * cp, y: h - (cy + 1) * cp, width: cp, height: cp))
            }
        }
        let alpha = layout.shapeFrame == nil ? OverlayBlendLimits.clamp(overlayAlpha) : 0
        if alpha > 0, let target, let t = ImagePixels.cgImage(target) {
            let crop = Self.scaledCrop(layout, toTargetWidth: target.width, height: target.height)
            if let part = t.cropping(to: crop.integral) {
                ctx.setAlpha(alpha)
                ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        guard let image = ctx.makeImage() else { throw ExportError.encodingFailed }
        let name = "preview.jpg"
        try Self.writeJPEG(image, to: directory.appendingPathComponent(name))
        return WorkImageFile(fileName: name, pixelWidth: w, pixelHeight: h)
    }

    func writeTarget(_ target: PixelBuffer, maxLongEdge: Int, into directory: URL) async throws -> WorkImageFile {
        guard let cg = ImagePixels.cgImage(target) else { throw ExportError.encodingFailed }
        var image = cg
        if max(cg.width, cg.height) > maxLongEdge, let scaled = ImagePixels.opaqueSRGB(cg, maxEdge: maxLongEdge),
           let s = ImagePixels.cgImage(scaled) {
            image = s
        }
        let name = "target.jpg"
        try Self.writeJPEG(image, to: directory.appendingPathComponent(name))
        return WorkImageFile(fileName: name, pixelWidth: image.width, pixelHeight: image.height)
    }

    func readTarget(at url: URL) async throws -> PixelBuffer {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let pb = ImagePixels.opaqueSRGB(cg)
        else { throw ExportError.encodingFailed }
        return pb
    }

    /// 预览图 / 兜底图原尺寸解码（裁兜底格用；不降采样）。
    func readImage(at url: URL) async throws -> PixelBuffer {
        #if INTERNAL_TOOLS
        PreviewReadProbe.recordFileRead()
        #endif
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let pb = ImagePixels.opaqueSRGB(cg)
        else { throw ExportError.encodingFailed }
        return pb
    }

    /// 兜底图写 PNG（无损：之后每次重画预览 / 导出都从它取，不能一代代 JPEG 损失）。
    func writeFallback(_ image: PixelBuffer, into directory: URL) async throws -> WorkImageFile {
        guard let cg = ImagePixels.cgImage(image) else { throw ExportError.encodingFailed }
        let name = "fallback.png"
        let url = directory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.encodingFailed }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodingFailed }
        return WorkImageFile(fileName: name, pixelWidth: cg.width, pixelHeight: cg.height)
    }

    /// 布局里的网格区域是生成时目标图像素；目标图（副本）尺寸不同时按比例换算。
    static func scaledCrop(_ layout: MosaicLayout, toTargetWidth tw: Int, height th: Int) -> CGRect {
        let sx = layout.targetSize.width > 0 ? Double(tw) / Double(layout.targetSize.width) : 1
        let sy = layout.targetSize.height > 0 ? Double(th) / Double(layout.targetSize.height) : 1
        let c = layout.targetCrop
        return CGRect(x: c.x * sx, y: c.y * sy, width: c.width * sx, height: c.height * sy)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ExportError.encodingFailed }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodingFailed }
    }

    /// 列表缩略图 / 查看页：ImageIO 降采样解码（不整张解码大图）。
    static func loadImage(_ url: URL, maxPixel: Int) -> CGImage? {
        #if INTERNAL_TOOLS
        PreviewReadProbe.recordFileRead()
        #endif
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }
}

#if INTERNAL_TOOLS
import os

/// 内测计数：列表和查看页读预览文件的真实入口是 `ImageIOWorkImages.loadImage` / `readImage`。
/// 日志只有次数。不记路径、作品 ID、相册名或错误内容。不改变谁可以读。
enum PreviewReadProbe {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "pinyi", category: "preview-read")
    private static let lock = NSLock()
    private static var fileReads = 0

    static var fileReadCount: Int { withLock { fileReads } }

    static func reset() {
        let n = withLock { () -> Int in
            fileReads = 0
            return 0
        }
        log.info("previewFileReads \(n, privacy: .public)")
    }

    static func recordFileRead() {
        let n = withLock { () -> Int in
            fileReads += 1
            return fileReads
        }
        log.info("previewFileReads \(n, privacy: .public)")
    }

    /// 在临时目录写一张合成图，再走和作品列表相同的 `loadImage`。成功时读取次数加 1。
    static func positiveControl() -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pinyi-probe-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        guard writeSyntheticJPEG(to: url), ImageIOWorkImages.loadImage(url, maxPixel: 32) != nil else {
            log.info("positiveControl failed")
            return false
        }
        return true
    }

    private static func writeSyntheticJPEG(to url: URL) -> Bool {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.2, 0.4, 0.6, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
#endif

/// 从作品再导出 → 导出线 `AppCoordinator.export(layout:target:purpose:)`（按保存的显式布局，档位用当前 `exportTier`）。
/// 弱引用协调器（`WorksController` 强持有本桥）。
@MainActor
final class CoordinatorWorkExporter: WorkExportHandling {
    weak var coordinator: AppCoordinator?
    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func exportWork(layout: MosaicLayout, target: PixelBuffer?, fallbacks: [Int: PixelBuffer], purpose: ExportPurpose) async {
        await coordinator?.export(layout: layout, target: target, fallbacks: fallbacks, purpose: purpose)
    }
}
