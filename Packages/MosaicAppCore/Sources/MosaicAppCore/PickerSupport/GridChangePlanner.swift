import Foundation

// MARK: - 相册变化 → 网格更新（photo-picker-v0.1 §2「相册变化」；T3）
//
// App 层的 `PhotoLibraryObserver` 从 `PHFetchResultChangeDetails` 里读出下面这些原始数，交给 `GridChangePlanner.plan`
// 决定是做增量 `performBatchUpdates` 还是整体 `reloadData`。纯逻辑放这里是为了在 Linux 上测。
//
// 隐藏照片：取数统一走 `PhotoFetch`（`includeHiddenAssets = false`），照片被设为隐藏后会从新的 fetch result 里消失，
// PhotoKit 给出的 changeDetails 里它就在 `removedIndexes` 里，所以这里自然表现为删除，不需要特殊分支。

/// `PHFetchResultChangeDetails` 的原始信息（App 层抄出来，不含 PhotoKit 类型）。
public struct GridChangeDetails: Sendable, Hashable {
    /// 变化前的 `count`。
    public var countBefore: Int
    /// 变化后的 `count`（`fetchResultAfterChanges.count`）。
    public var countAfter: Int
    /// `hasIncrementalChanges`。false 时其余字段无意义。
    public var hasIncrementalChanges: Bool
    /// `removedIndexes`（旧下标）。
    public var removed: IndexSet
    /// `insertedIndexes`（新下标）。
    public var inserted: IndexSet
    /// `changedIndexes`（新下标）。
    public var changed: IndexSet
    /// `enumerateMoves` 的结果（旧下标 → 新下标）。
    public var moves: [AssetGridMove]

    public init(countBefore: Int, countAfter: Int, hasIncrementalChanges: Bool, removed: IndexSet = IndexSet(),
                inserted: IndexSet = IndexSet(), changed: IndexSet = IndexSet(), moves: [AssetGridMove] = []) {
        self.countBefore = countBefore
        self.countAfter = countAfter
        self.hasIncrementalChanges = hasIncrementalChanges
        self.removed = removed
        self.inserted = inserted
        self.changed = changed
        self.moves = moves
    }
}

public enum GridChangePlanner {
    /// 一次增量更新最多处理多少项（删 + 插 + 改 + 移）。超过就整体 reload：批量动画本身很慢，用户也看不出区别。
    public static let maxIncrementalItems = 300
    /// 不超过这么多项时，即使超过总数一半也做增量（小相簿里删一两张照片也要有动画）。
    public static let smallChangeItems = 20

    /// 决定怎么更新网格。以下情况整体 reload：
    /// - 没有增量信息（`hasIncrementalChanges == false`）；
    /// - 变化项数超过 `maxIncrementalItems`，或超过 `smallChangeItems` 且超过变化后总数的一半；
    /// - 数据不自洽（下标越界、`countBefore - removed + inserted != countAfter`、移动下标越界）。
    ///   UICollectionView 在批量更新数不对时会直接抛异常崩溃，宁可 reload。
    public static func plan(_ d: GridChangeDetails) -> AssetGridChange {
        guard d.hasIncrementalChanges else { return .reload }
        guard d.countBefore >= 0, d.countAfter >= 0 else { return .reload }
        if d.removed.isEmpty && d.inserted.isEmpty && d.changed.isEmpty && d.moves.isEmpty {
            // 有增量信息但什么都没变（例如只是元数据变化没落到本结果）：仍给一个空增量，调用方可直接忽略。
            return d.countBefore == d.countAfter
                ? .incremental(removed: IndexSet(), inserted: IndexSet(), changed: IndexSet(), moves: []) : .reload
        }
        let total = d.removed.count + d.inserted.count + d.changed.count + d.moves.count
        if total > maxIncrementalItems || (total > smallChangeItems && total * 2 > d.countAfter) {
            return .reload
        }
        if let last = d.removed.last, last >= d.countBefore { return .reload }
        if let last = d.inserted.last, last >= d.countAfter { return .reload }
        if let last = d.changed.last, last >= d.countAfter { return .reload }
        if d.countBefore - d.removed.count + d.inserted.count != d.countAfter { return .reload }
        for m in d.moves where m.from < 0 || m.from >= d.countBefore || m.to < 0 || m.to >= d.countAfter {
            return .reload
        }
        return .incremental(removed: d.removed, inserted: d.inserted, changed: d.changed, moves: d.moves)
    }
}
