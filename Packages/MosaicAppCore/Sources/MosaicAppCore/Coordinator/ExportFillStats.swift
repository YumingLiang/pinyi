/// 紧急版导出里，每个格子最终是高清图、退回 128px 扫描缩略图，还是空白。
/// 供日志和内测性能页使用（界面文案不进文案表）。
public struct ExportFillStats: Sendable, Hashable {
    public enum Fill: Sendable, Hashable {
        /// 档位目标尺寸的高清图画上了。
        case highQuality
        /// 高清取不到，退回 `.scan`（128 px）缩略图——可能偏糊。
        case blurryFallback
        /// 没有任何图画上（取图失败、没有资产，或位图转换失败）。
        case blank
    }

    public var highQuality: Int
    public var blurryFallback: Int
    public var blank: Int

    public init(highQuality: Int = 0, blurryFallback: Int = 0, blank: Int = 0) {
        self.highQuality = max(0, highQuality)
        self.blurryFallback = max(0, blurryFallback)
        self.blank = max(0, blank)
    }

    public var total: Int { highQuality + blurryFallback + blank }

    /// 日志 / 性能页用，不含任何资产标识。
    public var logDescription: String {
        "糊格子 \(blurryFallback) 白格子 \(blank)"
    }

    public mutating func add(_ fill: Fill) {
        switch fill {
        case .highQuality: highQuality += 1
        case .blurryFallback: blurryFallback += 1
        case .blank: blank += 1
        }
    }

    /// 取图结果分类：高清成功优先，否则退回扫描缩略图，都没有则为空白。
    public static func fill(highQuality: Bool, scanThumbnail: Bool) -> Fill {
        if highQuality { return .highQuality }
        if scanThumbnail { return .blurryFallback }
        return .blank
    }
}
