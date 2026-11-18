import Foundation
import MosaicCore

/// 预览兜底（hd-export-req-v0.2 F 节；`works.missing`；Q1 之后不再产生新兜底图，只剩旧作品迁移和纯函数）：作品里原照片取不到、又找不到合格相近照片的格子，
/// 在重新生成预览**之前**从旧预览里裁出该格区域，存进作品目录（`WorkMeta.fallbackFile`），之后的预览重画和高清导出都用它
/// 放大填充（App 侧 `.high` 插值，不用最近邻）。纯 Swift，Linux 有测试。
///
/// - 旧预览已经叠加过目标图（α ≤ 0.3）。裁格子时按「预览 = (1 − α)·格子 + α·目标」反解出叠加前的格子颜色，
///   否则重画预览 / 导出时再叠一次，兜底格会比别的格子更「像目标图」。
/// - 兜底图按格拼成一张（列 × 行，每格与预览每格同像素），只有兜底格位置有像素（其余为 0），PNG 无损；已经是兜底的格子后来重写时直接搬旧兜底图，不再从预览二次裁切，
///   避免每次重写都损失一点。
public enum WorkFallbackImages {
    /// 第 `cell` 格在 `width × height` 图里的整数像素区域（列 / 行等分，左上原点）。
    public static func cellRect(_ cell: Int, cols: Int, rows: Int, width: Int, height: Int) -> PixelRegion? {
        guard cols > 0, rows > 0, width >= cols, height >= rows, cell >= 0, cell < cols * rows else { return nil }
        let col = cell % cols, row = cell / cols
        let x0 = col * width / cols, x1 = (col + 1) * width / cols
        let y0 = row * height / rows, y1 = (row + 1) * height / rows
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 从（旧）预览裁出 `cells` 的兜底图，并去掉预览里的目标图叠加（有目标图副本且 α > 0 时）。
    /// 预览尺寸和格子数对不上（例如很旧的预览、坏文件）时返回空：调用方按「没有旧预览」留白。
    public static func crop(from preview: PixelBuffer, cells: [Int], layout: MosaicLayout, target: PixelBuffer?,
                            overlayAlpha: Double) -> [Int: PixelBuffer] {
        let w = preview.width, h = preview.height
        guard layout.cols > 0, layout.rows > 0, w >= layout.cols, h >= layout.rows else { return [:] }
        let alpha = target == nil ? 0 : OverlayBlendLimits.clamp(overlayAlpha)
        let crop = target.map { scaledCrop(layout, width: $0.width, height: $0.height) }
        var out: [Int: PixelBuffer] = [:]
        for cell in cells {
            guard let r = cellRect(cell, cols: layout.cols, rows: layout.rows, width: w, height: h) else { continue }
            var bytes = [UInt8](repeating: 255, count: r.width * r.height * 4)
            for y in 0..<r.height {
                for x in 0..<r.width {
                    let px = r.x + x, py = r.y + y
                    let p = preview.rgb(x: px, y: py)
                    var c = (Double(p.r), Double(p.g), Double(p.b))
                    if alpha > 0, let target, let crop {
                        let tx = crop.x + (Double(px) + 0.5) * crop.width / Double(w) - 0.5
                        let ty = crop.y + (Double(py) + 0.5) * crop.height / Double(h) - 0.5
                        let t = bilinear(target, tx, ty)
                        c = ((c.0 - alpha * t.0) / (1 - alpha), (c.1 - alpha * t.1) / (1 - alpha), (c.2 - alpha * t.2) / (1 - alpha))
                    }
                    let o = (y * r.width + x) * 4
                    bytes[o] = byte(c.0)
                    bytes[o + 1] = byte(c.1)
                    bytes[o + 2] = byte(c.2)
                }
            }
            out[cell] = try? PixelBuffer(width: r.width, height: r.height, bytes: bytes)
        }
        return out
    }

    /// 把各格兜底图拼回一张与预览同尺寸的图（存盘用）；没有格子时返回 nil。
    public static func atlas(_ tiles: [Int: PixelBuffer], layout: MosaicLayout, width: Int, height: Int) -> PixelBuffer? {
        guard !tiles.isEmpty, width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (cell, tile) in tiles {
            guard let r = cellRect(cell, cols: layout.cols, rows: layout.rows, width: width, height: height) else { continue }
            for y in 0..<r.height {
                for x in 0..<r.width {
                    // 尺寸不一致（不应发生）时按比例取最近的源像素，只为不越界
                    let sx = min(tile.width - 1, x * tile.width / r.width), sy = min(tile.height - 1, y * tile.height / r.height)
                    let p = tile.rgb(x: sx, y: sy)
                    let o = ((r.y + y) * width + r.x + x) * 4
                    bytes[o] = p.r
                    bytes[o + 1] = p.g
                    bytes[o + 2] = p.b
                    bytes[o + 3] = 255
                }
            }
        }
        return try? PixelBuffer(width: width, height: height, bytes: bytes)
    }

    /// 从存盘的兜底图按格裁回。
    public static func split(_ atlas: PixelBuffer, cells: [Int], layout: MosaicLayout) -> [Int: PixelBuffer] {
        var out: [Int: PixelBuffer] = [:]
        for cell in cells {
            guard let r = cellRect(cell, cols: layout.cols, rows: layout.rows, width: atlas.width, height: atlas.height) else { continue }
            var bytes = [UInt8](repeating: 255, count: r.width * r.height * 4)
            for y in 0..<r.height {
                for x in 0..<r.width {
                    let p = atlas.rgb(x: r.x + x, y: r.y + y)
                    let o = (y * r.width + x) * 4
                    bytes[o] = p.r
                    bytes[o + 1] = p.g
                    bytes[o + 2] = p.b
                }
            }
            out[cell] = try? PixelBuffer(width: r.width, height: r.height, bytes: bytes)
        }
        return out
    }

    /// 布局里的网格区域按目标图（副本）尺寸换算（与 App 预览 / 导出叠加同一换算）。
    static func scaledCrop(_ layout: MosaicLayout, width tw: Int, height th: Int) -> CropRect {
        let sx = layout.targetSize.width > 0 ? Double(tw) / Double(layout.targetSize.width) : 1
        let sy = layout.targetSize.height > 0 ? Double(th) / Double(layout.targetSize.height) : 1
        let c = layout.targetCrop
        return CropRect(x: c.x * sx, y: c.y * sy, width: c.width * sx, height: c.height * sy)
    }

    static func bilinear(_ img: PixelBuffer, _ x: Double, _ y: Double) -> (Double, Double, Double) {
        let fx = min(max(x, 0), Double(img.width - 1)), fy = min(max(y, 0), Double(img.height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, img.width - 1), y1 = min(y0 + 1, img.height - 1)
        let ax = fx - Double(x0), ay = fy - Double(y0)
        func v(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let p = img.rgb(x: x, y: y)
            return (Double(p.r), Double(p.g), Double(p.b))
        }
        let a = v(x0, y0), b = v(x1, y0), c = v(x0, y1), d = v(x1, y1)
        func mix(_ p: Double, _ q: Double, _ r: Double, _ s: Double) -> Double {
            (p * (1 - ax) + q * ax) * (1 - ay) + (r * (1 - ax) + s * ax) * ay
        }
        return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2))
    }

    static func byte(_ v: Double) -> UInt8 { UInt8(min(max(v, 0), 255).rounded()) }
}
