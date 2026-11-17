import Foundation

/// 系统选择器选的照片用不了（copy v1.6，#18）：经 PhotoFetch 取不到或读不出来，一律弹同一个提示 `picker.unavailable`，
/// 不区分原因。主流程和「再拼一张」共用这个选图页，所以都走这里。
/// - 「换一张」`picker.unavailable.change`：重新打开系统选择器。
/// - 「取消」`common.cancel`：回到发起「再拼一张」的那一页（copy v1.6「回到发起页，当前结果保留」）：
///   预览页 → 原预览页；作品查看页 → 那张作品的查看页（主流程退回进来前的那一页，平台层按 `reopenWorkRequest` 重新打开查看页）；
///   「再调一调」设置页 → 那个设置页。原结果、作品、「已存」状态都不动。普通主流程（不是「再拼一张」）就是选图页本身，留在原地。
/// - 「增加可用照片」`picker.unavailable.add_access`：只在 App 整体是受限访问时显示，点了调系统的增加可用照片。
/// 目标图、`pendingTarget`、旧结果都不动。
extension AppCoordinator {
    /// 平台层：PickedTargetGate 不通过，或之后解码失败。
    public func pickedTargetUnavailable() {
        state.showsPickerUnavailable = true
    }

    public func pickerUnavailableChangeTapped() {
        guard state.showsPickerUnavailable else { return }
        state.showsPickerUnavailable = false
        state.targetPickerReopenRequest += 1
    }

    public func pickerUnavailableCancelTapped() {
        guard state.showsPickerUnavailable else { return }
        state.showsPickerUnavailable = false
        returnToQuickStartOrigin()
    }

    /// 「再拼一张」在选图页放弃：回发起页。
    func returnToQuickStartOrigin() {
        guard state.flow.step == .target, state.flow.isQuickAgain || state.flow.isFreshQuickStart else { return }
        let origin = quickStartOrigin
        if state.flow.isQuickAgain {
            flowSend(.back)   // 回原预览页（quickAgainCancelled：释放新目标图、恢复设置，不弹未保存提示）
        } else {
            pendingTarget = nil
            state.flow.cancelFreshQuickStart()
        }
        quickStartOrigin = nil
        if case .work(let id) = origin {
            state.reopenWorkRequest = WorkReopenRequest(workID: id, token: (state.reopenWorkRequest?.token ?? 0) + 1)
        }
    }

    public func pickerUnavailableAddAccessTapped() {
        guard state.showsPickerUnavailable, state.pickerUnavailableShowsAddAccess else { return }
        state.showsPickerUnavailable = false
        systemActionHandler?(.presentLimitedPicker)
    }

    /// 提示被收起（SwiftUI 点按钮时也会调）：延后一轮再看，还弹着（没有按钮处理过）就按「取消」，避免状态挂着；
    /// 按钮动作先清掉了标记就什么都不做，所以不会吞掉「换一张」「增加可用照片」。
    @discardableResult
    public func pickerUnavailableDismissed() -> Task<Void, Never>? {
        guard state.showsPickerUnavailable else { return nil }
        return Task { @MainActor [weak self] in
            guard let self, self.state.showsPickerUnavailable else { return }
            self.pickerUnavailableCancelTapped()
        }
    }
}
