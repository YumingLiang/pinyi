/// 「关于」页连点版本号 5 次的隐藏入口（决定 18）。
/// ⚠️ 架构师 2026-11-16 定：性能页整体只在 `INTERNAL_TOOLS`（Debug / Internal 配置）里编译，Release 不含性能页，
/// 因此 Release 里这个连点入口也不编译（与决定 18「上架版保留连点入口」不一致，已提请产品/架构确认）。
public struct HiddenEntryTapCounter: Sendable, Hashable {
    public static let requiredTaps = 5
    /// 两次点击最大间隔（秒）。
    public var maxInterval: Double = 1.0
    public private(set) var count = 0
    private var lastTap: Double?

    public init(maxInterval: Double = 1.0) { self.maxInterval = maxInterval }

    /// 记录一次点击；达到 5 次返回 true 并清零。
    public mutating func tap(at now: Double) -> Bool {
        if let last = lastTap, now - last > maxInterval { count = 0 }
        lastTap = now
        count += 1
        if count >= Self.requiredTaps {
            count = 0
            lastTap = nil
            return true
        }
        return false
    }
}

/// 构建配置相关开关。平台层在启动时用 `#if INTERNAL_TOOLS` 决定 `internalTools`（Debug / Internal 为 true，Release 为 false）。
public struct BuildFlags: Sendable, Hashable {
    /// 编译了内部工具（性能计时页、导出 8000 档、「马赛克测试」相簿开关）。
    public var internalTools: Bool
    public init(internalTools: Bool) { self.internalTools = internalTools }

    /// 决定 18：内部构建在设置页直接显示「性能测试」入口。
    public var showsPerformanceEntryInSettings: Bool { internalTools }
    /// 「关于」页连点 5 次入口：只有编译了性能页才有意义。
    public var allowsHiddenPerformanceEntry: Bool { internalTools }
}
