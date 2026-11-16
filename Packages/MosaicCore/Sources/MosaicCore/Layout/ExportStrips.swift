/// 导出分条（技术方案 v0.2 §4.2 第 2 步，A-20）。
public enum ExportStripPolicy: Hashable, Sendable {
    /// 每条固定 `n` 行格子（n ≥ 1；n = 1 即"每条 = 1 行格子高度"）。
    case cellRows(Int)
    /// 每条不超过 `pixels` 像素高、且按整行格子对齐（至少 1 行；格子像素 > pixels 时退化为 1 行/条）。
    case maxPixelHeight(Int)

    /// 方案默认：512 px。
    public static let `default` = ExportStripPolicy.maxPixelHeight(512)
}

/// 一条导出条带。
public struct ExportStrip: Hashable, Sendable {
    /// 条带序号（自上而下）。
    public let index: Int
    /// 覆盖的格子行。
    public let rows: Range<Int>
    /// 在导出图中的像素行范围（`rows × cellPixels`）。
    public let pixelRows: Range<Int>
    /// 条带像素高度。
    public var pixelHeight: Int { pixelRows.count }
}

extension GridLayout {
    /// 导出图的条带切分：条带按格子行对齐、自上而下、并集覆盖整张导出图且互不重叠。
    /// 导出尺寸与每格像素同 `exportSize(longEdge:)`（向下取整规则）。
    public func exportStrips(longEdge: Int, policy: ExportStripPolicy = .default) -> [ExportStrip] {
        let cell = exportSize(longEdge: longEdge).cellPixels
        let perStrip: Int
        switch policy {
        case .cellRows(let n): perStrip = max(1, n)
        case .maxPixelHeight(let px): perStrip = max(1, px / cell)
        }
        var strips: [ExportStrip] = []
        var r = 0
        while r < rows {
            let end = min(rows, r + perStrip)
            strips.append(ExportStrip(index: strips.count, rows: r..<end, pixelRows: (r * cell)..<(end * cell)))
            r = end
        }
        return strips
    }
}
