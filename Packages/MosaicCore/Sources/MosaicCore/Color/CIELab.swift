import Foundation

/// CIELAB（CIE 1976 L*a*b*，D65 白点）颜色。
///
/// 技术方案 §3.1：OKLab 为默认，CIELAB + ΔE76 作为备选，两者都实现以便 A/B。
/// 注意数值尺度与 OKLab 不同（L* 为 0…100），切换颜色空间时惩罚系数 λ 需同步调整。
public struct CIELab: Hashable, Sendable {
    /// 明度 L*（0…100）。
    public var L: Float
    /// a*（绿–红）。
    public var a: Float
    /// b*（蓝–黄）。
    public var b: Float

    /// D65 参考白（2° 观察者），与 sRGB 一致。
    public static let whitePoint = SIMD3<Float>(0.95047, 1.0, 1.08883)

    /// 用分量直接构造。
    public init(L: Float, a: Float, b: Float) {
        self.L = L
        self.a = a
        self.b = b
    }

    /// 从线性 sRGB 转换：线性 sRGB → XYZ(D65) → L*a*b*。
    public init(_ rgb: LinearRGB) {
        // 双精度计算（L* 尺度 0…100，Float 中间量会损失约 1e-4 精度，A-03 要求 ≤ 1e-4）。
        let r = Double(rgb.r), g = Double(rgb.g), bl = Double(rgb.b)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * bl
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * bl
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * bl

        let fx = CIELab.f(x / 0.95047)
        let fy = CIELab.f(y / 1.0)
        let fz = CIELab.f(z / 1.08883)

        L = Float(116 * fy - 16)
        a = Float(500 * (fx - fy))
        b = Float(200 * (fy - fz))
    }

    /// 从 sRGB 编码值（0…1）转换。
    public init(srgbRed r: Float, green g: Float, blue b: Float) {
        self.init(LinearRGB(srgbRed: r, green: g, blue: b))
    }

    /// CIE 分段函数 f(t)。
    @usableFromInline
    static func f(_ t: Double) -> Double {
        let delta = 6.0 / 29.0
        if t > delta * delta * delta { return PortableMath.cbrt(t) }
        return t / (3 * delta * delta) + 4.0 / 29.0
    }

    /// 以 `SIMD3(L, a, b)` 形式返回。
    public var simd: SIMD3<Float> { SIMD3(L, a, b) }

    /// ΔE76 色差的平方（即平方欧氏距离）。
    public func squaredDistance(to other: CIELab) -> Float {
        let d = simd - other.simd
        return (d * d).sum()
    }
}

/// 特征使用的颜色空间。
public enum FeatureColorSpace: String, Sendable, Hashable, CaseIterable {
    /// OKLab（默认）。
    case oklab
    /// CIELAB（D65）。分量按原始尺度（L* 0…100），不做归一化。
    case cielab

    /// 把线性 sRGB 转成该空间的三元组 `(L, a, b)`。
    @inlinable
    public func convert(_ rgb: LinearRGB) -> SIMD3<Float> {
        switch self {
        case .oklab: return OKLab(rgb).simd
        case .cielab: return CIELab(rgb).simd
        }
    }

    /// 只算亮度分量（与 `convert(rgb).x` 相同）。
    @inlinable
    public func lightness(_ rgb: LinearRGB) -> Float {
        switch self {
        case .oklab: return OKLab.lightness(rgb)
        case .cielab: return CIELab(rgb).L
        }
    }

    /// 该空间亮度分量归一化到约 0…1 的比例（OKLab 为 1，CIELAB 为 1/100），
    /// 用于让亮度方差在两种空间下尺度可比。
    @inlinable
    public var lightnessScale: Float {
        switch self {
        case .oklab: return 1
        case .cielab: return 0.01
        }
    }
}
