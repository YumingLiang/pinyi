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
    /// 作品库里还有没有这张作品（选图提示「取消」回作品查看页前确认：作品在取消前被删了就不再重开查看页）。
    func hasWork(_ id: WorkID) -> Bool
}

public extension CurrentResultSaving {
    func hasWork(_ id: WorkID) -> Bool { true }
}

/// 预览页「再拼一张」（需求 v1.0 §2b / §2e）。判断都在这里（Linux 单测），视图只调方法。
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
        unsavedPromptID += 1
    }

    /// 预览页「再拼一张」。生成中 / 导出中 / 不在结果页时忽略（按钮本来也是禁用的）。
    public func startNewMosaicTapped() {
        guard state.canStartNewMosaic else { return }
        nextQuickStartOrigin = .preview
        startNewFromResult()
    }

    private func startNewFromResult() {
        if isCurrentResultKept || !allowsWorkSave {
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
    /// - Parameter workID: 发起的作品（选图提示「取消」时回到这张作品的查看页）。
    public func startNewFromWorkTapped(workID: WorkID? = nil, savedShape: ShapeManifest? = nil, densityName: String? = nil) {
        guard !state.isGenerating, !state.export.isBusy, state.unsavedPrompt == nil, !state.isSavingBeforeLeaving,
              !state.flow.isQuickAgain else { return }
        if let savedShape, let choice = ShapeChoice(manifest: savedShape) {
            shapeIdentity = choice
            state.flow.shape = choice
            if savedShape.spec.source.isText {
                state.flow.settings.density = .fine
            } else if let densityName, let density = DensityChoice(rawValue: densityName) {
                state.flow.settings.density = density
            }
            nextQuickStartOrigin = workID.map { .work(id: $0) }
            if state.flow.step == .result, case .result = state.flow.generation.phase {
                state.flow.send(.shapeQuickAgainStarted)
            } else if state.flow.step != .result {
                state.flow.send(.freshShapeConfigStarted)
            }
            quickStartOrigin = nextQuickStartOrigin
            return
        }
        if state.canStartNewMosaic {
            nextQuickStartOrigin = workID.map { .work(id: $0) } ?? .preview
            startNewFromResult()
            return
        }
        if case .result = state.flow.generation.phase { return }
        // 发起页（产品 03:16 / 02:35 口径）：从作品查看页点的就回作品查看页——包括「再调一调」途中进作品页点的
        // （查看页下面的主流程恢复成「再调一调」设置页，原目标图和「完成」都在，从查看页返回即到）。
        // 没有作品 ID（旧调用）时，「再调一调」途中按设置页发起算。
        nextQuickStartOrigin = workID.map { .work(id: $0) } ?? (isAdjustingResult ? .adjust : nil)
        if isAdjustingResult, !isCurrentResultKept {
            if !allowsWorkSave {
                beginFreshQuickStart()
                return
            }
            ask(.startNewFromAdjust)
            return
        }
        beginFreshQuickStart()
    }

    private func beginFreshQuickStart() {
        pendingTarget = nil
        // 选图页 / 确认页里选过的照片会直接写 `target`（没有旧结果要保护的普通流程就是这样）；
        // 「取消」回发起页时要把进来前的目标图和代次原样放回（P1-2：「再调一调」回去仍是原目标图、主按钮仍是「完成」）。
        targetBeforeFreshQuickStart = (target, targetGeneration)
        if currentResultIsShape {
            realignShapeChoiceWithResult()
            settingsBeforeQuickAgain = (state.flow.settings, state.flow.source.selection)
            state.flow.send(.freshShapeConfigStarted)
        } else {
            state.flow.send(.freshQuickStartStarted)
        }
        quickStartOrigin = nextQuickStartOrigin
    }

    /// 预览页返回首页等会丢掉当前结果的离开方式（「再调一调」「换一种拼法」不走这里）。
    public func leaveResultTapped() {
        guard state.canStartNewMosaic else { return }
        if isCurrentResultKept || !allowsWorkSave {
            discardResultAndReturnToStart()
        } else {
            ask(.leaveResult)
        }
    }

    /// 未保存提示「保存」：存成功后继续原来的离开方式；存失败留在预览页（错误由「存到我的作品」按钮下方的 `works.save_failed` 显示）。
    public func unsavedPromptSave() async {
        guard let task = unsavedPromptSaveTapped() else { return }
        await task.value
    }

    /// 「保存」按钮用的同步入口：提示状态当场清掉、标记保存中，再在 Task 里存。这样同一次点击里 SwiftUI 收起弹窗
    /// （`unsavedPromptDismissed`）不管先到后到都不会把「保存」吞掉。
    @discardableResult
    public func unsavedPromptSaveTapped() -> Task<Void, Never>? {
        guard let prompt = state.unsavedPrompt, !state.isSavingBeforeLeaving else { return nil }
        if !allowsWorkSave {
            state.unsavedPrompt = nil
            state.unsavedPromptIsUpdate = false
            return nil
        }
        state.unsavedPrompt = nil
        state.unsavedPromptIsUpdate = false
        state.isSavingBeforeLeaving = true
        return Task { @MainActor [weak self] in await self?.finishSaveBeforeLeaving(prompt) }
    }

    private func finishSaveBeforeLeaving(_ prompt: UnsavedResultPrompt) async {
        if !allowsWorkSave {
            state.isSavingBeforeLeaving = false
            return
        }
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

    /// 弹窗被收起（点弹窗外面、系统收起；按钮点击时 SwiftUI 也会调）。等这一轮按钮动作做完再看：提示还是同一个、
    /// 没有在保存，就按「取消」处理——否则提示状态一直挂着，「再拼一张」会一直不可点、弹窗也会反复弹。
    /// - Returns: 延后执行的 Task（测试用）。
    @discardableResult
    public func unsavedPromptDismissed() -> Task<Void, Never>? {
        guard state.unsavedPrompt != nil else { return nil }
        let id = unsavedPromptID
        return Task { @MainActor [weak self] in
            guard let self, self.state.unsavedPrompt != nil, self.unsavedPromptID == id,
                  !self.state.isSavingBeforeLeaving else { return }
            self.unsavedPromptCancel()
        }
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

    /// 照片去选目标照片；形状回到形状配置。结果、预览、「已存」状态都不动。
    private func beginQuickAgain() {
        pendingTarget = nil
        settingsBeforeQuickAgain = (state.flow.settings, state.flow.source.selection)
        if currentResultIsShape {
            realignShapeChoiceWithResult()
            state.flow.send(.shapeQuickAgainStarted)
        } else {
            state.flow.send(.quickAgainStarted)
        }
        quickStartOrigin = nextQuickStartOrigin
    }

    /// 「再拼一张」途中返回到原预览页（选图页返回；用系统 PhotosPicker 时确认页返回也直接回来，P2-c）：
    /// 释放新选的目标图（P3），确认页上改的强度 / 密度 / 素材来源恢复成原结果的（P2-b），不弹未保存提示。
    func quickAgainCancelled() {
        restoreUncommittedShapeEdits()
        quickStartOrigin = nil
    }

    /// 再拼还没开始新生成就返回：密度、素材和形状选择回到这张结果生成时的值。
    func restoreUncommittedShapeEdits() {
        pendingTarget = nil
        if let s = settingsBeforeQuickAgain {
            state.flow.settings = s.settings
            state.flow.source.select(s.selection)
        }
        settingsBeforeQuickAgain = nil
        realignShapeChoiceWithResult()
    }

    /// 回到仍在的形状结果时，把导航上的形状选择放回去。选新图或退回目标页可以暂时清掉它，但不能把这张结果变成可保存的照片。
    func realignShapeChoiceWithResult() {
        guard product?.shapeFrame != nil, let shapeIdentity else { return }
        state.flow.shape = shapeIdentity
    }

    /// 生成刚完成时调用。用户没改选择，或选择已被清掉，才对齐到这次结果。
    /// 已经改成别的形状、配色或背景时保留后选值；结果仍记着开跑时的选择，所以还不能导出。
    func realignShapeChoiceWithResultIfUnchanged() {
        guard product?.shapeFrame != nil, let shapeIdentity else { return }
        if let current = state.flow.shape, current != shapeIdentity { return }
        state.flow.shape = shapeIdentity
    }

    /// 开始生成新图（由 `send` 在 `.run` 之前调用）：丢弃旧结果，换上新目标图。
    func commitQuickAgain() {
        if let t = pendingTarget { target = t; targetGeneration += 1 }
        pendingTarget = nil
        settingsBeforeQuickAgain = nil
        quickStartOrigin = nil
        discardResult()
        state.flow.commitQuickAgain()
    }

    private func discardResultAndReturnToStart() {
        pendingTarget = nil
        targetBeforeFreshQuickStart = nil
        quickStartOrigin = nil
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
        shapeIdentity = nil
        state.resultRevision += 1
        state.postFilterShortageNotice = false
    }
}
