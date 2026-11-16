/// 马赛克网格（行优先编号：`index = row * columns + column`）。
public struct MosaicGrid: Hashable, Sendable {
    /// 列数。
    public let columns: Int
    /// 行数。
    public let rows: Int

    /// 创建网格。允许 0×0 的空网格（产生空结果）。
    /// - Throws: `MosaicError.invalidGrid` 列/行为负，或只有一个为 0。
    public init(columns: Int, rows: Int) throws {
        guard columns >= 0, rows >= 0 else { throw MosaicError.invalidGrid("columns/rows must be >= 0") }
        guard (columns == 0) == (rows == 0) else {
            throw MosaicError.invalidGrid("columns and rows must both be zero or both be positive")
        }
        self.columns = columns
        self.rows = rows
    }

    /// 按密度档位与目标图尺寸确定网格（长边 N 格，短边向下取整，见 `Layout.grid`）。
    /// 例如 4:3 目标图：40 档 40×30、80 档 80×60、120 档 120×90；竖图行列互换。
    public init(density: Density, imageWidth: Int, imageHeight: Int) throws {
        self = try Layout.grid(width: imageWidth, height: imageHeight, density: density).grid
    }

    /// 格子总数。
    public var cellCount: Int { columns * rows }

    /// 列、行 → 下标。
    @inlinable
    public func index(column: Int, row: Int) -> Int { row * columns + column }

    /// 下标 → (列, 行)。
    @inlinable
    public func position(of index: Int) -> (column: Int, row: Int) { (index % columns, index / columns) }

    /// 第 `index` 个格子在给定邻域内的所有邻居下标（不含自身，已裁剪到网格内）。
    public func neighbors(of index: Int, in neighborhood: Neighborhood) -> [Int] {
        let (c, r) = position(of: index)
        var out: [Int] = []
        for o in neighborhood.offsets {
            let nc = c + o.dx
            let nr = r + o.dy
            if nc >= 0, nc < columns, nr >= 0, nr < rows { out.append(self.index(column: nc, row: nr)) }
        }
        return out
    }
}

/// 密度档位（文案：粗 / 中 / 细）：长边格数 N。可自定义。
public enum Density: Hashable, Sendable {
    /// 粗：40 列。
    case coarse
    /// 中（默认）：80 列。
    case medium
    /// 细：120 列。
    case fine
    /// 自定义列数（≥ 1）。
    case custom(columns: Int)

    /// 长边格数 N（属性名沿用 `columns`，竖图时实际对应行数）。
    public var columns: Int {
        switch self {
        case .coarse: return 40
        case .medium: return 80
        case .fine: return 120
        case .custom(let c): return max(1, c)
        }
    }
}

/// "相邻不重复"约束所用的邻域定义（技术方案 §3.4：默认 8 邻域，半径 1；120 档可设 2；回退时放宽为 4 邻域）。
public enum Neighborhood: Hashable, Sendable {
    /// 不做相邻约束。
    case none
    /// Moore 邻域（切比雪夫距离 ≤ radius）。radius = 1 即 8 邻域；radius = 2 为 24 邻域。
    case moore(radius: Int)
    /// 冯·诺依曼邻域（曼哈顿距离 ≤ radius）。radius = 1 即上下左右 4 邻域。
    case vonNeumann(radius: Int)

    /// 默认：8 邻域。
    public static let eight = Neighborhood.moore(radius: 1)
    /// 4 邻域。
    public static let four = Neighborhood.vonNeumann(radius: 1)

    /// 相对偏移（不含 (0,0)），按 (dy, dx) 升序排列以保证确定性。
    public var offsets: [(dx: Int, dy: Int)] {
        switch self {
        case .none:
            return []
        case .moore(let radius):
            let r = max(0, radius)
            var out: [(dx: Int, dy: Int)] = []
            for dy in -r...r { for dx in -r...r where !(dx == 0 && dy == 0) { out.append((dx, dy)) } }
            return out
        case .vonNeumann(let radius):
            let r = max(0, radius)
            var out: [(dx: Int, dy: Int)] = []
            for dy in -r...r {
                for dx in -r...r where !(dx == 0 && dy == 0) && abs(dx) + abs(dy) <= r { out.append((dx, dy)) }
            }
            return out
        }
    }
}
