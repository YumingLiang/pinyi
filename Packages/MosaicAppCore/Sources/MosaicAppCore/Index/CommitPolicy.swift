/// 扫描期间何时把内存里的新行落盘（评审 d6fa750 MF-4）。
///
/// 整表重写是 O(n)，首扫 10 万张时按旧规则（每 8 s 一次、不看行数）会累计重写约 57× n。新规则：
/// - **占空比**：距上次提交须 ≥ `dutyFactor` × 上次提交耗时（20 ⇒ 提交占扫描时间约 ≤ 5%）；
/// - **行数触发**：新行 ≥ max(`minRowsForSizeTrigger`, 表长 × 10%)，总写入量 O(n log n)；
/// - **时间触发**：距上次提交 ≥ max(`minInterval`, `dutyFactor` × 上次提交耗时)，且新行 ≥ `minRowsForTimedCommit`（300）；
/// - 最后一批总是提交（被取消时由调用方另行尽力提交）。
public struct CommitPolicy: Sendable, Hashable {
    public var minRowsForSizeTrigger: Int
    public var sizeTriggerFraction: Double
    public var minRowsForTimedCommit: Int
    public var minInterval: Double
    public var dutyFactor: Double

    public init(minRowsForSizeTrigger: Int = 1000, sizeTriggerFraction: Double = 0.1, minRowsForTimedCommit: Int = 300,
                minInterval: Double = 8, dutyFactor: Double = 20) {
        self.minRowsForSizeTrigger = minRowsForSizeTrigger
        self.sizeTriggerFraction = sizeTriggerFraction
        self.minRowsForTimedCommit = minRowsForTimedCommit
        self.minInterval = minInterval
        self.dutyFactor = dutyFactor
    }

    /// 时间触发的间隔：max(8 s, 20 × 上次提交耗时)。
    public func timedInterval(lastCommitSeconds: Double) -> Double {
        max(minInterval, dutyFactor * max(0, lastCommitSeconds))
    }

    /// 行数触发阈值：max(1000, 表长 × 10%)。
    public func sizeThreshold(tableCount: Int) -> Int {
        max(minRowsForSizeTrigger, Int(Double(max(0, tableCount)) * sizeTriggerFraction))
    }

    public func shouldCommit(uncommitted: Int, tableCount: Int, secondsSinceLastCommit: Double,
                             lastCommitSeconds: Double, isLastBatch: Bool) -> Bool {
        guard uncommitted > 0 else { return false }
        if isLastBatch { return true }
        // 占空比约束对两种触发都生效
        guard secondsSinceLastCommit >= dutyFactor * max(0, lastCommitSeconds) else { return false }
        if uncommitted >= sizeThreshold(tableCount: tableCount) { return true }
        return uncommitted >= minRowsForTimedCommit
            && secondsSinceLastCommit >= timedInterval(lastCommitSeconds: lastCommitSeconds)
    }
}
