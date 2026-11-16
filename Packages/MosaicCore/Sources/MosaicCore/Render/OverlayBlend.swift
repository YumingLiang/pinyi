/// 原图叠加（技术方案 v0.2 §3.5，A-19）：最终像素 = (1 − α)·块像素 + α·目标图对应像素，α ∈ [0, 0.3]。
///
/// - 在 **sRGB 编码值** 上逐通道混合，与 iOS 预览（`CGContext` 以 alpha 画一层降采样目标图）一致，
///   预览与导出用同一公式（导出在分条渲染时逐条调用本函数或同等的 CG 混合）。
/// - 结果四舍五入到 8 位；α 超出范围时钳到 [0, 0.3]，NaN 视为 0。
/// - 颜色迁移（OKLab 均值平移）属 v0.2/TF2 开关，**本类型不提供、默认不启用**。
public enum OverlayBlend {
    /// α 上限（产品：0–30%）。
    public static let maxAlpha: Float = 0.3

    /// 把 α 钳到 [0, 0.3]。
    public static func clampAlpha(_ alpha: Float) -> Float {
        guard alpha.isFinite else { return alpha == .infinity ? maxAlpha : 0 }
        return min(max(alpha, 0), maxAlpha)
    }

    /// 单通道混合。
    @inlinable
    public static func blend(tile: UInt8, target: UInt8, alpha: Float) -> UInt8 {
        let a = clampAlpha(alpha)
        let v = (1 - a) * Float(tile) + a * Float(target)
        return UInt8(min(max(v.rounded(), 0), 255))
    }

    /// 三通道混合。
    public static func blend(tile: (r: UInt8, g: UInt8, b: UInt8), target: (r: UInt8, g: UInt8, b: UInt8),
                             alpha: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        (blend(tile: tile.r, target: target.r, alpha: alpha),
         blend(tile: tile.g, target: target.g, alpha: alpha),
         blend(tile: tile.b, target: target.b, alpha: alpha))
    }

    /// 整块混合：两张同尺寸缓冲区（任意通道布局）→ 新的 RGBA8 缓冲区（alpha = 255）。
    /// - Throws: 尺寸不同时抛 `MosaicError.invalidPixelBuffer`。
    public static func blend(tile: PixelBuffer, target: PixelBuffer, alpha: Float) throws -> PixelBuffer {
        guard tile.width == target.width, tile.height == target.height else {
            throw MosaicError.invalidPixelBuffer("overlay size mismatch \(tile.width)×\(tile.height) vs \(target.width)×\(target.height)")
        }
        var out = [UInt8](repeating: 255, count: tile.width * tile.height * 4)
        for y in 0..<tile.height {
            for x in 0..<tile.width {
                let c = blend(tile: tile.rgb(x: x, y: y), target: target.rgb(x: x, y: y), alpha: alpha)
                let o = (y * tile.width + x) * 4
                out[o] = c.r; out[o + 1] = c.g; out[o + 2] = c.b
            }
        }
        return try PixelBuffer(width: tile.width, height: tile.height, layout: .rgba8, colorSpace: tile.colorSpace, bytes: out)
    }
}
