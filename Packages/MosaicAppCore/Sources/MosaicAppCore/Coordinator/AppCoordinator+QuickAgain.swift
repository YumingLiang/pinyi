import Foundation
import MosaicCore

/// 「存到我的作品」的问答接口（App 里由 `WorksController` 实现）。未保存提示用：当前结果要不要提示、点「保存」去存。
@MainActor
public protocol CurrentResultSaving: AnyObject {
    /// 当前结果 vs 作品库（和「存到我的作品」按钮同一口径）：`.none` 已存且没改；`.unsaved` 没存（导出过不算存过）；
    /// `.alphaChanged(id)` 存过但只改了叠加强度还没存。
    var unsavedPrompt: UnsavedPrompt { get }
    /// 把当前结果存到我的作品（没存过 → 新存；只改了强度 → 更新原作品）；成功返回 true。
    func saveCurrentResult() async -> Bool
}

/// 预览页「再拼一张」（需求 v0.4 §2b / §2e）。判断都在这里（Linux 单测），视图只调方法。
///
/// 流程：点「再拼一张」→（当前结果没存进作品、或存过但强度改了没存时先弹 `quick.unsaved.*`）→ 选目标图 → 确认页（素材沿用上次、
/// 可「换素材」）→「开始拼图」。选图页 / 确认页返回都回到原预览页，结果和「已存」状态不变；
/// **真正开始生成新图时**（`send` 里出现 `.run`）才丢弃旧结果和预览位图。
extension AppCoordinator {
    /// 当前结果要弹哪种未保存提示（hd-export B10-4/11）。导出过不算存过；没接 `resultSaver` 时按「没存」算。
    public var currentUnsavedPrompt: UnsavedPrompt { resultSaver?.unsavedPrompt ?? .unsaved }

    /// 「再调一调」途中：结果还留着（`product`、`lastOutcome` 在，phase 回到 `.idle`），人在设置 / 来源 / 选图页，
    /// 不是「再拼一张」流程。这时离开去开始一张新图同样会丢掉这张结果（验收 7a）。
    public var isAdjustingResult: Bool {
        guard product != nil, state.flow.generation.lastOutcome != nil, case .idle = state.flow.generation.phase,
              !state.flow.isQuickAgain, !state.flow.isFreshQuickStart, state.flow.step != .result else { return false }
        return true
    }

    /// 当前结果算不算「已保存」：已在我的作品里，且叠加强度和存的一样。
    public var isCurrentResultKept: Bool { currentUnsavedPrompt == .none }

    private func ask(_ reason: UnsavedResultPrompt) {
        let kind = currentUnsavedPrompt
        state.unsavedPromptIsUpdate = { if case .alphaChanged = kind { return true }; return false }()
        state.unsavedPrompt = reason
    }

    /// 预览页「再拼一张」。生成中 / 导出中 / 不在结果页时忽略（按钮本来也是禁用的）。
    public func startNewMosaicTapped() {
        guard state.canStartNewMosaic else { return }
        if isCurrentResultKept {
            beginQuickAgain()
        } else {
            ask(.startNew)
        }
    }

    /// 作品查看页「再拼一张」（quick-start v1.0 §2a）。平台层同时把导航栈退回主流程。
    /// - 主流程停在结果页：和预览页「再拼一张」完全一样（同样的未保存提示，选图页返回回到那张预览）。
    /// - 已经在「再拼一张」的选图 / 确认页：不动（平台层退回去就是那里）。
    /// - 「再调一调」途中（`isAdjustingResult`）：这张结果会丢，按同一套规则判断（验收 7a）：已存且没改 → 直接去选图；
    ///   没存 / 存过但只改了强度 → 弹提示（`.startNewFromAdjust`，标题同样区分 update_title），继续 = 去选图。
    /// - 其他（没有结果）：直接去选目标图，选好进确认页（素材沿用）。
    /// 生成中 / 导出中 / 提示弹着或保存中忽略。
    public func startNewFromWorkTapped() {
        guard !state.isGenerating, !state.export.isBusy, state.unsavedPrompt == nil, !state.isSavingBeforeLeaving,
              !state.flow.isQuickAgain else { return }
        if state.canStartNewMosaic {
            startNewMosaicTapped()
            return
        }
        if case .result = state.flow.generation.phase { return }
        if isAdjustingResult, !isCurrentResultKept {
            ask(.startNewFromAdjust)
            return
        }
        beginFreshQuickStart()
    }

    private func beginFreshQuickStart() {
        pendingTarget = nil
        state.flow.send(.freshQuickStartStarted)
    }

    /// 预览页返回首页等会丢掉当前结果的离开方式（「再调一调」「换一种拼法」不走这里）。
    public func leaveResultTapped() {
        guard state.canStartNewMosaic else { return }
        if isCurrentResultKept {
            discardResultAndReturnToStart()
        } else {
            ask(.leaveResult)
        }
    }

    /// 未保存提示「保存」：存成功后继续原来的离开方式；存失败留在预览页（错误由「存到我的作品」按钮下方的 `works.save_failed` 显示）。
    public func unsavedPromptSave() async {
        guard let prompt = state.unsavedPrompt, !state.isSavingBeforeLeaving else { return }
        state.unsavedPrompt = nil
        state.unsavedPromptIsUpdate = false
        state.isSavingBeforeLeaving = true
        let ok = await resultSaver?.saveCurrentResult() ?? false
        state.isSavingBeforeLeaving = false
        guard ok else { return }
        continueLeaving(prompt)
    }

    /// 未保存提示「不保存」。
    public func unsavedPromptDiscard() {
        guard let prompt = state.unsavedPrompt else { return }
        state.unsavedPrompt = nil
        state.unsavedPromptIsUpdate = false
        continueLeaving(prompt)
    }

    /// 未保存提示「取消」：留在预览页，什么都不变。
    public func unsavedPromptCancel() {
        state.unsavedPrompt = nil
        state.unsavedPromptIsUpdate = false
    }

    private func continueLeaving(_ prompt: UnsavedResultPrompt) {
        guard !state.isGenerating, !state.export.isBusy else { return }
        if prompt == .startNewFromAdjust {
            if isAdjustingResult { beginFreshQuickStart() }
            return
        }
        guard case .result = state.flow.generation.phase, state.flow.step == .result else { return }
        switch prompt {
        case .startNew: beginQuickAgain()
        case .leaveResult: discardResultAndReturnToStart()
        case .startNewFromAdjust: break
        }
    }

    /// 去选目标图。结果、预览、「已存」状态都不动（选图页返回还能回来）。
    private func beginQuickAgain() {
        pendingTarget = nil
        state.flow.send(.quickAgainStarted)
    }

    /// 开始生成新图（由 `send` 在 `.run` 之前调用）：丢弃旧结果，换上新目标图。
    func commitQuickAgain() {
        if let t = pendingTarget { target = t; targetGeneration += 1 }
        pendingTarget = nil
        discardResult()
        state.flow.commitQuickAgain()
    }

    private func discardResultAndReturnToStart() {
        pendingTarget = nil
        target = nil
        targetGeneration += 1
        discardResult()
        state.flow.generation.send(.backToSettings)
        state.flow.returnToStart()
    }

    /// 丢掉当前结果：`hasResult` 变 false → 平台层释放预览位图；`resultRevision` +1 → 「存到我的作品」按钮回到初始状态。
    private func discardResult() {
        guard product != nil else { return }
        product = nil
        state.resultRevision += 1
        state.postFilterShortageNotice = false
    }
}
