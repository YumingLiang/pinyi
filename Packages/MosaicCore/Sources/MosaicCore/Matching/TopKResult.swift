/// 每个查询（目标格子）的 top‑k 近邻结果（技术方案 §3.4 第 1 步）。
///
/// 每个查询的候选按 **(距离升序, 下标升序)** 排列；距离相等时用下标打破平局，
/// 保证不同内核（纯 Swift / Accelerate）结果一致（技术方案 §11.1）。
public struct TopKResult: Sendable, Equatable {
    /// 查询个数 M。
    public let queryCount: Int
    /// 每个查询实际返回的候选数：`min(请求的 k, 可用候选数)`。
    public let k: Int
    /// 行优先 `M × k`：第 q 个查询的第 j 名候选下标为 `indices[q * k + j]`。
    public let indices: [UInt32]
    /// 与 `indices` 对应的平方距离。
    public let distances: [Float]

    /// 构造结果。
    /// - Precondition: `indices.count == distances.count == queryCount × k`。
    public init(queryCount: Int, k: Int, indices: [UInt32], distances: [Float]) {
        precondition(indices.count == queryCount * k && distances.count == queryCount * k, "TopKResult size mismatch")
        self.queryCount = queryCount
        self.k = k
        self.indices = indices
        self.distances = distances
    }

    /// 第 `query` 个查询的候选下标（已排序）。
    public func indices(forQuery query: Int) -> ArraySlice<UInt32> {
        indices[(query * k)..<((query + 1) * k)]
    }

    /// 第 `query` 个查询的候选距离（已排序）。
    public func distances(forQuery query: Int) -> ArraySlice<Float> {
        distances[(query * k)..<((query + 1) * k)]
    }

    /// 第 `query` 个查询的 `(下标, 距离)` 列表。
    public func neighbors(forQuery query: Int) -> [Neighbor] {
        (0..<k).map { Neighbor(index: Int(indices[query * k + $0]), distance: distances[query * k + $0]) }
    }
}

/// 一个候选素材及其与查询的平方距离。
public struct Neighbor: Hashable, Sendable {
    /// 素材下标（`FeatureMatrix` 中的列号）。
    public var index: Int
    /// 平方距离。
    public var distance: Float

    /// 构造。
    public init(index: Int, distance: Float) {
        self.index = index
        self.distance = distance
    }
}
