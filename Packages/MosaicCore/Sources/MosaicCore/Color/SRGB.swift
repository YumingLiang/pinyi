import Foundation

/// sRGB 传递函数（IEC 61966-2-1）：编码值 ↔ 线性光。
///
/// 输入/输出均为 0…1 的归一化值。目标图若为 Display P3，需在平台层先转换到 sRGB
/// （技术方案 §2.1），本模块只处理 sRGB。
public enum SRGB {
    /// 把 sRGB 编码分量（0…1）解码为线性光分量。
    @inlinable
    public static func toLinear(_ c: Float) -> Float {
        if c <= 0.04045 { return c / 12.92 }
        return pow((c + 0.055) / 1.055, 2.4)
    }

    /// 把线性光分量编码为 sRGB 分量（0…1）。负值按线性段处理。
    @inlinable
    public static func fromLinear(_ c: Float) -> Float {
        if c <= 0.0031308 { return c * 12.92 }
        return 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// 8 位 sRGB 值 → 线性光的查找表（256 项），用于逐像素快速解码。
    public static let linearLUT: [Float] = (0..<256).map { toLinear(Float($0) / 255) }

    /// 用查找表把 8 位 sRGB 分量解码为线性光。
    @inlinable
    public static func linear(fromByte value: UInt8) -> Float {
        linearLUT[Int(value)]
    }
}

/// 线性 sRGB 颜色（sRGB 原色、D65 白点、线性光）。
public struct LinearRGB: Hashable, Sendable {
    /// 红色分量（线性光，通常 0…1）。
    public var r: Float
    /// 绿色分量（线性光，通常 0…1）。
    public var g: Float
    /// 蓝色分量（线性光，通常 0…1）。
    public var b: Float

    /// 直接用线性分量构造。
    public init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// 从 sRGB 编码值（0…1）构造：先做 sRGB 解码（线性化）。
    public init(srgbRed r: Float, green g: Float, blue b: Float) {
        self.init(r: SRGB.toLinear(r), g: SRGB.toLinear(g), b: SRGB.toLinear(b))
    }

    /// 从 8 位 sRGB 值构造（查表线性化）。
    public init(srgb8Red r: UInt8, green g: UInt8, blue b: UInt8) {
        self.init(r: SRGB.linear(fromByte: r), g: SRGB.linear(fromByte: g), b: SRGB.linear(fromByte: b))
    }

    /// 编码回 sRGB（0…1，未裁剪）。
    public var srgb: (r: Float, g: Float, b: Float) {
        (SRGB.fromLinear(r), SRGB.fromLinear(g), SRGB.fromLinear(b))
    }
}
