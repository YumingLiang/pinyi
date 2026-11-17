import Foundation

// MARK: - 系统 PhotosPicker 选完后的兜底（#18 QA P1-a；quick-start v1.0 §0-3，需求 v1.0 §4.8；copy v1.6）

/// 系统选择器选出来的照片能不能当目标图：只输出「可用 / 不可用」，**不区分原因**。
///
/// 过渡期目标图用系统 PhotosPicker（走系统进程，可能显示隐藏照片，要等 T7 真机确认）。兜底：选完后按
/// `itemIdentifier` 经 `PhotoFetch` 再取一次 PHAsset（`isAvailable`，平台层实现：取得到且没隐藏才算可用）。
/// 取不到（隐藏 / 受限下未授权 / 已删除）、没有 `itemIdentifier`、之后解码失败，一律走同一个提示
/// `picker.unavailable`（`AppCoordinator.pickedTargetUnavailable()`），主流程和「再拼一张」都一样。
public enum PickedTargetGate {
    public static func allows(itemIdentifier: String?, isAvailable: (String) -> Bool) -> Bool {
        guard let id = itemIdentifier, !id.isEmpty else { return false }
        return isAvailable(id)
    }
}
