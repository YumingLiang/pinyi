/// 像素数据所用的 RGB 颜色空间（A-04 / 技术方案 §2.1："如为 Display P3 先转到 sRGB"）。
///
/// iOS 上 PhotoKit 缩略图常带 Display P3 色彩描述。平台层可以直接画到 sRGB 上下文（推荐，
/// 此时标 `.sRGB`）；若交给 Core 的是 P3 字节，则标 `.displayP3`，Core 在线性化后用 3×3 矩阵转到线性 sRGB，
/// 再进入 OKLab。两者共用 sRGB 传递函数（IEC 61966-2-1）。
public enum RGBColorSpace: String, Sendable, Hashable, CaseIterable {
    /// sRGB（默认；不做任何二次转换）。
    case sRGB
    /// Display P3（DCI-P3 原色 + D65 白点 + sRGB 传递函数）。
    case displayP3
}

/// Display P3 → sRGB 的线性变换。
///
/// 矩阵不手抄常数，而是由两套原色色度坐标与 D65 白点按标准方法推导
/// （`M = M_sRGB⁻¹ · M_P3`，`M_X` 为 RGB→XYZ），双精度计算后转 Float。
/// - sRGB 原色（ITU-R BT.709）：R(0.640, 0.330) G(0.300, 0.600) B(0.150, 0.060)
/// - Display P3 原色（SMPTE EG 432-1）：R(0.680, 0.320) G(0.265, 0.690) B(0.150, 0.060)
/// - 白点 D65：(0.3127, 0.3290)
public enum DisplayP3 {
    /// 线性 P3 → 线性 sRGB（行优先 3×3）。约为
    /// `[[1.2249, −0.2249, 0], [−0.0421, 1.0421, 0], [−0.0196, −0.0786, 1.0983]]`。
    public static let toLinearSRGBMatrix: [Double] = {
        let srgb = rgbToXYZ(r: (0.640, 0.330), g: (0.300, 0.600), b: (0.150, 0.060))
        let p3 = rgbToXYZ(r: (0.680, 0.320), g: (0.265, 0.690), b: (0.150, 0.060))
        return mul(inverse(srgb), p3)
    }()

    @usableFromInline static let m: [Float] = toLinearSRGBMatrix.map { Float($0) }

    /// 线性 P3 → 线性 sRGB；`clampToGamut` 时把超出 sRGB 色域的分量钳到 0…1（与平台"画到 sRGB 上下文"一致）。
    @inlinable
    public static func toLinearSRGB(_ p: LinearRGB, clampToGamut: Bool = true) -> LinearRGB {
        let r = m[0] * p.r + m[1] * p.g + m[2] * p.b
        let g = m[3] * p.r + m[4] * p.g + m[5] * p.b
        let b = m[6] * p.r + m[7] * p.g + m[8] * p.b
        if !clampToGamut { return LinearRGB(r: r, g: g, b: b) }
        return LinearRGB(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1))
    }

    // MARK: 推导

    static func rgbToXYZ(r: (Double, Double), g: (Double, Double), b: (Double, Double)) -> [Double] {
        func xyz(_ c: (Double, Double)) -> [Double] { [c.0 / c.1, 1, (1 - c.0 - c.1) / c.1] }
        let xr = xyz(r), xg = xyz(g), xb = xyz(b)
        let w = xyz((0.3127, 0.3290))
        // P = [xr xg xb]（列），S = P⁻¹ · W
        let p: [Double] = [xr[0], xg[0], xb[0], xr[1], xg[1], xb[1], xr[2], xg[2], xb[2]]
        let inv = inverse(p)
        let s = [inv[0] * w[0] + inv[1] * w[1] + inv[2] * w[2],
                 inv[3] * w[0] + inv[4] * w[1] + inv[5] * w[2],
                 inv[6] * w[0] + inv[7] * w[1] + inv[8] * w[2]]
        return [p[0] * s[0], p[1] * s[1], p[2] * s[2],
                p[3] * s[0], p[4] * s[1], p[5] * s[2],
                p[6] * s[0], p[7] * s[1], p[8] * s[2]]
    }

    static func inverse(_ a: [Double]) -> [Double] {
        let det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
        return [
            (a[4] * a[8] - a[5] * a[7]) / det, (a[2] * a[7] - a[1] * a[8]) / det, (a[1] * a[5] - a[2] * a[4]) / det,
            (a[5] * a[6] - a[3] * a[8]) / det, (a[0] * a[8] - a[2] * a[6]) / det, (a[2] * a[3] - a[0] * a[5]) / det,
            (a[3] * a[7] - a[4] * a[6]) / det, (a[1] * a[6] - a[0] * a[7]) / det, (a[0] * a[4] - a[1] * a[3]) / det,
        ]
    }

    static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var o = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { o[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j] } } }
        return o
    }
}
