import Foundation
import MosaicCore

// MARK: - 结果页预览「清晰层」（feat/preview-detail-layer，架构师 21:02 方案）
//
// 底图：现有整张预览位图（每格 ≤ 64 px，长边 ≤ 4096）不动。
// 清晰层：放在 `ZoomableContainer` 的内容里（scaleEffect 之内），可见格子（外扩 1 圈）每格一个 `Image`，
// frame = 未缩放的格子尺寸、`.position` 定位，不光栅化，Core Animation 放大时直接用图层原始像素，
// 所以 256 / 512 / 1024 px 的格子图放大后仍清楚。手势进行中清晰层随内容一起变换（不隐藏、不错位），
// 手势结束 150 ms 后才重新算可见集合并取图，旧集合里不再需要的请求取消。
//
// 本文件全是纯逻辑（Linux 单测）：几何（可见格子、外扩、每格屏幕像素）、档位、启用条件、代次 / 防抖状态机、
// 取图计划和请求差分。PhotoKit 取图、NSCache 和 SwiftUI 在 App 层。

/// 清晰层缩略图档位（正方形边长，px）。按**可见格数**分档：格越少每格越大。
public enum DetailTier: Int, CaseIterable, Comparable, Sendable {
    case p256 = 256
    case p512 = 512
    case p1024 = 1024

    public var pixels: Int { rawValue }

    public static func < (a: DetailTier, b: DetailTier) -> Bool { a.rawValue < b.rawValue }

    /// 可见格 > 64 → 256；≤ 64 → 512；≤ 4 → 1024。
    public static func select(visibleCells n: Int) -> DetailTier {
        if n <= 4 { return .p1024 }
        if n <= 64 { return .p512 }
        return .p256
    }

    /// RGBA8 正方形字节数（NSCache 计费用）。
    public var byteCost: Int { pixels * pixels * 4 }
}

/// 清晰层的阈值。默认值是架构师方案的定值，真机实测后改这里一处。
public struct DetailLayerPolicy: Sendable, Equatable {
    /// 屏幕上每格像素 > 底图每格像素 × 这个倍数才启用。
    public var minGainOverBase: Double = 1.5
    /// 可见格（不含外扩圈）超过这个数就不启用。
    /// 960：盖住 iPhone 17 Pro Max（440×600 pt @3x）细档 4:3 在启用阈值约 4.65x 时的约 930 格
    ///（768 仍会留下 4.65–5.06x 的缺口）。实际取图再按 64 MB 字节预算截断（256 档最多 256 张，中心优先）。
    public var maxVisibleCells: Int = 960
    /// 可见范围外扩几圈格子。
    public var ring: Int = 1
    /// 手势结束后多久更新可见集合（秒）。
    public var settleDelay: Double = 0.15
    /// 同时在飞的 PhotoKit 请求数。
    public var maxConcurrentRequests: Int = 6
    /// 缓存字节上限（NSCache totalCostLimit）。
    public var cacheByteLimit: Int = 64 * 1_048_576

    public init() {}
    public static let standard = DetailLayerPolicy()
}

/// 结果页预览的屏幕几何。和 `ZoomableContainer` 的变换一致：
/// 内容按 scaledToFit 居中放进视口（`fittedSize`），再以视口中心为原点 `scaleEffect(scale)`，再 `offset`。
/// `contentRect` / `cellRect` 输出：视口左上角为原点的**屏幕像素**（点 × displayScale），y 向下；
/// `unscaledCellFrame` 输出：scaleEffect 之前的内容坐标（点）。
public struct DetailGeometry: Equatable, Sendable {
    public struct Rect: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    public let viewport: ZoomState.Vector
    public let fittedSize: ZoomState.Vector
    public let scale: Double
    public let offset: ZoomState.Vector
    public let displayScale: Double
    public let columns: Int
    public let rows: Int

    public init(viewport: ZoomState.Vector, fittedSize: ZoomState.Vector, scale: Double, offset: ZoomState.Vector,
                displayScale: Double, columns: Int, rows: Int) {
        self.viewport = viewport
        self.fittedSize = fittedSize
        self.scale = scale
        self.offset = offset
        self.displayScale = displayScale
        self.columns = columns
        self.rows = rows
    }

    public init(zoom: ZoomState, displayScale: Double, columns: Int, rows: Int) {
        self.init(viewport: zoom.viewport, fittedSize: zoom.fittedSize, scale: zoom.scale, offset: zoom.offset,
                  displayScale: displayScale, columns: columns, rows: rows)
    }

    public var isValid: Bool {
        columns > 0 && rows > 0 && viewport.x > 0 && viewport.y > 0 && fittedSize.x > 0 && fittedSize.y > 0
            && scale.isFinite && scale > 0 && displayScale.isFinite && displayScale > 0
            && offset.x.isFinite && offset.y.isFinite
    }

    /// 视口位图尺寸（像素，向上取整）。
    public var viewportPixels: (width: Int, height: Int) {
        guard isValid else { return (0, 0) }
        return (Int((viewport.x * displayScale).rounded(.up)), Int((viewport.y * displayScale).rounded(.up)))
    }

    /// 整张内容在屏幕上的矩形（像素）。
    public var contentRect: Rect {
        let s = displayScale
        let w = fittedSize.x * scale, h = fittedSize.y * scale
        let x = viewport.x / 2 - w / 2 + offset.x
        let y = viewport.y / 2 - h / 2 + offset.y
        return Rect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    /// 每格在屏幕上的像素（宽、高）。格子是正方形时两者相等。
    public var cellScreenSize: (width: Double, height: Double) {
        guard isValid else { return (0, 0) }
        let c = contentRect
        return (c.width / Double(columns), c.height / Double(rows))
    }

    /// 每格屏幕像素（取长边，选档用）。
    public var cellScreenPixels: Double {
        let s = cellScreenSize
        return max(s.width, s.height)
    }

    /// 第 (col, row) 格在屏幕上的矩形（像素）。
    public func cellRect(column: Int, row: Int) -> Rect {
        let c = contentRect, cs = cellScreenSize
        return Rect(x: c.x + Double(column) * cs.width, y: c.y + Double(row) * cs.height,
                    width: cs.width, height: cs.height)
    }

    /// 与视口相交（面积 > 0）的格子范围；没有可见格子时为 nil。
    public var visibleRange: (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        guard isValid else { return nil }
        let c = contentRect, cs = cellScreenSize
        let vw = viewport.x * displayScale, vh = viewport.y * displayScale
        let x0 = max(0, c.x), y0 = max(0, c.y)
        let x1 = min(vw, c.maxX), y1 = min(vh, c.maxY)
        guard x1 > x0, y1 > y0, cs.width > 0, cs.height > 0 else { return nil }
        // 半开区间 [x0, x1)：右 / 下边缘正好落在格线上时不算下一格。
        let eps = 1e-9
        let c0 = Int(((x0 - c.x) / cs.width + eps).rounded(.down))
        let c1 = Int(((x1 - c.x) / cs.width - eps).rounded(.down))
        let r0 = Int(((y0 - c.y) / cs.height + eps).rounded(.down))
        let r1 = Int(((y1 - c.y) / cs.height - eps).rounded(.down))
        let cc0 = min(max(c0, 0), columns - 1), cc1 = min(max(c1, 0), columns - 1)
        let rr0 = min(max(r0, 0), rows - 1), rr1 = min(max(r1, 0), rows - 1)
        guard cc0 <= cc1, rr0 <= rr1 else { return nil }
        return (cc0...cc1, rr0...rr1)
    }

    /// 可见范围向外扩 `ring` 圈（夹在网格内）。
    public func visibleRange(ring: Int) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        guard let r = visibleRange else { return nil }
        let k = max(0, ring)
        return (max(0, r.columns.lowerBound - k)...min(columns - 1, r.columns.upperBound + k),
                max(0, r.rows.lowerBound - k)...min(rows - 1, r.rows.upperBound + k))
    }

    /// 第 (col, row) 格在**未缩放内容坐标**（点，内容左上角为原点）里的中心和边长：
    /// SwiftUI 在 scaleEffect 之内用 `.frame(width: side, height: side).position(center)` 摆放。
    public func unscaledCellFrame(column: Int, row: Int) -> (centerX: Double, centerY: Double, width: Double, height: Double) {
        guard columns > 0, rows > 0 else { return (0, 0, 0, 0) }
        let w = fittedSize.x / Double(columns), h = fittedSize.y / Double(rows)
        let ox = (viewport.x - fittedSize.x) / 2, oy = (viewport.y - fittedSize.y) / 2
        return (ox + (Double(column) + 0.5) * w, oy + (Double(row) + 0.5) * h, w, h)
    }

    public var visibleCellCount: Int {
        guard let r = visibleRange else { return 0 }
        return r.columns.count * r.rows.count
    }

    /// 可见格子下标（行优先 index = row × columns + col），按离视口中心由近到远排序（先取中间）。
    public func visibleCellsCenterOut() -> [Int] { cellsCenterOut(ring: 0) }

    /// 可见范围外扩 `ring` 圈后的格子：先可见格子、再外扩圈，各自按离视口中心由近到远排序。
    public func cellsCenterOut(ring: Int) -> [Int] {
        guard let r = visibleRange(ring: ring), let v = visibleRange else { return [] }
        let cx = viewport.x * displayScale / 2, cy = viewport.y * displayScale / 2
        // (外扩圈?, 距离²)：先可见格子，再外扩圈；各自由近到远。
        var cells: [(index: Int, outer: Bool, d: Double)] = []
        cells.reserveCapacity(r.columns.count * r.rows.count)
        for row in r.rows {
            for col in r.columns {
                let rect = cellRect(column: col, row: row)
                let dx = rect.x + rect.width / 2 - cx, dy = rect.y + rect.height / 2 - cy
                let outer = !(v.columns.contains(col) && v.rows.contains(row))
                cells.append((row * columns + col, outer, dx * dx + dy * dy))
            }
        }
        cells.sort { a, b in
            if a.outer != b.outer { return !a.outer }
            if a.d != b.d { return a.d < b.d }
            return a.index < b.index
        }
        return cells.map(\.index)
    }
}

/// 什么时候启用清晰层（纯函数）。
public enum DetailLayerTrigger {
    public enum Decision: Equatable, Sendable {
        /// 启用：外扩后的格子范围 + 档位。
        case activate(columns: ClosedRange<Int>, rows: ClosedRange<Int>, tier: DetailTier)
        case baseIsSharpEnough
        case tooManyCells
        case invalidGeometry
    }

    /// - Parameter baseCellPixels: 底图每格像素（`PreviewImageLimits.cellPixels`）。
    public static func decide(_ g: DetailGeometry, baseCellPixels: Int,
                              policy: DetailLayerPolicy = .standard) -> Decision {
        guard g.isValid, g.visibleRange != nil else { return .invalidGeometry }
        guard g.cellScreenPixels > Double(max(1, baseCellPixels)) * policy.minGainOverBase else { return .baseIsSharpEnough }
        let n = g.visibleCellCount
        guard n <= policy.maxVisibleCells else { return .tooManyCells }
        guard let r = g.visibleRange(ring: policy.ring) else { return .invalidGeometry }
        return .activate(columns: r.columns, rows: r.rows, tier: DetailTier.select(visibleCells: n))
    }
}

/// 防抖 + 代次状态机。App 层只按返回的动作执行。
///
/// - 缩放 / 平移有变化（手势每帧、结束、双击）→ 代次 +1，安排 `settleDelay` 后的定时器。清晰层**不隐藏**：
///   它在 scaleEffect 里，随内容一起变换，不会错位。
/// - 定时器到点且代次仍是当前的 → 判断启用条件：启用就 `update`（新可见集合 + 档位），否则 `clear`。
/// - 离开结果页 / 换拼法 → `reset()`：清空清晰层、取消全部请求、清缓存；之前安排的定时器全部作废。
public struct DetailLayerState: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case scheduleSettle(generation: Int, delay: Double)
        /// 换成这组格子 + 档位（App 层按 `DetailRequestDiff` 取消旧请求、发新请求）。
        case update(columns: ClosedRange<Int>, rows: ClosedRange<Int>, tier: DetailTier)
        /// 不需要清晰层：取消全部请求、移除格子图（缓存保留）。
        case clear
        /// 清空缓存（离开结果页、换拼法、内存警告）。
        case purgeCache
    }

    public private(set) var generation = 0
    public private(set) var active: (columns: ClosedRange<Int>, rows: ClosedRange<Int>, tier: DetailTier)?
    public let policy: DetailLayerPolicy

    public init(policy: DetailLayerPolicy = .standard) { self.policy = policy }

    public static func == (a: DetailLayerState, b: DetailLayerState) -> Bool {
        a.generation == b.generation && a.policy == b.policy
            && a.active?.columns == b.active?.columns && a.active?.rows == b.active?.rows && a.active?.tier == b.active?.tier
    }

    public var isActive: Bool { active != nil }

    public mutating func zoomChanged() -> [Action] {
        generation += 1
        return [.scheduleSettle(generation: generation, delay: policy.settleDelay)]
    }

    /// 定时器到点。过期代次、或集合 / 档位没变时返回空。
    public mutating func settled(generation g: Int, geometry: DetailGeometry, baseCellPixels: Int) -> [Action] {
        guard g == generation else { return [] }
        switch DetailLayerTrigger.decide(geometry, baseCellPixels: baseCellPixels, policy: policy) {
        case .activate(let cols, let rows, let tier):
            if let a = active, a.columns == cols, a.rows == rows, a.tier == tier { return [] }
            active = (cols, rows, tier)
            return [.update(columns: cols, rows: rows, tier: tier)]
        default:
            guard active != nil else { return [] }
            active = nil
            return [.clear]
        }
    }

    public mutating func reset() -> [Action] {
        generation += 1
        active = nil
        return [.clear, .purgeCache]
    }
}

/// 一次取图的计划：可见格子（含外扩圈）→ 按素材分组（同一张照片出现在几格只取一次），中心优先。
public struct DetailLoadPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let assetID: String
        /// 用到这张照片的格子下标（行优先）。
        public let cells: [Int]
    }

    public let tier: DetailTier
    public let items: [Item]
    /// 因字节预算被丢掉的照片数（日志用）。
    public let truncatedCount: Int

    /// - Parameter ring: 可见范围外扩几圈（外扩的格子排在可见格子之后）。
    public init(geometry: DetailGeometry, cellAssetIDs: [String?], tier: DetailTier, ring: Int = 1) {
        self.tier = tier
        var order: [String] = []
        var cellsByID: [String: [Int]] = [:]
        for cell in geometry.cellsCenterOut(ring: ring) where cell < cellAssetIDs.count {
            guard let id = cellAssetIDs[cell], !id.isEmpty else { continue }
            if cellsByID[id] == nil { order.append(id) }
            cellsByID[id, default: []].append(cell)
        }
        items = order.map { Item(assetID: $0, cells: cellsByID[$0] ?? []) }
        truncatedCount = 0
    }

    /// 按字节预算截断：中心优先保留，超出 `byteBudget`（每张 `tier.byteCost`）的照片不取，那些格子保持底图。
    /// 清晰层显示中的图被视图持有，NSCache 淘汰也释放不了，所以内存上限必须在这里守住（≤ 0 表示不限）。
    public func limited(toBytes byteBudget: Int) -> DetailLoadPlan {
        guard byteBudget > 0 else { return self }
        let maxItems = max(1, byteBudget / tier.byteCost)
        guard items.count > maxItems else { return self }
        return DetailLoadPlan(tier: tier, items: Array(items.prefix(maxItems)), truncatedCount: items.count - maxItems)
    }

    private init(tier: DetailTier, items: [Item], truncatedCount: Int) {
        self.tier = tier
        self.items = items
        self.truncatedCount = truncatedCount
    }

    public var cellCount: Int { items.reduce(0) { $0 + $1.cells.count } }
}

/// 可见集合变化时，哪些请求要取消、哪些要新发（纯函数）。
public enum DetailRequestDiff {
    /// - Parameters:
    ///   - inFlight: 正在取的 assetID。
    ///   - needed: 新集合要的 assetID（按优先级排好，中心优先）。
    ///   - cached: 已有足够档位缓存的 assetID 判断。
    /// - Returns: cancel = 在飞但不再需要的；start = 需要、没缓存、也不在飞的（保持 `needed` 的顺序）。
    public static func diff(inFlight: Set<String>, needed: [String],
                            cached: (String) -> Bool) -> (cancel: Set<String>, start: [String]) {
        let neededSet = Set(needed)
        let cancel = inFlight.subtracting(neededSet)
        var seen = Set<String>()
        var start: [String] = []
        for id in needed where !inFlight.contains(id) && !cached(id) && seen.insert(id).inserted {
            start.append(id)
        }
        return (cancel, start)
    }
}

// MARK: - 清晰层缓存键（含 fc）

/// 清晰层一张图的缓存键。照片格键里带空的 fc（`-`）；纯色格键是颜色，不带照片 ID。
/// 颜色一变就是另一个键，不能命中换色前的图。纯色格 `fetchesPhoto == false`，不向 PhotoKit 取图。
public struct DetailCacheKey: Hashable, Sendable, Equatable {
    public var assetID: String
    public var fill: CellColor?

    public init(assetID: String, fill: CellColor?) {
        if let fill {
            self.assetID = ""
            self.fill = fill
        } else {
            self.assetID = assetID
            self.fill = nil
        }
    }

    public init(cell: MosaicLayout.CellAssignment) {
        self.init(assetID: cell.localIdentifier, fill: cell.fill)
    }

    /// 有纯色、或没有照片 ID 时不取图。
    public var fetchesPhoto: Bool { fill == nil && !assetID.isEmpty }

    /// `NSCache` / 测试用的稳定字符串。始终包含 `fc`。
    public var cacheToken: String {
        if let fill {
            return "id:\(assetID)|fc:\(fill.r),\(fill.g),\(fill.b)"
        }
        return "id:\(assetID)|fc:-"
    }
}

/// 清晰层缓存。`invalidate()` 丢掉全部条目（离开结果页、换布局、fc 变化时调用）。
public struct DetailTileCache<Value: Sendable>: Sendable {
    private let storage = LockedState<[DetailCacheKey: Value]>([:])

    public init() {}

    public func set(_ value: Value, for key: DetailCacheKey) {
        storage.withLock { $0[key] = value }
    }

    public func get(_ key: DetailCacheKey) -> Value? {
        storage.withLock { $0[key] }
    }

    public func invalidate() {
        storage.withLock { $0.removeAll() }
    }
}
