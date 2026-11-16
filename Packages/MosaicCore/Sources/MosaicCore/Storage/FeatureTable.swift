/// 素材特征表：`features.bin` 在内存中的形态（技术方案 v0.2 §2.3）。
///
/// 行号即 `index.sqlite` 中的行号（`localIdentifier ↔ 行号`），删除不移动行，只打 tombstone
/// （`FeatureFlags.deleted`）；空洞率 > 20% 时用 `compacted()` 压缩重写并返回新旧行号映射。
public struct FeatureTable: Sendable, Equatable {
    /// 12 维特征（SoA），直接交给 `DistanceKernel` / `GreedyAssigner`。
    public private(set) var matrix: FeatureMatrix
    /// 每行亮度方差。
    public private(set) var lightnessVariance: [Float]
    /// 每行原图宽高比。
    public private(set) var aspectRatio: [Float]
    /// 每行标志位。
    public private(set) var flags: [FeatureFlags]

    /// 触发压缩的空洞率阈值（方案：> 20%）。
    public static let compactionThreshold = 0.2

    /// 由记录构造（只支持 12 维）。
    public init(records: [FeatureRecord]) {
        matrix = FeatureMatrix(records: records)
        lightnessVariance = records.map(\.lightnessVariance)
        aspectRatio = records.map(\.aspectRatio)
        flags = records.map(\.flags)
    }

    /// 由各列直接构造。
    /// - Throws: 列长度与 `matrix.count` 不一致时抛 `MosaicError.countMismatch`。
    public init(matrix: FeatureMatrix, lightnessVariance: [Float], aspectRatio: [Float], flags: [FeatureFlags]) throws {
        for c in [lightnessVariance.count, aspectRatio.count, flags.count] where c != matrix.count {
            throw MosaicError.countMismatch(expected: matrix.count, actual: c)
        }
        self.matrix = matrix
        self.lightnessVariance = lightnessVariance
        self.aspectRatio = aspectRatio
        self.flags = flags
    }

    /// 行数（含 tombstone）。
    public var count: Int { matrix.count }

    /// 第 `row` 行的完整记录（仅 12 维）。
    public func record(_ row: Int) -> FeatureRecord {
        FeatureRecord(vector: FeatureVector(matrix.row(row)), lightnessVariance: lightnessVariance[row],
                      aspectRatio: aspectRatio[row], flags: flags[row])
    }

    /// 打 tombstone（删除）。
    public mutating func markDeleted(_ row: Int) {
        flags[row].insert(.deleted)
    }

    /// 已删除行数。
    public var tombstoneCount: Int { flags.reduce(0) { $0 + ($1.contains(.deleted) ? 1 : 0) } }

    /// 空洞率（已删除 / 总行数）。
    public var holeRatio: Double { count == 0 ? 0 : Double(tombstoneCount) / Double(count) }

    /// 是否应压缩重写（空洞率 > 20%）。
    public var needsCompaction: Bool { holeRatio > FeatureTable.compactionThreshold }

    /// 未删除行的掩码；与相簿掩码求交后交给匹配器。
    public var liveMask: BitMask {
        var m = BitMask(count: count)
        for i in 0..<count where !flags[i].contains(.deleted) { m[i] = true }
        return m
    }

    /// 压缩：去掉 tombstone 行。
    /// - Returns: 新表，以及 `oldToNew[旧行号] = 新行号`（已删除行为 nil），供更新 `index.sqlite`。
    public func compacted() -> (table: FeatureTable, oldToNew: [Int?]) {
        var keep: [Int] = []
        var map = [Int?](repeating: nil, count: count)
        for i in 0..<count where !flags[i].contains(.deleted) {
            map[i] = keep.count
            keep.append(i)
        }
        let dim = matrix.dimension
        let n = keep.count
        var soa = [Float](repeating: 0, count: dim * n)
        for d in 0..<dim {
            for (j, i) in keep.enumerated() { soa[d * n + j] = matrix.storage[d * count + i] }
        }
        // 维度与长度由构造保证，不会抛错。
        let m = (try? FeatureMatrix(dimension: dim, count: n, soa: soa)) ?? matrix
        let t = FeatureTable(uncheckedMatrix: m, lightnessVariance: keep.map { lightnessVariance[$0] },
                             aspectRatio: keep.map { aspectRatio[$0] }, flags: keep.map { flags[$0] })
        return (t, map)
    }

    /// 只保留前 `prefix` 行（损坏恢复用）。
    func prefix(_ prefix: Int) -> FeatureTable {
        if prefix >= count { return self }
        let dim = matrix.dimension
        var soa = [Float](repeating: 0, count: dim * prefix)
        for d in 0..<dim {
            for i in 0..<prefix { soa[d * prefix + i] = matrix.storage[d * count + i] }
        }
        let m = (try? FeatureMatrix(dimension: dim, count: prefix, soa: soa)) ?? matrix
        return FeatureTable(uncheckedMatrix: m, lightnessVariance: Array(lightnessVariance.prefix(prefix)),
                            aspectRatio: Array(aspectRatio.prefix(prefix)), flags: Array(flags.prefix(prefix)))
    }

    init(uncheckedMatrix: FeatureMatrix, lightnessVariance: [Float], aspectRatio: [Float], flags: [FeatureFlags]) {
        matrix = uncheckedMatrix
        self.lightnessVariance = lightnessVariance
        self.aspectRatio = aspectRatio
        self.flags = flags
    }
}
