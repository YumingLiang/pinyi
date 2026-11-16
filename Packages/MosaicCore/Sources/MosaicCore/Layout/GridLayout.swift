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
/// 极端长图（产品决定 v0.3 补充决定 9「方案 A」，2026-11-16 01:10 定稿）：宽高比超过 N:1、
/// 短边排不满一格（`短边 < 长边 ÷ N`）时，**格子边长取短边**，排 1 行（竖图为 1 列）N 格，
/// 长边多出的 `长边 − N × 短边` 两侧居中裁掉；不拉伸、不补边、不拒绝、不提示。
/// 刚好 N:1 时 `s = 短边`，走常规分支，结果与方案 A 相同（1 × N、零裁切）。
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
    /// 是否触发了极端长图方案 A（格子边长取短边、长边居中裁切）。仅作内部/诊断标记，UI 不据此提示。
    public let shortEdgeUnderflow: Bool

    /// 列数。
    public var columns: Int { grid.columns }
    /// 行数。
    public var rows: Int { grid.rows }
    /// 格子总数。
    public var cellCount: Int { grid.cellCount }
    /// 目标图是否横向（宽 ≥ 高）。正方形按横向处理。
    public var isLandscape: Bool { imageWidth >= imageHeight }
    /// 被裁掉的总像素数（两侧之和）：常规为短边方向的余量；方案 A 时为长边方向的余量。
    public var croppedAmount: Double {
        (Double(imageWidth) - cropRect.width) + (Double(imageHeight) - cropRect.height)
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

    /// 导出尺寸（产品决定 v0.3「导出尺寸最终规则」2026-11-16 01:12，唯一正式策略）：
    /// 每格像素 = floor(标称长边 ÷ 长边格数)；导出尺寸 = 每格像素 × 格数；不做最后缩放、不做余数分摊。
    /// 例：4000 + 细档 → 33 px/格 → 长边 3960（标称的 99%）。长边恒在标称值的 99%–100%（N ≤ 120、标称 ≥ 4000 时）。
    /// - Parameter longEdge: 用户选择的导出标称长边（4000 默认 / 6000；8000 仅性能页摸底）。
    /// - Returns: 导出图宽高与每格像素边长。
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
        if exactM == 0 {
            // 方案 A：格子边长 = 短边，1 × N，长边居中裁掉 long − N·short。
            let usedLong = Double(n) * short
            let offset = (long - usedLong) / 2
            let grid = landscape ? try MosaicGrid(columns: n, rows: 1) : try MosaicGrid(columns: 1, rows: n)
            let crop = landscape
                ? CropRect(x: offset, y: 0, width: usedLong, height: short)
                : CropRect(x: 0, y: offset, width: short, height: usedLong)
            return GridLayout(grid: grid, cellSize: short, cropRect: crop,
                              imageWidth: width, imageHeight: height, shortEdgeUnderflow: true)
        }
        let m = exactM
        let usedShort = Double(m * longPx) / Double(n)
        let offset = (short - usedShort) / 2

        let grid = landscape ? try MosaicGrid(columns: n, rows: m) : try MosaicGrid(columns: m, rows: n)
        let crop = landscape
            ? CropRect(x: 0, y: offset, width: long, height: usedShort)
            : CropRect(x: offset, y: 0, width: usedShort, height: long)
        return GridLayout(grid: grid, cellSize: s, cropRect: crop,
                          imageWidth: width, imageHeight: height, shortEdgeUnderflow: false)
    }
}
