import MosaicCore

/// 形状导出 / 预览共用的逐格决定（设计 §6）。
///
/// 条带按 `ExportStripPolicy.default`（高 512 px、按整行格子对齐）自上而下，条带内行优先。
/// 无形状时每格都走照片路径，下标顺序就是 `0 ..< 列×行`，和原来的整表扫描一样。
/// 形状外填背景色，不取照片，不计入糊格 / 白格。形状内空格子仍走原来的空白统计。
public enum ShapeStripExport {
    public struct Step: Sendable, Equatable {
        /// 行优先格子下标。
        public var index: Int
        /// 非 nil：这一格是形状外，填该背景，不取图，不计入 `ExportFillStats`。
        public var background: ShapeBackground?

        public init(index: Int, background: ShapeBackground?) {
            self.index = index
            self.background = background
        }

        /// 是否计入糊格 / 白格。形状外为 false。
        public var countsInFillStats: Bool { background == nil }
    }

    /// - Parameters:
    ///   - shape: 无形状（nil）时全部走照片路径。掩码尺寸和网格不一致时也全部走照片路径，避免涂错格子。
    public static func steps(columns: Int, rows: Int, cellPixels: Int, shape: ShapeFrame?) -> [Step] {
        let columns = max(0, columns), rows = max(0, rows)
        guard columns > 0, rows > 0 else { return [] }
        let mask = shape.flatMap { placement -> CellMask? in
            placement.mask.columns == columns && placement.mask.rows == rows ? placement.mask : nil
        }
        let background = shape?.background
        var out: [Step] = []
        out.reserveCapacity(columns * rows)
        for rowRange in stripRows(rows: rows, cellPixels: cellPixels) {
            for row in rowRange {
                for column in 0..<columns {
                    let index = row * columns + column
                    let outside = mask.map { !$0.isActive(index) } ?? false
                    out.append(Step(index: index, background: outside ? background : nil))
                }
            }
        }
        return out
    }

    /// 与 `GridLayout.exportStrips` 同一条带高度：默认 512 px，至少 1 行。
    static func stripRows(rows: Int, cellPixels: Int) -> [Range<Int>] {
        let perStrip: Int
        switch ExportStripPolicy.default {
        case .cellRows(let n): perStrip = max(1, n)
        case .maxPixelHeight(let px): perStrip = max(1, px / max(1, cellPixels))
        }
        var ranges: [Range<Int>] = []
        var row = 0
        while row < rows {
            let end = min(rows, row + perStrip)
            ranges.append(row..<end)
            row = end
        }
        return ranges
    }
}
