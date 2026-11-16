/// 渐进可用的素材快照（评审 S6 / 测试缺口 T3）。
///
/// 把"来源掩码 ∧ 已扫描（行号 < rowLimit）∧ 未删除（非 tombstone）"在生成那一刻固化下来；
/// 使用上限、供给判断（200 张阈值）都基于快照的可用张数。App 只把快照交给 `MosaicPipeline`。
public struct LibrarySnapshot: Sendable, Equatable {
    /// 特征表（可能还在后台追加；快照只看前 `rowLimit` 行）。
    public let table: FeatureTable
    /// 已扫描完成的行数上界。
    public let rowLimit: Int
    /// 生效掩码（长度 = `table.count`）。
    public let mask: BitMask

    /// 创建快照。
    /// - Parameters:
    ///   - rowLimit: 已扫描行数；`nil` 表示整张表。超过表长时按表长。
    ///   - sourceMask: 来源（相簿）掩码；`nil` 表示全部。多相簿可先 `BitMask.union`。
    /// - Throws: `sourceMask` 长度与表不符时抛 `MosaicError.countMismatch`。
    public init(table: FeatureTable, rowLimit: Int? = nil, sourceMask: BitMask? = nil) throws {
        if let sourceMask, sourceMask.count != table.count {
            throw MosaicError.countMismatch(expected: table.count, actual: sourceMask.count)
        }
        let limit = min(max(0, rowLimit ?? table.count), table.count)
        var m = table.liveMask
        for i in limit..<table.count { m[i] = false }
        if let sourceMask { m = m.intersection(sourceMask) }
        self.table = table
        self.rowLimit = limit
        self.mask = m
    }

    /// 快照内可用张数。
    public var availableCount: Int { mask.setCount }
    /// 供给档位（< 200 张提示、0 张空状态）。
    public var supply: MaterialSupply { MaterialSupply.evaluate(availableCount: availableCount) }
}
