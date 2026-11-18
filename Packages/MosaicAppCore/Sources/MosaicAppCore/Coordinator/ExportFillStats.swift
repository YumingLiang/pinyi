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

    /// 形状外的格子不记入糊格 / 白格。导出循环和测试都走这个入口。
    public mutating func record(step: ShapeStripExport.Step, fill: Fill) {
        guard step.countsInFillStats else { return }
        add(fill)
    }

    /// 取图结果分类：高清成功优先，否则退回扫描缩略图，都没有则为空白。
    /// 不区分「资产是否可见」；导出路径请用 `decision(afterHighQuality:)`。
    public static func fill(highQuality: Bool, scanThumbnail: Bool) -> Fill {
        if highQuality { return .highQuality }
        if scanThumbnail { return .blurryFallback }
        return .blank
    }

    /// 高清请求之后的下一步（导出 / 清晰层共用）。
    ///
    /// - `.image`：用高清图。
    /// - `.missing`：隐藏 / 删除 / PhotoFetch 取不到 → 直接空白，**不走** 128px 兜底
    ///   （QA：即使 `.scanDisplay` 仍能从缓存取到，也不能把隐藏照片画出去）。
    /// - `.unavailableLocal` / `.failed`：资产仍在，高清失败（例如 iCloud 原图未下载、解码失败）
    ///   → 再试 `.scanDisplay`；再失败才空白。
    public static func decision(afterHighQuality result: ThumbnailResult) -> ExportCellDecision {
        switch result {
        case .image: return .highQuality
        case .missing: return .blank
        case .unavailableLocal, .failed: return .tryScanDisplay
        }
    }

    /// 由高清结果 + 128px 是否取到，得到最终填格类别（纯函数，供 Linux 测试）。
    public static func fill(afterHighQuality result: ThumbnailResult, scanThumbnail: Bool) -> Fill {
        switch decision(afterHighQuality: result) {
        case .highQuality: return .highQuality
        case .blank: return .blank
        case .tryScanDisplay: return scanThumbnail ? .blurryFallback : .blank
        }
    }
}

/// `ExportFillStats.decision(afterHighQuality:)` 的下一步。
public enum ExportCellDecision: Sendable, Hashable {
    /// 使用高清请求拿到的图。
    case highQuality
    /// 再试 `.scanDisplay`（128 px）。仅当资产可见、高清失败时。
    case tryScanDisplay
    /// 直接白格子，不再取图。
    case blank
}
