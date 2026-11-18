import MosaicCore

/// 合成目标图（设计 shape-mosaic-v0.1 §4）：**按格子涂色，不按路径涂色**。
/// 形状内每格整块涂该格中心的渐变色（左上 → 右下，`t = (cx / W + cy / H) / 2`）；形状外涂背景色（不参与匹配）。
/// 这样边缘格子不会因为一半是背景而去配白色或黑色照片。
public enum ShapeTarget {
    /// 第 (column, row) 格的渐变色。
    public static func cellColor(column: Int, row: Int, columns: Int, rows: Int, gradient: ShapeGradient) -> OKLab {
        let cx = (Double(column) + 0.5) / Double(max(1, columns))
        let cy = (Double(row) + 0.5) / Double(max(1, rows))
        return gradient.color(at: (cx + cy) / 2)
    }

    /// OKLab → 8 位 sRGB（钳到色域内）。
    public static func srgb8(_ c: OKLab) -> (r: UInt8, g: UInt8, b: UInt8) {
        let lin = c.linearRGB
        func q(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (SRGB.fromLinear(max(0, min(1, v))) * 255).rounded()))) }
        return (q(lin.r), q(lin.g), q(lin.b))
    }

    /// 生成合成目标图：`mask.columns × pixelsPerCell` 宽、`mask.rows × pixelsPerCell` 高，RGBA8、sRGB。
    public static func render(mask: CellMask, gradient: ShapeGradient, background: ShapeBackground,
                              pixelsPerCell: Int = ShapeLayoutRules.targetPixelsPerCell) throws -> PixelBuffer {
        let px = max(1, pixelsPerCell)
        let w = mask.columns * px, h = mask.rows * px
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let bg = background.srgb8
        for r in 0..<mask.rows {
            for c in 0..<mask.columns {
                let rgb = mask.isActive(column: c, row: r)
                    ? srgb8(cellColor(column: c, row: r, columns: mask.columns, rows: mask.rows, gradient: gradient))
                    : bg
                for y in (r * px)..<((r + 1) * px) {
                    var o = (y * w + c * px) * 4
                    for _ in 0..<px {
                        bytes[o] = rgb.r
                        bytes[o + 1] = rgb.g
                        bytes[o + 2] = rgb.b
                        bytes[o + 3] = 255
                        o += 4
                    }
                }
            }
        }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }
}
