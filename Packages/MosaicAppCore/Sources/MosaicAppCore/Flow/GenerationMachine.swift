import MosaicCore

/// 生成结果（结果页需要的信息）。
public struct GenerationOutcome: Sendable, Hashable {
    public var seed: UInt64
    /// 结果页是否显示 `shortage.result`（= `MosaicGeneration.shouldShowShortageNotice`：可用 < 200 且实际放宽了约束）。
    public var shouldShowShortageNotice: Bool
    public var cellCount: Int
    /// 清晰度筛选后实际可用的张数（未启用筛选为 nil）。200 张门槛按它判断。
    public var availableAfterFilter: Int?

    public init(seed: UInt64, shouldShowShortageNotice: Bool, cellCount: Int, availableAfterFilter: Int? = nil) {
        self.seed = seed
        self.shouldShowShortageNotice = shouldShowShortageNotice
        self.cellCount = cellCount
        self.availableAfterFilter = availableAfterFilter
    }

    /// 筛选后是否低于 200 张门槛。
    public var isBelowThresholdAfterFilter: Bool {
        availableAfterFilter.map { MaterialSupply.evaluate(availableCount: $0).needsWarning } ?? false
    }

    public init(_ g: MosaicGeneration) {
        self.init(seed: g.seed, shouldShowShortageNotice: g.shouldShowShortageNotice, cellCount: g.layout.cellCount)
    }
}

/// 生成失败的分类（平台层把错误映射过来）。**`CancellationError` 不是失败**（决定 (2)：按正常取消处理，不弹错、不记诊断错误）。
public enum GenerationFailure: Sendable, Hashable {
    /// 可用素材为 0（理论上应先被空状态拦住）。
    case noMaterial
    /// 来源相簿打不开。
    case albumUnreadable
    /// 其他（内存不足 / 读取失败…）→ `generate.failed.*`。
    case other

    public static func classify(_ error: any Error) -> GenerationFailure? {
        if error is CancellationError { return nil }
        if let e = error as? PhotoIndexError, e == .albumUnreadable { return .albumUnreadable }
        if let e = error as? MosaicError, case .noCandidates = e { return .noMaterial }
        if error is NoSharpPhotosError { return .noMaterial }
        return .other
    }
}

/// 生成流程状态机（T9 / 文案 §7、§8，决定 2 / 4 / 5）。纯值类型 reducer，平台层执行 `Effect`。
///
/// 每次运行有递增的 `runID`；平台层回报结果时带上 runID，过期运行的回报一律忽略（例如取消后才到的结果）。
public struct GenerationMachine: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        /// 设置页（密度 / 叠加 / 开始拼图）。
        case idle
        /// 可用 < 200：生成前提示一次（`shortage.pregenerate`），不阻止生成。
        case confirmingShortage(available: Int)
        /// 生成中。`isReshuffle` = 由「换一种拼法」触发（取消后回结果页而不是设置页）。
        case running(runID: Int, seed: UInt64, isReshuffle: Bool)
        /// 生成中点了「取消」，等待确认；生成继续跑。
        case confirmingCancel(runID: Int, seed: UInt64, isReshuffle: Bool)
        /// 被切到后台挂起：已取消本次运行，回前台用同一种子自动重跑。
        case suspended(seed: UInt64, isReshuffle: Bool)
        /// 结果页。
        case result(GenerationOutcome)
        /// 失败页（`generate.failed.*`）。
        case failed(GenerationFailure)
    }

    public enum Event: Sendable, Hashable {
        /// 点「开始拼图」。`available` = 当前来源快照的可用张数。
        case startTapped(available: Int)
        case shortageContinue
        case shortageBack
        case progressed(runID: Int, fraction: Double)
        case cancelTapped
        case cancelConfirmed
        case cancelDismissed
        case succeeded(runID: Int, GenerationOutcome)
        /// 运行抛错（含 `CancellationError`：`failure == nil`）。
        case finishedWithError(runID: Int, failure: GenerationFailure?)
        case enteredBackground
        case becameActive
        /// 结果页「换一种拼法」。
        case reshuffleTapped
        /// 结果页「再调一调」/ 失败页「返回调整」。
        case backToSettings
        /// 失败页「再试一次」/ 设置页 auto-retry 提示上的「再试一次」。
        case retryTapped(available: Int)
    }

    public enum Effect: Sendable, Hashable {
        case run(runID: Int, seed: UInt64)
        case cancel(runID: Int)
        /// 进入 / 离开生成：让扫描降并发（方案 §5）。
        case setGenerationActive(Bool)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var fraction: Double = 0
    /// 设置页上方的提示（`generate.auto_retry_failed`：自动重跑也失败后回设置页）。
    public private(set) var settingsNotice: L10nKey?
    /// 最近一次成功的结果（「换一种拼法」被取消时回到它）。
    public private(set) var lastOutcome: GenerationOutcome?
    private var nextRunID = 1
    private var nextSeed: UInt64
    /// 当前运行是否是"回前台后的自动重跑"。
    private var isAutoRetry = false

    /// - Parameter initialSeed: 首次生成的种子（平台层用系统随机数；测试固定）。
    public init(initialSeed: UInt64) { self.nextSeed = initialSeed }

    public var currentRunID: Int? {
        switch phase {
        case .running(let id, _, _), .confirmingCancel(let id, _, _): return id
        default: return nil
        }
    }

    @discardableResult
    public mutating func send(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (.idle, .startTapped(let n)), (.failed, .retryTapped(let n)), (.idle, .retryTapped(let n)):
            settingsNotice = nil
            if MaterialSupply.evaluate(availableCount: n).needsWarning {
                phase = .confirmingShortage(available: n)
                return []
            }
            if n <= 0 { phase = .failed(.noMaterial); return [] }
            return start(seed: nextSeed, isReshuffle: false)
        case (.confirmingShortage, .shortageContinue):
            return start(seed: nextSeed, isReshuffle: false)
        case (.confirmingShortage, .shortageBack):
            phase = .idle
            return []

        case (.running(let id, _, _), .progressed(let rid, let f)) where id == rid,
             (.confirmingCancel(let id, _, _), .progressed(let rid, let f)) where id == rid:
            fraction = max(fraction, min(1, f))
            return []

        case (.running(let id, let seed, let r), .cancelTapped):
            phase = .confirmingCancel(runID: id, seed: seed, isReshuffle: r)
            return []
        case (.confirmingCancel(let id, let seed, let r), .cancelDismissed):
            phase = .running(runID: id, seed: seed, isReshuffle: r)
            return []
        case (.confirmingCancel(let id, _, let r), .cancelConfirmed):
            phase = r ? (lastOutcome.map { .result($0) } ?? .idle) : .idle
            return [.cancel(runID: id), .setGenerationActive(false)]

        case (.running(let id, _, _), .succeeded(let rid, let o)) where id == rid,
             (.confirmingCancel(let id, _, _), .succeeded(let rid, let o)) where id == rid:
            phase = .result(o)
            lastOutcome = o
            nextSeed = MosaicSeed.next(after: o.seed)
            isAutoRetry = false
            return [.setGenerationActive(false)]

        case (.running(let id, let seed, let r), .finishedWithError(let rid, let failure)) where id == rid,
             (.confirmingCancel(let id, let seed, let r), .finishedWithError(let rid, let failure)) where id == rid:
            defer { isAutoRetry = false }
            guard let failure else {
                // CancellationError 但不是用户确认取消（例如系统取消）：按挂起处理，回前台同种子重跑。
                phase = .suspended(seed: seed, isReshuffle: r)
                return [.setGenerationActive(false)]
            }
            if isAutoRetry {
                // 决定 5：自动重跑也失败 → 回到生成前设置页，提示「刚才没拼完，再试一次」。
                phase = .idle
                settingsNotice = .generateAutoRetryFailed
            } else {
                phase = .failed(failure)
            }
            return [.setGenerationActive(false)]

        case (.running(let id, let seed, let r), .enteredBackground),
             (.confirmingCancel(let id, let seed, let r), .enteredBackground):
            phase = .suspended(seed: seed, isReshuffle: r)
            return [.cancel(runID: id), .setGenerationActive(false)]
        case (.suspended(let seed, let r), .becameActive):
            let effects = start(seed: seed, isReshuffle: r)
            isAutoRetry = true
            return effects

        case (.result(let o), .reshuffleTapped):
            return start(seed: MosaicSeed.next(after: o.seed), isReshuffle: true)
        case (.result, .backToSettings), (.failed, .backToSettings):
            phase = .idle
            return []

        default:
            return []
        }
    }

    private mutating func start(seed: UInt64, isReshuffle: Bool) -> [Effect] {
        let id = nextRunID
        nextRunID += 1
        fraction = 0
        isAutoRetry = false
        phase = .running(runID: id, seed: seed, isReshuffle: isReshuffle)
        return [.setGenerationActive(true), .run(runID: id, seed: seed)]
    }

    // MARK: 视图辅助

    public var showsProgress: Bool {
        switch phase {
        case .running, .confirmingCancel: return true
        default: return false
        }
    }

    public var showsCancelConfirm: Bool {
        if case .confirmingCancel = phase { return true }
        return false
    }

    public var shortagePrompt: Bool {
        if case .confirmingShortage = phase { return true }
        return false
    }
}
