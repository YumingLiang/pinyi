/// 性能页入口（决定 18）：内部构建按编译条件（`PERF_PAGE`）在设置页显示；上架版只保留「关于」页连点版本号 5 次进入。
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

/// 构建配置相关开关（平台层在启动时用 `#if PERF_PAGE` 决定传入值）。
public struct BuildFlags: Sendable, Hashable {
    public var showsPerformanceEntryInSettings: Bool
    public init(showsPerformanceEntryInSettings: Bool) { self.showsPerformanceEntryInSettings = showsPerformanceEntryInSettings }
}
