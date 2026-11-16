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

    public init(initialSeed: UInt64) { generation = GenerationMachine(initialSeed: initialSeed) }

    public enum Event: Sendable, Hashable {
        case targetLoaded
        case targetFailed
        case next
        case back
    }

    public mutating func send(_ e: Event) {
        switch e {
        case .targetLoaded:
            hasTarget = true
            targetNotice = nil
        case .targetFailed:
            hasTarget = false
            targetNotice = .targetUnreadable
        case .next:
            switch step {
            case .target where hasTarget: step = .source
            case .source: step = .settings
            default: break
            }
        case .back:
            switch step {
            case .source: step = .target
            case .settings: step = .source
            case .result: step = .settings
            case .target: break
            }
        }
    }

    /// 生成状态机进入 / 离开结果页时同步导航。
    public mutating func syncWithGeneration() {
        if case .result = generation.phase { step = .result } else if step == .result { step = .settings }
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
