/// 隐藏照片双保险：PhotoFetch 取回后再按 `isHidden` 过滤。
///
/// `PHAsset.fetchAssets(withLocalIdentifiers:)` 对 `includeHiddenAssets` 的行为不完全一致
///（Apple 文档 / 论坛说法不一），不能只靠取不到。调用方在拿到 PHAsset 列表后走这里。
public enum VisibleAssetFilter {
    /// 丢掉 `isHidden == true` 的项，其余保持原顺序。
    public static func accepting<T>(_ items: [T], isHidden: (T) -> Bool) -> [T] {
        items.filter { !isHidden($0) }
    }
}
