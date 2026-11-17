import Foundation
import MosaicCore

/// 「存到我的作品」的问答接口（App 里由 `WorksController` 实现）。未保存提示用：当前结果存没存过、点「保存」去存。
@MainActor
public protocol CurrentResultSaving: AnyObject {
    /// 第 `revision` 版结果是否已在「我的作品」里（手动存过，或导出成功后自动存过）。
    func isCurrentResultSaved(revision: Int) -> Bool
    /// 把当前结果存到我的作品；成功返回 true。
    func saveCurrentResult() async -> Bool
}

/// 预览页「再拼一张」（需求 v0.4 §2b / §2e）。判断都在这里（Linux 单测），视图只调方法。
///
/// 流程：点「再拼一张」→（当前结果既没导出过也没存过时先弹 `quick.unsaved.*`）→ 选目标图 → 确认页（素材沿用上次、
/// 可「换素材」）→「开始拼图」。选图页 / 确认页返回都回到原预览页，结果和「已存」状态不变；
/// **真正开始生成新图时**（`send` 里出现 `.run`）才丢弃旧结果和预览位图。
extension AppCoordinator {
    /// 当前结果算不算「已保存」：导出成功过，或已在我的作品里。
    public var isCurrentResultKept: Bool {
        if state.resultExportedRevision == state.resultRevision { return true }
        return resultSaver?.isCurrentResultSaved(revision: state.resultRevision) ?? false
    }

    /// 预览页「再拼一张」。生成中 / 导出中 / 不在结果页时忽略（按钮本来也是禁用的）。
    public func startNewMosaicTapped() {
        guard state.canStartNewMosaic else { return }
        if isCurrentResultKept {
            beginQuickAgain()
        } else {
            state.unsavedPrompt = .startNew
        }
    }

    /// 预览页返回首页等会丢掉当前结果的离开方式（「再调一调」「换一种拼法」不走这里）。
    public func leaveResultTapped() {
        guard state.canStartNewMosaic else { return }
        if isCurrentResultKept {
            discardResultAndReturnToStart()
        } else {
            state.unsavedPrompt = .leaveResult
        }
    }

    /// 未保存提示「保存」：存成功后继续原来的离开方式；存失败留在预览页（错误由「存到我的作品」按钮下方的 `works.save_failed` 显示）。
    public func unsavedPromptSave() async {
        guard let prompt = state.unsavedPrompt, !state.isSavingBeforeLeaving else { return }
        state.unsavedPrompt = nil
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
        continueLeaving(prompt)
    }

    /// 未保存提示「取消」：留在预览页，什么都不变。
    public func unsavedPromptCancel() {
        state.unsavedPrompt = nil
    }

    private func continueLeaving(_ prompt: UnsavedResultPrompt) {
        guard case .result = state.flow.generation.phase, state.flow.step == .result,
              !state.isGenerating, !state.export.isBusy else { return }
        switch prompt {
        case .startNew: beginQuickAgain()
        case .leaveResult: discardResultAndReturnToStart()
        }
    }

    /// 去选目标图。结果、预览、「已存」状态都不动（选图页返回还能回来）。
    private func beginQuickAgain() {
        pendingTarget = nil
        state.flow.send(.quickAgainStarted)
    }

    /// 开始生成新图（由 `send` 在 `.run` 之前调用）：丢弃旧结果，换上新目标图。
    func commitQuickAgain() {
        if let t = pendingTarget { target = t }
        pendingTarget = nil
        discardResult()
        state.flow.commitQuickAgain()
    }

    private func discardResultAndReturnToStart() {
        pendingTarget = nil
        target = nil
        discardResult()
        state.flow.generation.send(.backToSettings)
        state.flow.returnToStart()
    }

    /// 丢掉当前结果：`hasResult` 变 false → 平台层释放预览位图；`resultRevision` +1 → 「存到我的作品」按钮回到初始状态。
    private func discardResult() {
        guard product != nil else { return }
        product = nil
        state.resultRevision += 1
        state.resultExportedRevision = nil
        state.postFilterShortageNotice = false
    }
}
