import Foundation

/// 显式的协作式取消令牌（技术方案 v0.2 §5.1：生成被挂起/后台到期时取消，回前台用同一种子重跑）。
///
/// - 线程安全，可在任意线程 `cancel()`；内核的并行工作线程也会轮询它
///   （工作线程不在 Swift Task 上下文里，读不到 `Task.isCancelled`，所以需要令牌）。
/// - 与 Swift 结构化并发对接：`async` 入口用 `withTaskCancellationHandler` 把 Task 取消转成 `cancel()`，
///   同步入口在调用线程上同时检查 `Task.isCancelled`。
/// - 取消后所有入口抛 `CancellationError`，**不返回任何半成品**；取消不影响随机数序列，重跑同种子结果一致。
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    /// 创建未取消的令牌。
    public init() {}

    /// 请求取消（幂等）。
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// 是否已请求取消。
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// 一次长任务的取消/进度控制（内部使用，把令牌、Task 取消、进度回调合在一起）。
struct CancellationCheck: Sendable {
    let token: CancellationToken?

    /// 令牌已取消，或当前线程所在 Task 已取消。
    @inline(__always)
    var isCancelled: Bool {
        (token?.isCancelled ?? false) || Task.isCancelled
    }

    /// 已取消则抛 `CancellationError`。
    @inline(__always)
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// 生成进度。
public struct MosaicProgress: Sendable, Hashable {
    /// 阶段。
    public enum Phase: Int, Sendable, Hashable, CaseIterable {
        /// 目标图每格取样。
        case sampling
        /// top‑k 匹配。
        case matching
        /// 约束贪心分配。
        case assigning
    }
    /// 当前阶段。
    public var phase: Phase
    /// 本阶段已完成单位数。
    public var completed: Int
    /// 本阶段总单位数。
    public var total: Int

    /// 创建进度值。
    public init(phase: Phase, completed: Int, total: Int) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    /// 本阶段完成比例 0…1。
    public var phaseFraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }

    /// 粗略的整体完成比例（取样 5% / 匹配 60% / 分配 35%，仅供进度条显示）。
    public var overallFraction: Double {
        let weights: [Double] = [0.05, 0.60, 0.35]
        let before = weights.prefix(phase.rawValue).reduce(0, +)
        return min(1, before + weights[phase.rawValue] * phaseFraction)
    }
}

/// 进度回调。可能在任意线程（包括内核工作线程）调用，实现须线程安全且尽快返回；
/// 同一阶段内 `completed` 单调不减，但相邻两次回调不保证在同一线程。
public typealias MosaicProgressHandler = @Sendable (MosaicProgress) -> Void
