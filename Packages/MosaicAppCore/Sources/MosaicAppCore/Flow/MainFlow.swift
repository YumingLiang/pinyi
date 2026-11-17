/// 主流程导航（T9）：选目标图 → 选来源 → 密度 / 叠加 → 生成（进度 + 取消）→ 结果页。
public struct MainFlow: Sendable, Hashable {
    public enum Step: Int, Sendable, Hashable, Comparable, CaseIterable {
        case target, source, settings, result
        public static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    public private(set) var step: Step = .target
    /// 已选并成功解码目标图（像素本身由平台层持有）。
    public private(set) var hasTarget = false
    /// 目标图读不出来（`target.unreadable`）。
    public private(set) var targetNotice: L10nKey?
    public var source = SourcePickerState()
    public var settings = GenerationSettings()
    public var generation: GenerationMachine
    /// 「再拼一张」进行中（需求 v0.4 §2e）：已离开预览页去选新目标图 / 确认页，但上一张结果**还在**——
    /// 在选图页返回就回到原预览页；真正开始生成新图时（协调器 `commitQuickAgain`）才结束这个状态、丢弃旧结果。
    public private(set) var isQuickAgain = false
    /// 进入「再拼一张」前是否已有目标图（返回预览页时恢复）。
    private var hasTargetBeforeQuickAgain = false

    public init(initialSeed: UInt64) { generation = GenerationMachine(initialSeed: initialSeed) }

    public enum Event: Sendable, Hashable {
        case targetLoaded
        case targetFailed
        case next
        case back
        /// 预览页「再拼一张」（未保存提示已处理完之后）：去选目标图，上一张结果保留。
        case quickAgainStarted
        /// 确认页「换素材」：去来源页，选完回确认页。
        case changeSource
    }

    public mutating func send(_ e: Event) {
        switch e {
        case .targetLoaded:
            hasTarget = true
            targetNotice = nil
            // 2b：再拼一张选好照片直接进确认页（素材沿用上次），保证 ≤ 3 次点击。
            if isQuickAgain, step == .target { step = .settings }
        case .targetFailed:
            hasTarget = false
            targetNotice = .targetUnreadable
        case .next:
            switch step {
            case .target where hasTarget: step = isQuickAgain ? .settings : .source
            case .source: step = .settings
            default: break
            }
        case .back:
            if isQuickAgain {
                switch step {
                case .target:
                    // 回到原预览页：结果、「已存」状态都没动过。
                    isQuickAgain = false
                    hasTarget = hasTargetBeforeQuickAgain
                    targetNotice = nil
                    step = .result
                case .settings: step = .target
                case .source: step = .settings
                case .result: break
                }
                return
            }
            switch step {
            case .source: step = .target
            case .settings: step = .source
            case .result: step = .settings
            case .target: break
            }
        case .quickAgainStarted:
            guard step == .result, case .result = generation.phase else { return }
            hasTargetBeforeQuickAgain = hasTarget
            isQuickAgain = true
            hasTarget = false
            targetNotice = nil
            step = .target
        case .changeSource:
            if step == .settings { step = .source }
        }
    }

    /// 「再拼一张」真正开始生成新图：结束保留旧结果的状态（协调器同时丢弃旧结果和预览位图）。
    public mutating func commitQuickAgain() {
        isQuickAgain = false
    }

    /// 离开结果页、回到首页（选目标图）：旧结果已由协调器丢弃。
    public mutating func returnToStart() {
        isQuickAgain = false
        hasTarget = false
        targetNotice = nil
        step = .target
    }

    /// 生成状态机进入 / 离开结果页时同步导航。「再拼一张」期间结果仍在（phase 仍是 `.result`），不把页面拉回预览页。
    public mutating func syncWithGeneration() {
        if case .result = generation.phase {
            if !isQuickAgain { step = .result }
        } else if step == .result {
            step = .settings
        }
    }

    public var targetButtonKey: L10nKey { hasTarget ? .targetReplace : .targetChoose }
    public var canGoNextFromTarget: Bool { hasTarget }
}

/// 点「开始拼图」时的闸门：空状态 / 先等扫描 / 可以开始。
public enum GenerateGate: Sendable, Hashable {
    case emptyState(LibraryEmptyState)
    /// 跳到扫描页，等到可用 ≥ 2,000 或扫描完成。
    case waitForScan
    /// 可以开始；`available` = 当前来源快照的可用张数（交给 `GenerationMachine.startTapped`）。
    case proceed(available: Int)

    /// - Parameters:
    ///   - availableInSource: 当前来源已扫描可用张数。
    ///   - sourceAssetTotal: 当前来源资产总数（全部照片 = `status.assetTotal`；相簿 = 相簿资产数）。
    public static func decide(status: IndexStatus, availableInSource: Int, sourceAssetTotal: Int) -> GenerateGate {
        if let e = LibraryEmptyState.evaluate(status) { return .emptyState(e) }
        let complete = SourceListLogic.isScanComplete(status)
        if complete {
            // 来源（相簿）内一张可用的都没有：沿用全库空状态的分类。
            if availableInSource == 0 {
                return .emptyState(sourceAssetTotal == 0 ? .noPhotos : .notDownloaded)
            }
            return .proceed(available: availableInSource)
        }
        if availableInSource >= ScanFlow.progressiveThreshold { return .proceed(available: availableInSource) }
        return .waitForScan
    }
}
