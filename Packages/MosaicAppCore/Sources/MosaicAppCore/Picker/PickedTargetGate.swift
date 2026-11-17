import Foundation

// MARK: - 系统 PhotosPicker 选完后的隐藏照片兜底（#18 QA P1-a；quick-start v1.0 §0-3，需求 v1.0 §4.8）

/// 按 `itemIdentifier` 经 `PhotoFetch` 再取一次 PHAsset 的结果（平台层查，这里只做判断，便于 Linux 单测）。
public enum PickedAssetLookup: Sendable, Equatable {
    /// 取不到：被隐藏（PhotoFetch 写死 `includeHiddenAssets = false`）、已删除、受限访问下没授权、或 iCloud 共享以外的来源。
    case notFound
    /// 取到了但 `isHidden == true`（双保险，正常情况下 PhotoFetch 已经过滤掉）。
    case hidden
    /// 取到了、没隐藏。
    case visible
}

/// 系统选择器选出来的照片能不能当目标图。
///
/// 过渡期目标图用系统 PhotosPicker（走系统进程，可能显示隐藏照片，要等 T7 真机确认）。兜底：选完后按
/// `itemIdentifier` 经 `PhotoFetch` 再取一次 PHAsset，取不到或 `isHidden` 就按「读不出来」处理（`target.unreadable`，
/// 和解码失败同一条路），主流程和「再拼一张」都一样。没有 `itemIdentifier`（不是从图库选的）同样按读不出来。
/// ⚠️ 受限访问下没授权的照片也会取不到，于是读不出来——这比放过隐藏照片稳妥；受限访问下怎么提示待产品对齐。
public enum PickedTargetGate {
    public static func allows(itemIdentifier: String?, lookup: (String) -> PickedAssetLookup) -> Bool {
        guard let id = itemIdentifier, !id.isEmpty else { return false }
        return lookup(id) == .visible
    }
}
