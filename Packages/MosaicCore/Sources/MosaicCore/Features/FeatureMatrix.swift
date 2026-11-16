/// 一组特征向量的 SoA（维度优先）连续存储，供距离内核直接扫描（技术方案 §2.3 / §11.1）。
///
/// 布局：`storage[d * count + i]` 为第 `i` 个向量的第 `d` 维。
/// 这样同一维的所有向量连续排列，内层循环可沿向量方向向量化。
public struct FeatureMatrix: Sendable, Equatable {
    /// 维度（默认 12）。
    public let dimension: Int
    /// 向量个数。
    public let count: Int
    /// 维度优先的连续存储，长度 `dimension × count`。
    public let storage: [Float]

    /// 由 SoA 原始数据构造。
    /// - Throws: `MosaicError.invalidConfiguration` 维度 ≤ 0；`MosaicError.countMismatch` 长度不符。
    public init(dimension: Int, count: Int, soa storage: [Float]) throws {
        guard dimension > 0 else { throw MosaicError.invalidConfiguration("dimension must be > 0") }
        guard count >= 0 else { throw MosaicError.invalidConfiguration("count must be >= 0") }
        guard storage.count == dimension * count else {
            throw MosaicError.countMismatch(expected: dimension * count, actual: storage.count)
        }
        self.dimension = dimension
        self.count = count
        self.storage = storage
    }

    /// 由 AoS 行（每行一个向量）构造。
    /// - Throws: 任何一行长度 ≠ `dimension` 时抛 `MosaicError.dimensionMismatch`。
    public init(dimension: Int, rows: [[Float]]) throws {
        guard dimension > 0 else { throw MosaicError.invalidConfiguration("dimension must be > 0") }
        var s = [Float](repeating: 0, count: dimension * rows.count)
        for (i, row) in rows.enumerated() {
            guard row.count == dimension else { throw MosaicError.dimensionMismatch(expected: dimension, actual: row.count) }
            for d in 0..<dimension { s[d * rows.count + i] = row[d] }
        }
        self.dimension = dimension
        self.count = rows.count
        self.storage = s
    }

    /// 由 12 维特征向量构造。
    public init(vectors: [FeatureVector]) {
        let n = vectors.count
        let dim = FeatureVector.dimension
        var s = [Float](repeating: 0, count: dim * n)
        for (i, v) in vectors.enumerated() {
            for d in 0..<dim { s[d * n + i] = v.storage[d] }
        }
        self.dimension = dim
        self.count = n
        self.storage = s
    }

    /// 由特征记录构造（只取 12 维向量）。
    public init(records: [FeatureRecord]) {
        self.init(vectors: records.map(\.vector))
    }

    /// 第 `index` 个向量的第 `d` 维。
    @inlinable
    public func value(dimension d: Int, index: Int) -> Float {
        storage[d * count + index]
    }

    /// 取出第 `index` 个向量（AoS）。
    public func row(_ index: Int) -> [Float] {
        precondition(index >= 0 && index < count)
        return (0..<dimension).map { storage[$0 * count + index] }
    }

    /// 只取一个向量组成新的 1×dim 矩阵（用于单格回退重算）。
    public func subset(_ index: Int) -> FeatureMatrix {
        // 单个向量时 SoA 与 AoS 布局相同。
        FeatureMatrix(uncheckedDimension: dimension, count: 1, storage: row(index))
    }

    private init(uncheckedDimension dimension: Int, count: Int, storage: [Float]) {
        self.dimension = dimension
        self.count = count
        self.storage = storage
    }
}
