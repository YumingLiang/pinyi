import Foundation

/// 系统选择器选的照片用不了（copy v1.6，#18）：经 PhotoFetch 取不到或读不出来，一律弹同一个提示 `picker.unavailable`，
/// 不区分原因。主流程和「再拼一张」共用这个选图页，所以都走这里。
/// - 「换一张」`picker.unavailable.change`：重新打开系统选择器。
/// - 「取消」`common.cancel`：回到发起页，当前结果保留（「再拼一张」途中 = 回原预览页，同选图页返回；
///   主流程 / 从作品查看页进来的没有更早的页，留在选图页）。
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
        if state.flow.isQuickAgain, state.flow.step == .target { flowSend(.back) }
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
