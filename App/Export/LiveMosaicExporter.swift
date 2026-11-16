import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MosaicCore
import MosaicAppCore

/// 导出器的 Apple 实现（T8）：逻辑在 MosaicAppCore 的 `StripExporter`（条带循环、存储预检、取消、清理，Linux 有测试），
/// 这里只提供 Core Graphics 条带渲染和 ImageIO 编码。所有文件放在 `tmp/export/`，启动时整个目录清空（B-27）。
/// ⚠️ 盲写（Linux 上无法编译 CG / ImageIO），见 CHANGES「盲写风险」R23–R26。
enum LiveMosaicExporter {
    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
    }

    static func make(thumbnails: any ThumbnailProviding) -> StripExporter {
        StripExporter(directory: exportDirectory, renderer: CGStripRenderer(thumbnails: thumbnails),
                      encoder: ImageIOJPEGEncoder(), storage: { availableBytes() })
    }

    /// `volumeAvailableCapacityForImportantUsage`（系统会为「重要」写入腾出可清理空间）；读不到返回 nil（不拦截）。
    static func availableBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// 一条条带 = 一块 `width × stripHeight` 的 RGBA8 画布：画该条带内各格的缩略图，再按 α 叠加目标图对应区域。
/// 同时在内存里的只有这一块画布（6000 档 ≤ 6000×512×4 ≈ 12 MB）和一个取图窗口的缩略图。
struct CGStripRenderer: StripRendering {
    let thumbnails: any ThumbnailProviding

    func render(_ strip: ExportStrip, geometry g: ExportGeometry, request: ExportRequest) async throws -> Data {
        let w = g.width, h = strip.pixelHeight, cp = g.cellPixels
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ExportError.encodingFailed }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high

        let cells = g.cells(in: strip)
        let allIDs = request.product.cellAssetIDs
        let stripIDs: [String?] = cells.map { $0 < allIDs.count ? allIDs[$0] : nil }
        let columns = g.columns
        let firstRow = strip.rows.lowerBound
        let thumbs = thumbnails

        func draw(_ group: ThumbnailPreviewPlan.Group, _ pb: PixelBuffer) {
            guard let img = ImagePixels.cgImage(pb) else { return }
            for local in group.cells {
                let cell = cells.lowerBound + local
                let col = cell % columns, rowInStrip = cell / columns - firstRow
                // CG 原点在左下：条带内第 0 行在最上面
                ctx.draw(img, in: CGRect(x: col * cp, y: h - (rowInStrip + 1) * cp, width: cp, height: cp))
            }
        }

        // 第 1 遍：按导出格子大小取高质量缩略图（本地没有原图的取不到，零网络）。
        // let（不是 var）：会被 @Sendable 的 fetch 闭包捕获
        let hq: ThumbnailRequest = {
            var r = ThumbnailRequest(targetPixelSize: min(512, max(128, cp)))
            r.fastFormat = false
            r.fastResize = false
            return r
        }()
        var drawnCells = Set<Int>()
        try await ThumbnailPreviewPlan(cellAssetIDs: stripIDs, maxConcurrent: 8).run(
            fetch: { id in await thumbs.thumbnail(for: id, request: hq) }
        ) { group, pb in
            draw(group, pb)
            drawnCells.formUnion(group.cells)
        }
        // 第 2 遍：取不到高质量图的格子退回扫描用 128 px 缩略图（导出后这些块会稍模糊，文案 export.degraded）。
        let missing: [String?] = stripIDs.enumerated().map { drawnCells.contains($0.offset) ? nil : $0.element }
        if missing.contains(where: { $0 != nil }) {
            try await ThumbnailPreviewPlan(cellAssetIDs: missing, maxConcurrent: 8).run(
                fetch: { id in await thumbs.thumbnail(for: id, request: .scan) }
            ) { group, pb in draw(group, pb) }
        }

        // 叠加目标图（α ≤ 0.3，sRGB 编码值上混合，与 OverlayBlend 同公式）。
        let alpha = OverlayBlendLimits.clamp(request.overlayAlpha)
        if alpha > 0, let target = ImagePixels.cgImage(request.target) {
            let layout = request.product.generation.layout
            let crop = layout.cropRect
            let rowH = crop.height / Double(layout.rows)
            let rect = CGRect(x: crop.x, y: crop.y + rowH * Double(strip.rows.lowerBound),
                              width: crop.width, height: rowH * Double(strip.rows.count))
            if let part = target.cropping(to: rect.integral) {
                ctx.setAlpha(alpha)
                ctx.interpolationQuality = .medium
                ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        guard let base = ctx.data else { throw ExportError.encodingFailed }
        return Data(bytes: base, count: w * h * 4)
    }
}

/// raw RGBA8 暂存文件 → JPEG（质量 0.9，sRGB）。`CGDataProvider(url:)` 按需读文件，不先整张读进内存。
struct ImageIOJPEGEncoder: RasterEncoding {
    var fileExtension: String { "jpg" }

    func encode(rawFile: URL, width: Int, height: Int, to output: URL) throws {
        guard let provider = CGDataProvider(url: rawFile as CFURL),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ExportError.encodingFailed }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodingFailed }
    }
}
