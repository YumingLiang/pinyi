/// 浮点矩形（目标图像素坐标，原点左上）。
public struct CropRect: Hashable, Sendable {
    /// 左上角 x。
    public var x: Double
    /// 左上角 y。
    public var y: Double
    /// 宽。
    public var width: Double
    /// 高。
    public var height: Double

    /// 构造。
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 一张目标图在某个密度档位下的网格划分结果（技术方案 v0.2 §3.6 / 产品决定 v0.3 第 9 条）。
///
/// 规则：
/// - 格子为正方形，边长 `s = 长边 ÷ N`（N = 40 / 80 / 120，浮点）；
/// - 长边格数 = N，长边不裁；
/// - 短边格数 `M = max(1, floor(短边 ÷ s))`；
/// - 短边余量 `r = 短边 − M·s` 两侧居中裁掉（每侧 r/2 ≤ s/2）；不拉伸、不补边；
/// - 不限制宽高比。
///
/// 特例（方案未覆盖，待架构师确认）：极端长图使 `短边 < s` 时 `M` 被钳为 1，此时余量为负，
/// 无法既"正方形"又"不补边"。本实现选择**不裁、不补**：唯一一行格子取整个短边高度
/// （格子取样区域为 `s × 短边` 的长方形），并把 `shortEdgeUnderflow` 置为 true 供上层决定。
public struct GridLayout: Hashable, Sendable {
    /// 网格（列 × 行）。
    public let grid: MosaicGrid
    /// 格子边长（目标图像素，浮点）。
    public let cellSize: Double
    /// 参与拼图的区域（短边方向已居中裁掉余量）。
    public let cropRect: CropRect
    /// 原图宽。
    public let imageWidth: Int
    /// 原图高。
    public let imageHeight: Int
    /// 短边是否不足一个格子（见类型说明中的特例）。
    public let shortEdgeUnderflow: Bool

    /// 列数。
    public var columns: Int { grid.columns }
    /// 行数。
    public var rows: Int { grid.rows }
    /// 格子总数。
    public var cellCount: Int { grid.cellCount }
    /// 目标图是否横向（宽 ≥ 高）。正方形按横向处理。
    public var isLandscape: Bool { imageWidth >= imageHeight }
    /// 短边方向被裁掉的总像素数（两侧之和；特例时为 0）。
    public var croppedAmount: Double {
        isLandscape ? Double(imageHeight) - cropRect.height : Double(imageWidth) - cropRect.width
    }

    /// 第 `index` 个格子在目标图中的浮点矩形。
    public func cellRect(_ index: Int) -> CropRect {
        let (c, r) = grid.position(of: index)
        let w = cropRect.width / Double(columns)
        let h = cropRect.height / Double(rows)
        return CropRect(x: cropRect.x + Double(c) * w, y: cropRect.y + Double(r) * h, width: w, height: h)
    }

    /// 第 `index` 个格子对应的整数像素取样区域（取整后至少 1×1，且不越界）。
    public func cellPixelRegion(_ index: Int) -> PixelRegion {
        let rect = cellRect(index)
        func span(_ start: Double, _ length: Double, _ limit: Int) -> (Int, Int) {
            var a = Int((start).rounded(.down))
            var b = Int((start + length).rounded(.down))
            a = min(max(0, a), limit - 1)
            b = min(max(a + 1, b), limit)
            return (a, b - a)
        }
        let (x, w) = span(rect.x, rect.width, imageWidth)
        let (y, h) = span(rect.y, rect.height, imageHeight)
        return PixelRegion(x: x, y: y, width: w, height: h)
    }

    /// 导出尺寸：格子像素边长 = 导出长边 ÷ N（取整），短边 = M × 该边长（技术方案 v0.2 §3.6）。
    /// - Parameter longEdge: 用户选择的导出长边（4000 默认 / 6000）。
    /// - Returns: 导出图宽高与每格像素边长。长边可能比 `longEdge` 少几个像素（N 不整除时向下取整，不拉伸）。
    public func exportSize(longEdge: Int) -> (width: Int, height: Int, cellPixels: Int) {
        let n = isLandscape ? columns : rows
        let m = isLandscape ? rows : columns
        let cell = max(1, longEdge / max(1, n))
        let long = cell * n
        let short = cell * m
        return isLandscape ? (long, short, cell) : (short, long, cell)
    }
}

/// 网格划分入口（技术方案 v0.2 §3.6：`Layout.grid(width:height:density:)`）。
public enum Layout {
    /// 计算网格划分与裁切矩形。纯函数。
    /// - Throws: `MosaicError.invalidGrid` 图像尺寸 ≤ 0。
    public static func grid(width: Int, height: Int, density: Density) throws -> GridLayout {
        guard width > 0, height > 0 else { throw MosaicError.invalidGrid("image size must be > 0") }
        let n = density.columns
        let landscape = width >= height
        let long = Double(landscape ? width : height)
        let short = Double(landscape ? height : width)
        let s = long / Double(n)
        // M = floor(短边 ÷ s) = floor(短边 × N ÷ 长边)，用整数运算避免浮点误差（例如 3 ÷ 0.05 = 59.999…）。
        let longPx = landscape ? width : height
        let shortPx = landscape ? height : width
        let exactM = shortPx * n / longPx
        let m = max(1, exactM)
        let underflow = exactM == 0
        let usedShort = underflow ? short : Double(m * longPx) / Double(n)
        let offset = (short - usedShort) / 2

        let grid = landscape ? try MosaicGrid(columns: n, rows: m) : try MosaicGrid(columns: m, rows: n)
        let crop = landscape
            ? CropRect(x: 0, y: offset, width: long, height: usedShort)
            : CropRect(x: offset, y: 0, width: usedShort, height: long)
        return GridLayout(grid: grid, cellSize: s, cropRect: crop,
                          imageWidth: width, imageHeight: height, shortEdgeUnderflow: underflow)
    }
}
