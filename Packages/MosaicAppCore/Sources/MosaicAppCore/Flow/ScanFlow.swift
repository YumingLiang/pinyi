/// 扫描页状态机（T5 / 文案 §6、决定 5、渐进可用 2,000 张）。
public struct ScanFlow: Sendable, Hashable {
    /// 渐进可用阈值（决定：扫描到 2,000 张即可开始生成）。
    public static let progressiveThreshold = 2000

    public enum Phase: Sendable, Hashable {
        case idle
        case scanning
        /// 用户点了「取消」，等待确认（扫描在后台继续）。
        case confirmingCancel
        /// 用户确认停止（`misc.scan_stopped`）。
        case stopped
        /// 进后台宽限期到期：暂停，回前台自动继续、不提示（决定 5）。
        case pausedInBackground
        case completed
        case failed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var progress = ScanProgress(processed: 0, total: 0, availableCount: 0, skippedUnavailable: 0, isResuming: false)
    /// 是否是首次扫描（显示 `scan.first_time_hint`）。
    public private(set) var isFirstScan = false

    public init() {}

    public enum Event: Sendable, Hashable {
        case started(isFirstScan: Bool, isResuming: Bool)
        case progressed(ScanProgress)
        case cancelTapped
        case cancelConfirmed
        case cancelDismissed
        case backgroundExpired
        case becameActive
        case finished
        case failed
    }

    public enum Effect: Sendable, Hashable {
        case startScan
        case cancelScan
    }

    @discardableResult
    public mutating func send(_ e: Event) -> [Effect] {
        switch (phase, e) {
        case (_, .started(let first, let resuming)):
            phase = .scanning
            isFirstScan = first
            progress.isResuming = resuming
            return []
        case (.scanning, .progressed(let p)), (.confirmingCancel, .progressed(let p)):
            progress = p
            return []
        case (.scanning, .cancelTapped):
            phase = .confirmingCancel
            return []
        case (.confirmingCancel, .cancelDismissed):
            phase = .scanning
            return []
        case (.confirmingCancel, .cancelConfirmed):
            phase = .stopped
            return [.cancelScan]
        case (.scanning, .backgroundExpired), (.confirmingCancel, .backgroundExpired):
            phase = .pausedInBackground
            return [.cancelScan]
        case (.pausedInBackground, .becameActive):
            phase = .scanning
            progress.isResuming = false   // 回前台继续不提示
            return [.startScan]
        case (.scanning, .finished), (.confirmingCancel, .finished):
            phase = .completed
            return []
        case (.scanning, .failed), (.confirmingCancel, .failed):
            phase = .failed
            return []
        default:
            return []
        }
    }

    /// 标题行：被杀后续扫显示「接着上次继续扫描」，否则「正在整理照片」。
    public var titleKey: L10nKey { progress.isResuming ? .scanResume : .scanTitle }

    public var progressLine: LocalizedLine {
        LocalizedLine(.scanProgress, [CountFormat.grouped(progress.processed), CountFormat.grouped(progress.total)])
    }

    /// 渐进可用：已就绪 ≥ 2,000 张且仍在扫描时，显示「已就绪 N 张，可以开始拼图」+ CTA。
    public var progressiveReadyLine: LocalizedLine? {
        guard canStartGenerationEarly else { return nil }
        return LocalizedLine(.scanProgressiveReady, [CountFormat.grouped(progress.availableCount)])
    }

    public var canStartGenerationEarly: Bool {
        (phase == .scanning || phase == .confirmingCancel) && progress.availableCount >= Self.progressiveThreshold
    }

    /// 停止后：若已有可用照片，可以「先用已经整理好的照片」。
    public var canUsePartialAfterStop: Bool { phase == .stopped && progress.availableCount > 0 }
}
