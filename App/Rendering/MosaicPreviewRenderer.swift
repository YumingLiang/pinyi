import CoreGraphics
import Foundation
import MosaicCore
import MosaicAppCore

/// 结果页预览：先用特征色块（`PreviewRenderer`，MosaicAppCore 内已测）即时显示，
/// 再用 128px 缩略图逐格绘制并叠加目标图（α 0–0.3，sRGB 编码值上混合，与 `OverlayBlend` 同公式）。
/// 导出（4000 / 6000 分条渲染）不在本卡范围。⚠️ 盲写。
enum MosaicPreviewRenderer {
    /// 预览每格像素：长边约 2400px 封顶（120 列 × 20px），内存约 2400×1800×4 ≈ 17 MB。
    static func cellPixels(for g: MosaicGeneration) -> Int {
        max(8, min(32, 2400 / max(g.layout.columns, g.layout.rows)))
    }

    /// 特征色块预览（同步、很快）。
    static func colorBlocks(_ product: GenerationProduct) -> CGImage? {
        guard let p = try? PreviewRenderer.render(product.generation, table: product.snapshot.library.table, cellPixels: 8) else { return nil }
        return ImagePixels.cgImage(p)
    }

    /// 缩略图预览。
    static func thumbnails(_ product: GenerationProduct, target: PixelBuffer, overlayAlpha: Double,
                           thumbnails: any ThumbnailProviding) async -> CGImage? {
        let g = product.generation
        let cp = cellPixels(for: g)
        let w = g.layout.columns * cp, h = g.layout.rows * cp
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 同一张素材可能被多格使用：按 id 去重取图。
        var cache: [String: CGImage] = [:]
        let ids = product.cellAssetIDs
        for cell in 0..<g.layout.cellCount {
            if Task.isCancelled { return nil }
            guard let id = ids[cell] else { continue }
            if cache[id] == nil, case .image(let pb) = await thumbnails.thumbnail(for: id, request: .scan),
               let cg = ImagePixels.cgImage(pb) {
                cache[id] = cg
            }
            guard let img = cache[id] else { continue }
            let (cx, cy) = g.layout.grid.position(of: cell)
            // CG 坐标原点在左下
            let rect = CGRect(x: cx * cp, y: h - (cy + 1) * cp, width: cp, height: cp)
            ctx.draw(img, in: rect)   // 缩略图已是 aspectFill 正方形附近；中心裁切由 PhotoKit 的 aspectFill 完成
        }
        let alpha = OverlayBlendLimits.clamp(overlayAlpha)
        if alpha > 0, let t = ImagePixels.cgImage(target) {
            let crop = g.layout.cropRect
            if let cropped = t.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)) {
                ctx.setAlpha(alpha)
                ctx.interpolationQuality = .medium
                ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return ctx.makeImage()
    }
}
