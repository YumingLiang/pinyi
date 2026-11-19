import MosaicCore

/// 纯 Swift 扫描线光栅化（设计 shape-mosaic-v0.1 §2）：路径 → 每格覆盖率 → `CellMask`。
///
/// - 路径按宽高比等比放进 `columns × rows` 网格，四周留 `marginCells` 格边距，居中。
/// - 贝塞尔按 0.05 格容差细分成线段。
/// - 每格 8 × 8 个采样点（采样点在 (i + 0.5) / 8 格处），非零环绕规则判断采样点是否在形状内。
/// - 覆盖 ≥ 32 / 64 的格子算形状内。
/// - 结果只由（路径、网格、边距）决定，可复现。
public enum PathRasterizer {
    /// 每格每个方向的采样数。
    public static let samplesPerAxis = 8
    /// 每格采样总数（64）。
    public static let samplesPerCell = samplesPerAxis * samplesPerAxis
    /// 形状内阈值：覆盖采样数 ≥ 32（50%）。
    public static let insideThreshold = 32
    /// 细分容差（格）。
    public static let flattenTolerance = 0.05

    /// 光栅化结果。
    public struct Result: Sendable, Equatable {
        /// 形状掩码。
        public let mask: CellMask
        /// 每格覆盖的采样数（0…64，行优先）。
        public let coverage: [UInt8]
        /// 路径外接框在网格里的位置（单位：格）。
        public let fitX: Double
        public let fitY: Double
        public let fitWidth: Double
        public let fitHeight: Double
    }

    /// 光栅化。
    /// - Throws: `MosaicError.invalidGrid`（列 / 行 ≤ 0、边距放不下）。
    public static func rasterize(_ path: ShapePath, columns: Int, rows: Int, marginCells: Double,
                                 fitWidth: Double? = nil, fitHeight: Double? = nil) throws -> Result {
        guard columns > 0, rows > 0 else { throw MosaicError.invalidGrid("shape grid must be positive") }
        let innerW = Double(columns) - 2 * marginCells
        let innerH = Double(rows) - 2 * marginCells
        guard innerW > 0, innerH > 0, path.aspect > 0, path.aspect.isFinite else {
            throw MosaicError.invalidGrid("margin leaves no room for the shape")
        }
        // 默认等比铺满内框。文字传入固定的 fit，短字不再被放大到铺满长边。
        let w: Double
        let h: Double
        if let fitWidth, let fitHeight {
            guard fitWidth > 0, fitHeight > 0, fitWidth <= innerW + 1e-6, fitHeight <= innerH + 1e-6 else {
                throw MosaicError.invalidGrid("text fit \(fitWidth)x\(fitHeight) exceeds \(innerW)x\(innerH)")
            }
            w = fitWidth
            h = fitHeight
        } else {
            h = min(innerH, innerW / path.aspect)
            w = h * path.aspect
        }
        let x0 = (Double(columns) - w) / 2
        let y0 = (Double(rows) - h) / 2
        let polys = path.polygons(transform: { ShapePoint(x0 + $0.x * w, y0 + $0.y * h) }, tolerance: flattenTolerance)

        // 边表：(x0, y0, x1, y1, dir)，水平边丢掉。y 用半开区间 [ymin, ymax)。
        struct Edge { var xTop: Double; var yTop: Double; var yBottom: Double; var slope: Double; var dir: Int }
        var edges: [Edge] = []
        for poly in polys {
            for i in poly.indices {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                if a.y == b.y { continue }
                let down = b.y > a.y
                let top = down ? a : b, bottom = down ? b : a
                edges.append(Edge(xTop: top.x, yTop: top.y, yBottom: bottom.y,
                                  slope: (bottom.x - top.x) / (bottom.y - top.y), dir: down ? 1 : -1))
            }
        }
        edges.sort { $0.yTop < $1.yTop }

        let s = samplesPerAxis
        let sampleCols = columns * s
        var coverage = [UInt8](repeating: 0, count: columns * rows)
        var crossings: [(x: Double, dir: Int)] = []
        var active: [Int] = []
        var nextEdge = 0
        for j in 0..<(rows * s) {
            let y = (Double(j) + 0.5) / Double(s)
            while nextEdge < edges.count, edges[nextEdge].yTop <= y {
                active.append(nextEdge)
                nextEdge += 1
            }
            active.removeAll { edges[$0].yBottom <= y }
            crossings.removeAll(keepingCapacity: true)
            for e in active where edges[e].yTop <= y {
                let ed = edges[e]
                crossings.append((ed.xTop + (y - ed.yTop) * ed.slope, ed.dir))
            }
            if crossings.isEmpty { continue }
            crossings.sort { $0.x < $1.x || ($0.x == $1.x && $0.dir < $1.dir) }
            let row = j / s
            var winding = 0
            var spanStart = 0.0
            for c in crossings {
                let before = winding
                winding += c.dir
                if before == 0, winding != 0 {
                    spanStart = c.x
                } else if before != 0, winding == 0 {
                    // 采样点 x = (i + 0.5) / s 落在 [spanStart, c.x) 内的 i。
                    let lo = max(0, Int((spanStart * Double(s) - 0.5).rounded(.up)))
                    let hi = min(sampleCols, Int((c.x * Double(s) - 0.5).rounded(.up)))
                    if lo < hi { addSpan(lo, hi, row: row, columns: columns, into: &coverage) }
                }
            }
        }

        var bits = BitMask(count: columns * rows)
        for i in coverage.indices where Int(coverage[i]) >= insideThreshold { bits[i] = true }
        return Result(mask: try CellMask(columns: columns, rows: rows, bits: bits), coverage: coverage,
                      fitX: x0, fitY: y0, fitWidth: w, fitHeight: h)
    }

    /// 只要掩码的便捷入口。
    public static func mask(_ path: ShapePath, columns: Int, rows: Int, marginCells: Double) throws -> CellMask {
        try rasterize(path, columns: columns, rows: rows, marginCells: marginCells).mask
    }

    /// 把一条扫描线上采样下标 [lo, hi) 计入对应格子。
    private static func addSpan(_ lo: Int, _ hi: Int, row: Int, columns: Int, into coverage: inout [UInt8]) {
        let s = samplesPerAxis
        var i = lo
        let base = row * columns
        while i < hi {
            let cell = i / s
            let cellEnd = min(hi, (cell + 1) * s)
            coverage[base + cell] &+= UInt8(cellEnd - i)
            i = cellEnd
        }
    }
}
