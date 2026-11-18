/// 格子掩码：标记网格里哪些格子参与匹配（形状 / 文字拼图，设计 shape-mosaic-v0.1 §5）。
///
/// - 与 `mask: BitMask`（**素材**掩码，长度 = 素材数）不是一回事：这里每一位对应一个**格子**，
///   下标与 `MosaicGrid` 相同，行优先：`index = row * columns + column`。
/// - 置 1 = 形状内（参与匹配、分配照片）；置 0 = 形状外（`tiles[i] = -1`，不占照片配额）。
/// - 持久化格式 `bits-v1`（设计 §7）：行优先，每格 1 bit，**低位在前**，按字节补齐，见 `bitsV1Bytes`。
public struct CellMask: Hashable, Sendable {
    /// 列数。
    public let columns: Int
    /// 行数。
    public let rows: Int
    /// 每格一位（长度 = `columns × rows`）。
    public let bits: BitMask

    /// 由位图创建。
    /// - Throws: `MosaicError.invalidGrid`（列 / 行为负或只有一个为 0）；
    ///   `MosaicError.countMismatch`（`bits.count ≠ columns × rows`）。
    public init(columns: Int, rows: Int, bits: BitMask) throws {
        _ = try MosaicGrid(columns: columns, rows: rows)
        guard bits.count == columns * rows else {
            throw MosaicError.countMismatch(expected: columns * rows, actual: bits.count)
        }
        self.columns = columns
        self.rows = rows
        self.bits = bits
    }

    /// 全部置 1 或全部置 0 的掩码。
    public init(columns: Int, rows: Int, allActive: Bool) throws {
        try self.init(columns: columns, rows: rows, bits: BitMask(count: max(0, columns) * max(0, rows), allSet: allActive))
    }

    /// 与网格同尺寸、按谓词置位的掩码（测试与调用方便捷入口）。
    public init(grid: MosaicGrid, isActive: (_ column: Int, _ row: Int) -> Bool) {
        var b = BitMask(count: grid.cellCount)
        for r in 0..<grid.rows {
            for c in 0..<grid.columns where isActive(c, r) { b[grid.index(column: c, row: r)] = true }
        }
        columns = grid.columns
        rows = grid.rows
        bits = b
    }

    /// 格子总数。
    public var cellCount: Int { columns * rows }

    /// 形状内的格子数。
    public var activeCount: Int { bits.setCount }

    /// 第 `index` 个格子（行优先）是否在形状内。
    public func isActive(_ index: Int) -> Bool { bits[index] }

    /// (列, 行) 是否在形状内；越界返回 `false`。
    public func isActive(column: Int, row: Int) -> Bool {
        guard column >= 0, column < columns, row >= 0, row < rows else { return false }
        return bits[row * columns + column]
    }

    /// 形状内格子的下标（升序）。
    public var activeIndices: [Int] {
        var out: [Int] = []
        out.reserveCapacity(activeCount)
        for (w, word) in bits.words.enumerated() {
            var v = word
            while v != 0 {
                let t = v.trailingZeroBitCount
                out.append(w * 64 + t)
                v &= v - 1
            }
        }
        return out
    }

    /// 尺寸是否与网格一致。
    public func matches(_ grid: MosaicGrid) -> Bool { columns == grid.columns && rows == grid.rows }

    // MARK: - bits-v1

    /// `bits-v1` 编码：行优先，每格 1 bit，字节内低位在前，长度 `ceil(columns × rows / 8)`。
    public var bitsV1Bytes: [UInt8] {
        let n = cellCount
        var out = [UInt8](repeating: 0, count: (n + 7) / 8)
        for i in 0..<out.count {
            let word = bits.words[i >> 3]
            out[i] = UInt8(truncatingIfNeeded: word >> UInt64((i & 7) * 8))
        }
        return out
    }

    /// 从 `bits-v1` 字节解码。
    /// - Throws: 字节数不等于 `ceil(columns × rows / 8)`，或末字节补齐位不为 0 时抛 `MosaicError.countMismatch` /
    ///   `MosaicError.invalidGrid`。
    public init(columns: Int, rows: Int, bitsV1 bytes: [UInt8]) throws {
        _ = try MosaicGrid(columns: columns, rows: rows)
        let n = columns * rows
        guard bytes.count == (n + 7) / 8 else {
            throw MosaicError.countMismatch(expected: (n + 7) / 8, actual: bytes.count)
        }
        if n & 7 != 0, let last = bytes.last, last >> UInt8(n & 7) != 0 {
            throw MosaicError.invalidGrid("bits-v1 padding bits must be zero")
        }
        var b = BitMask(count: n)
        for i in 0..<n where (bytes[i >> 3] >> UInt8(i & 7)) & 1 == 1 { b[i] = true }
        try self.init(columns: columns, rows: rows, bits: b)
    }
}
