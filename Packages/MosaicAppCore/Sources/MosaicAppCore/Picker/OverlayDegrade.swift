import Foundation

// MARK: - 目标图本机版本较小时，叠加层静默降级（photo-picker-v0.1 §6.1；需求 v0.4 §4.7）
//
// 只降叠加强度的上限，用户滑块位置不变：实际 alpha = min(用户值, OverlayBlendLimits.maxAlpha × k)。
// 不弹提示（§5.2）。门槛按「有效长边」s 算：裁剪后实际用到的那块区域的长边（px），不是整张图。

public enum OverlayDegrade {
    /// 分段门槛（px）。默认值是设计 §6.1 的定值；T7 真机实测后可能要调，改 `standard` 一处即可。
    public struct Thresholds: Sendable, Hashable {
        /// s ≥ full：k = 1。
        public let full: Double
        /// half ≤ s < full：k 从 0.5 线性升到 1。
        public let half: Double
        /// zero ≤ s < half：k 从 0 线性升到 0.5；s < zero：k = 0。
        public let zero: Double

        /// 要求 `0 ≤ zero < half < full`，且都是有限数；不满足返回 nil。
        public init?(full: Double, half: Double, zero: Double) {
            guard full.isFinite, half.isFinite, zero.isFinite, zero >= 0, zero < half, half < full else { return nil }
            self.full = full
            self.half = half
            self.zero = zero
        }

        private init(uncheckedFull full: Double, half: Double, zero: Double) {
            self.full = full
            self.half = half
            self.zero = zero
        }

        /// 设计 §6.1：1024 / 480 / 160。
        public static let standard = Thresholds(uncheckedFull: 1024, half: 480, zero: 160)
    }

    /// 降级系数 k ∈ [0, 1]，随 s 单调不减、分段连续（在 `half` 处两段都等于 0.5，在 `zero` 处等于 0）。
    ///
    /// 非法输入：NaN 和负数按「拿不到可用尺寸」处理，返回 0（只定颜色和布局，最保守）；+∞ 返回 1。
    public static func factor(effectiveLongSide s: Double, thresholds t: Thresholds = .standard) -> Double {
        if s.isNaN { return 0 }
        if s >= t.full { return 1 }
        if s >= t.half { return 0.5 + 0.5 * (s - t.half) / (t.full - t.half) }
        if s >= t.zero { return 0.5 * (s - t.zero) / (t.half - t.zero) }
        return 0
    }

    /// 实际叠加强度 = min(用户值, `OverlayBlendLimits.maxAlpha` × k)，结果在 [0, maxAlpha]。
    ///
    /// 用户值先按 `OverlayBlendLimits` 夹到 [0, maxAlpha]；用户值 NaN → 0、+∞ → maxAlpha
    /// （与 MosaicCore `OverlayBlend.clampAlpha` 一致；`OverlayBlendLimits.clamp` 本身不处理 NaN，这里不依赖它）。
    public static func effectiveAlpha(user: Double, effectiveLongSide s: Double,
                                      thresholds t: Thresholds = .standard) -> Double {
        let u: Double
        if user.isNaN { u = 0 } else { u = min(max(user, 0), OverlayBlendLimits.maxAlpha) }
        return min(u, OverlayBlendLimits.maxAlpha * factor(effectiveLongSide: s, thresholds: t))
    }
}
