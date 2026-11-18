import Foundation

// MARK: - 照片网格的纯逻辑（photo-picker-v0.1 §2；T4）
//
// App 层 `AssetGridViewController`（UICollectionView + 流式布局）只做 UIKit 调用，下面这些都在 Linux 上测：
// 列数 / cell 尺寸、缩略图 targetSize、可见下标区间、锚点 ↔ contentOffset 换算、快速滑动判定、
// `AssetGridChange` → batch updates / reloadData 的判定。坐标单位都是 pt，y 轴向下。

/// 网格几何：等宽正方形格子，按行排，下标 0 在左上角（最新的照片）。
public struct AssetGridLayout: Sendable, Hashable {
    /// 格子之间（横向、纵向）的间距，pt。
    public static let defaultSpacing: Double = 2
    /// 格子最小边长，pt：决定列数。440 pt（17 Pro Max）/ 375 pt 都是 4 列，320 pt 是 3 列。
    public static let defaultMinCellSide: Double = 90
    public static let minColumns = 3

    public let columns: Int
    /// 格子边长，已向下取整到整像素（1 / scale），保证一行严格放得下 `columns` 格。
    public let cellSide: Double
    public let spacing: Double
    /// 屏幕 scale（3.0 = @3x）。
    public let scale: Double

    /// - Parameters:
    ///   - containerWidth: collection view 可用宽度（已扣掉左右 inset）。
    public init(containerWidth: Double, scale: Double, spacing: Double = AssetGridLayout.defaultSpacing,
                minCellSide: Double = AssetGridLayout.defaultMinCellSide) {
        let s = scale > 0 ? scale : 1
        let sp = max(0, spacing)
        let w = max(0, containerWidth)
        let fit = minCellSide > 0 ? Int(((w + sp) / (minCellSide + sp)).rounded(.down)) : Self.minColumns
        let cols = max(Self.minColumns, fit)
        let raw = (w - sp * Double(cols - 1)) / Double(cols)
        self.columns = cols
        // 向下取整到整像素；正好整除时再让出 1 px，免得流式布局因浮点误差把一行折成 columns − 1 格
        // （UICollectionViewFlowLayout 会把多出来的空隙均摊到格间距里）。
        self.cellSide = max(0, (raw * s - 1e-6).rounded(.down) / s)
        self.spacing = sp
        self.scale = s
    }

    /// 行高（格子 + 行间距）。
    public var rowPitch: Double { cellSide + spacing }

    /// 缩略图请求尺寸：cell 边长 × scale，向上取整（§2，17 Pro Max 约 328 px）。至少 1。
    public var targetPixelSize: Int { max(1, Int((cellSide * scale).rounded(.up))) }

    public func rowCount(count: Int) -> Int { count <= 0 ? 0 : (count + columns - 1) / columns }

    /// 内容总高度（不含 inset）。
    public func contentHeight(count: Int) -> Double {
        let rows = rowCount(count: count)
        return rows == 0 ? 0 : Double(rows) * cellSide + Double(rows - 1) * spacing
    }

    /// 第 `index` 格上边缘在内容坐标里的 y。
    public func minY(ofIndex index: Int) -> Double { Double(max(0, index) / columns) * rowPitch }

    /// 一屏大约多少格：列数 × 可见行数（部分可见的行也算）。给 `ThumbnailCacheWindow` 用。
    public func itemsPerScreen(viewportHeight: Double) -> Int {
        guard cellSide > 0, viewportHeight > 0 else { return 0 }
        return columns * (Int((viewportHeight / rowPitch).rounded(.up)) + 1)
    }

    /// 可见区（内容坐标 `top ..< top + height`）里有哪些下标。只要露出一点就算可见。
    public func visibleRange(visibleTop top: Double, viewportHeight: Double, count: Int) -> Range<Int> {
        guard count > 0, cellSide > 0, viewportHeight > 0 else { return 0..<0 }
        let bottom = top + viewportHeight
        guard bottom > 0 else { return 0..<0 }
        let firstRow = max(0, firstRowIntersecting(top))
        // 最后一行：上边缘 < bottom 的最大行。
        let lastRow = Int(((bottom - 1e-9) / rowPitch).rounded(.down))
        let lo = firstRow * columns
        let hi = min(count, (lastRow + 1) * columns)
        return lo < hi ? lo..<hi : 0..<0
    }

    /// 下边缘 > y 的第一行（y 落在行间距里时取下一行）。
    private func firstRowIntersecting(_ y: Double) -> Int {
        guard y > 0 else { return 0 }
        let row = Int((y / rowPitch).rounded(.down))
        return y - Double(row) * rowPitch >= cellSide ? row + 1 : row
    }

    // MARK: 锚点（BrowsePosition：锚点格子上边缘 − 可见区上边缘；被遮住一部分时为负）

    /// 当前锚点：可见区顶部第一行（露出一点就算）的第一格。`visibleTop = contentOffset.y + adjustedContentInset.top`。
    public func anchor(visibleTop: Double, count: Int) -> GridAnchor? {
        guard count > 0, cellSide > 0 else { return nil }
        let row = min(firstRowIntersecting(visibleTop), rowCount(count: count) - 1)
        let index = row * columns
        return GridAnchor(index: index, offset: minY(ofIndex: index) - visibleTop)
    }

    /// 按锚点算 `contentOffset.y`：`minY(锚点) − offset − topInset`，再夹到可滚范围
    /// `[−topInset, max(−topInset, 内容高 + bottomInset − 视口高)]`。下标越界按最后一格算。
    public func contentOffsetY(for anchor: GridAnchor, count: Int, topInset: Double, bottomInset: Double,
                               viewportHeight: Double) -> Double {
        let minOffset = -topInset
        guard count > 0 else { return minOffset }
        let index = min(max(0, anchor.index), count - 1)
        let raw = minY(ofIndex: index) - anchor.offset - topInset
        let maxOffset = max(minOffset, contentHeight(count: count) + bottomInset - viewportHeight)
        return min(max(raw, minOffset), maxOffset)
    }
}

/// 网格锚点：数据源下标 + 「该格上边缘距可见区上边缘」的偏移（pt，被遮住时为负）。App 层把下标换成照片 ID 存进 `BrowsePosition`。
public struct GridAnchor: Sendable, Hashable {
    public var index: Int
    public var offset: Double
    public init(index: Int, offset: Double) {
        self.index = index
        self.offset = offset
    }
}

// MARK: - 快速滑动判定

/// 按相邻两次 `scrollViewDidScroll` 的位移 / 时间估速度；超过「每秒 N 屏」算快速滑动（§2：快速滑动时缓存窗口不扩大）。
public struct GridScrollSpeedMeter: Sendable {
    /// 每秒多少屏算快。
    public var fastScreensPerSecond: Double
    public private(set) var isFast = false
    private var last: (y: Double, t: Double)?

    public init(fastScreensPerSecond: Double = 4) { self.fastScreensPerSecond = fastScreensPerSecond }

    /// 返回更新后的 `isFast`。时间间隔 ≤ 0（同一帧多次回调）时沿用上次结果。
    public mutating func sample(offsetY: Double, time: Double, viewportHeight: Double) -> Bool {
        guard viewportHeight > 0, let prev = last else {
            last = (offsetY, time)
            isFast = false
            return isFast
        }
        let dt = time - prev.t
        guard dt > 0 else { return isFast }
        isFast = abs(offsetY - prev.y) / viewportHeight / dt > fastScreensPerSecond
        last = (offsetY, time)
        return isFast
    }

    /// 滑动停下（`didEndDecelerating` / 松手不减速 / 数据源切换）。
    public mutating func stop() {
        isFast = false
        last = nil
    }
}

// MARK: - 相册变化 → UICollectionView 更新

/// 一次 `AssetGridChange` 在 UICollectionView 上怎么做。
public enum AssetGridUpdatePlan: Sendable, Hashable {
    /// 没有可见变化。
    case nothing
    /// `performBatchUpdates { delete(旧下标); insert(新下标); move(旧 → 新) }`，完成后单独 `reloadItems(reloads)`（新下标）。
    case batch(deletes: [Int], inserts: [Int], moves: [AssetGridMove], reloads: [Int])
    /// 整体 `reloadData()`。
    case reloadData

    /// 增量操作总数超过它就直接 reloadData（批量动画太多反而卡，§2「变化太大」）。
    public static let defaultMaxIncremental = 300

    /// - Parameters:
    ///   - oldCount: 变化前网格显示的格数（App 层自己记，不能再问数据源：数据源已经换成新结果）。
    ///   - newCount: 变化后数据源的 `count`。
    ///   - isOnScreen: 网格不在屏幕上时没必要做动画，直接 reloadData。
    public static func plan(for change: AssetGridChange, oldCount: Int, newCount: Int, isOnScreen: Bool = true,
                            maxIncremental: Int = defaultMaxIncremental) -> AssetGridUpdatePlan {
        guard case let .incremental(removed, inserted, changed, moves) = change else { return .reloadData }
        guard isOnScreen, oldCount > 0, newCount >= 0 else { return .reloadData }

        // 下标必须和前后两个数量对得上，否则 UICollectionView 会抛异常：宁可 reload。
        if let m = removed.last, m >= oldCount { return .reloadData }
        if let m = inserted.last, m >= newCount { return .reloadData }
        if removed.first.map({ $0 < 0 }) == true || inserted.first.map({ $0 < 0 }) == true { return .reloadData }
        guard oldCount - removed.count + inserted.count == newCount else { return .reloadData }
        for mv in moves where mv.from < 0 || mv.from >= oldCount || mv.to < 0 || mv.to >= newCount {
            return .reloadData
        }
        // 同一旧下标既删又移 / 同一新下标既插又移：PhotoKit 不会给，给了就 reload。
        let moveFrom = Set(moves.map(\.from)), moveTo = Set(moves.map(\.to))
        guard moveFrom.count == moves.count, moveTo.count == moves.count,
              moveFrom.isDisjoint(with: removed), moveTo.isDisjoint(with: inserted) else { return .reloadData }

        let reloads = changed.filter { $0 >= 0 && $0 < newCount && !inserted.contains($0) && !moveTo.contains($0) }
        let total = removed.count + inserted.count + moves.count + reloads.count
        if total == 0 { return .nothing }
        if total > maxIncremental { return .reloadData }
        return .batch(deletes: Array(removed), inserts: Array(inserted), moves: moves, reloads: reloads)
    }
}
