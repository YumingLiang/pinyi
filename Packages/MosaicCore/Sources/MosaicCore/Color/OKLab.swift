import Foundation

/// OKLab 颜色（Björn Ottosson, 2020）。
///
/// - `L`：感知亮度，约 0（黑）… 1（白）。
/// - `a`：绿(−) ↔ 红(+)，sRGB 色域内约 −0.24…0.28。
/// - `b`：蓝(−) ↔ 黄(+)，sRGB 色域内约 −0.32…0.2。
///
/// 转换由「线性 sRGB → LMS（3×3 矩阵）→ 立方根 → OKLab（3×3 矩阵）」构成，
/// 欧氏距离即可近似感知色差（技术方案 §3.1）。
public struct OKLab: Hashable, Sendable {
    /// 感知亮度。
    public var L: Float
    /// 绿–红轴。
    public var a: Float
    /// 蓝–黄轴。
    public var b: Float

    /// 用分量直接构造。
    public init(L: Float, a: Float, b: Float) {
        self.L = L
        self.a = a
        self.b = b
    }

    /// 从线性 sRGB 转换到 OKLab。
    public init(_ rgb: LinearRGB) {
        let l = 0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b
        let m = 0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b
        let s = 0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b

        let l_ = PortableMath.cbrt(l)
        let m_ = PortableMath.cbrt(m)
        let s_ = PortableMath.cbrt(s)

        L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    }

    /// 只算感知亮度 L（省掉 a/b 的矩阵运算；与 `OKLab(rgb).L` 逐位相同）。
    @inlinable
    public static func lightness(_ rgb: LinearRGB) -> Float {
        let l = 0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b
        let m = 0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b
        let s = 0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b
        return 0.2104542553 * PortableMath.cbrt(l) + 0.7936177850 * PortableMath.cbrt(m) - 0.0040720468 * PortableMath.cbrt(s)
    }

    /// 从 sRGB 编码值（0…1）转换：sRGB → 线性 → OKLab。
    public init(srgbRed r: Float, green g: Float, blue b: Float) {
        self.init(LinearRGB(srgbRed: r, green: g, blue: b))
    }

    /// 转回线性 sRGB（可能超出 0…1，未裁剪）。
    public var linearRGB: LinearRGB {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b

        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        return LinearRGB(
            r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// 以 `SIMD3(L, a, b)` 形式返回。
    public var simd: SIMD3<Float> { SIMD3(L, a, b) }

    /// 与另一颜色的平方欧氏距离。
    public func squaredDistance(to other: OKLab) -> Float {
        let d = simd - other.simd
        return (d * d).sum()
    }
}
