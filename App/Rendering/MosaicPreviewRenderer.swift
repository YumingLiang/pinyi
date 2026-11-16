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

    /// T7：目标图裁到网格区域（与导出条带叠加用同一裁剪），预览里按滑杆 α 实时叠加。
    static func overlay(_ product: GenerationProduct, target: PixelBuffer) -> CGImage? {
        let crop = product.generation.layout.cropRect
        return ImagePixels.cgImage(target)?.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height).integral)
    }

    /// 缩略图预览。在调用方的隔离域（MainActor）上画，取图在后台有界并发。
    @MainActor
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
        // MF-6：按素材分组、有界并发（12）取图，每取到一张画完它的所有格子即丢弃，不留全量缓存。
        let plan = ThumbnailPreviewPlan(cellAssetIDs: product.cellAssetIDs, maxConcurrent: 12)
        let grid = g.layout.grid
        do {
            try await plan.run(fetch: { id in await thumbnails.thumbnail(for: id, request: .scan) }) { group, pb in
                guard let img = ImagePixels.cgImage(pb) else { return }
                for cell in group.cells {
                    let (cx, cy) = grid.position(of: cell)
                    // CG 坐标原点在左下；缩略图已是 aspectFill 正方形附近
                    ctx.draw(img, in: CGRect(x: cx * cp, y: h - (cy + 1) * cp, width: cp, height: cp))
                }
            }
        } catch {
            return nil   // 被取消
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
