/// 隐藏照片双保险（网格用）：一个懒加载的 fetch result 里如果混进了 `isHidden` 的项（PhotoKit 理论上不会，
/// 见 `VisibleAssetFilter`），网格的下标要跳过它们。没有隐藏项时是恒等映射，不额外占内存。
///
/// `visibleIndex`（网格看到的下标）↔ `rawIndex`（fetch result 里的下标）。
public struct VisibleIndexMap: Sendable, Hashable {
    /// 可见项在原结果里的下标（升序）；nil = 没有隐藏项，恒等映射。
    private let visibleToRaw: [Int]?
    public let rawCount: Int

    /// - Parameter isHidden: 按原下标判断（App 里是 `fetchResult.object(at:).isHidden`）。
    public init(rawCount: Int, isHidden: (Int) -> Bool) {
        self.rawCount = max(0, rawCount)
        var kept: [Int] = []
        var sawHidden = false
        for i in 0..<self.rawCount {
            if isHidden(i) {
                if !sawHidden { sawHidden = true; kept.reserveCapacity(self.rawCount); kept.append(contentsOf: 0..<i) }
            } else if sawHidden {
                kept.append(i)
            }
        }
        visibleToRaw = sawHidden ? kept : nil
    }

    /// 没有隐藏项。
    public var isIdentity: Bool { visibleToRaw == nil }

    /// 网格里的项数。
    public var count: Int { visibleToRaw?.count ?? rawCount }

    /// 网格下标 → 原下标。越界返回 nil。
    public func rawIndex(forVisible i: Int) -> Int? {
        guard i >= 0, i < count else { return nil }
        return visibleToRaw?[i] ?? i
    }

    /// 原下标 → 网格下标；该项被隐藏（或越界）返回 nil。
    public func visibleIndex(forRaw r: Int) -> Int? {
        guard r >= 0, r < rawCount else { return nil }
        guard let map = visibleToRaw else { return r }
        var lo = 0, hi = map.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if map[mid] < r { lo = mid + 1 } else { hi = mid }
        }
        return lo < map.count && map[lo] == r ? lo : nil
    }
}
