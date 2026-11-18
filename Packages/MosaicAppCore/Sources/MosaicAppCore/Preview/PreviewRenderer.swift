import MosaicCore

/// 结果页的"色块预览"：用素材特征的 2×2 子块颜色画出每个格子（OKLab → sRGB）。
///
/// 用途：缩略图还没取回时先显示的占位预览，以及 Linux 上可验证的渲染逻辑。真正的预览由 App 层用缩略图绘制。
public enum PreviewRenderer {
    /// - Parameters:
    ///   - cellPixels: 每格像素（偶数时 2×2 子块精确对齐）。
    /// - Returns: RGBA8 sRGB 不透明图像，尺寸 = 列数 × cellPixels，行数 × cellPixels。
    public static func render(_ generation: MosaicGeneration, table: FeatureTable, cellPixels: Int = 8) throws -> PixelBuffer {
        let cp = max(2, cellPixels)
        let cols = generation.layout.columns, rows = generation.layout.rows
        let w = cols * cp, h = rows * cp
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let half = cp / 2
        for cell in 0..<generation.layout.cellCount {
            let (cx, cy) = generation.layout.grid.position(of: cell)
            let tile = generation.assignment.tiles[cell]
            let vec = tile >= 0 && tile < table.count ? table.record(tile).vector : FeatureVector()
            for b in 0..<4 {
                let rgb = srgbBytes(fromFeatureBlock: vec.block(b), colorSpace: table.spec.colorSpace)
                let bx = b % 2, by = b / 2
                let x0 = cx * cp + (bx == 0 ? 0 : half), x1 = cx * cp + (bx == 0 ? half : cp)
                let y0 = cy * cp + (by == 0 ? 0 : half), y1 = cy * cp + (by == 0 ? half : cp)
                for y in y0..<y1 {
                    var o = (y * w + x0) * 4
                    for _ in x0..<x1 {
                        bytes[o] = rgb.0; bytes[o + 1] = rgb.1; bytes[o + 2] = rgb.2; bytes[o + 3] = 255
                        o += 4
                    }
                }
            }
        }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }

    /// 特征子块（OKLab 或 CIELAB 三元组）→ 8 位 sRGB。
    public static func srgbBytes(fromFeatureBlock c: SIMD3<Float>, colorSpace: FeatureColorSpace) -> (UInt8, UInt8, UInt8) {
        let lin: LinearRGB
        switch colorSpace {
        case .oklab: lin = OKLab(L: c.x, a: c.y, b: c.z).linearRGB
        case .cielab: lin = CIELabInverse.linearRGB(L: c.x, a: c.y, b: c.z)
        }
        func enc(_ v: Float) -> UInt8 {
            let s = SRGB.fromLinear(min(max(v, 0), 1))
            return UInt8(min(max((s * 255).rounded(), 0), 255))
        }
        return (enc(lin.r), enc(lin.g), enc(lin.b))
    }
}

/// CIELAB(D65) → 线性 sRGB（只给预览用；CIELAB 不是默认口径，决定 14）。
enum CIELabInverse {
    static func linearRGB(L: Float, a: Float, b: Float) -> LinearRGB {
        let fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func finv(_ t: Float) -> Float {
            let d: Float = 6.0 / 29.0
            return t > d ? t * t * t : 3 * d * d * (t - 4.0 / 29.0)
        }
        let X = 0.95047 * finv(fx), Y = finv(fy), Z = 1.08883 * finv(fz)
        let r = 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
        let g = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
        let bb = 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
        return LinearRGB(r: r, g: g, b: bb)
    }
}
