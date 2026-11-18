/// 相册变化去抖（技术方案 §2.5：`photoLibraryDidChange` 频繁触发，2 s 内合并为一次全量 diff）。
///
/// 纯逻辑、时间由调用方传入（单调秒），便于测试；平台层用定时器在 `nextFireTime` 调 `fire(now:)`。
public struct ChangeDebouncer: Sendable, Hashable {
    public var interval: Double
    /// 第一次未处理变化的时间。
    public private(set) var firstPending: Double?
    /// 最近一次变化的时间。
    public private(set) var lastPending: Double?
    /// 连续变化时最长等待（避免一直被推迟）。
    public var maxDelay: Double

    public init(interval: Double = 2, maxDelay: Double = 10) {
        self.interval = interval
        self.maxDelay = maxDelay
    }

    public var hasPending: Bool { lastPending != nil }

    public mutating func noteChange(at now: Double) {
        if firstPending == nil { firstPending = now }
        lastPending = now
    }

    /// 应当触发的时间点；无待处理变化时 nil。
    public var nextFireTime: Double? {
        guard let first = firstPending, let last = lastPending else { return nil }
        return min(last + interval, first + maxDelay)
    }

    /// 到点则清空并返回 true（调用方随后做一次全量 diff）。
    public mutating func fire(now: Double) -> Bool {
        guard let t = nextFireTime, now >= t else { return false }
        firstPending = nil
        lastPending = nil
        return true
    }
}
