/// 距离 + top‑k 内核的抽象（技术方案 §11.1）。
///
/// - Linux / iOS 通用参考实现：`ScalarSIMDKernel`（本模块）。
/// - Apple 平台加速实现：放在独立的 `MosaicAccelerate` 包中，用 `#if canImport(Accelerate)` 守卫，
///   本模块不 import 任何 Apple 专有框架。
/// - Metal compute 版本：MVP 不做，仅在真机基准不达标时实现同一协议。
///
/// 实现必须满足：
/// 1. 距离为平方欧氏距离 `Σ_d (q_d − c_d)²`；
/// 2. 每个查询返回 `min(k, 可用候选数)` 个结果，按 (距离升序, 下标升序) 排序；
/// 3. `mask` 非 nil 时只考虑对应位为 1 的候选；
/// 4. 纯函数、线程安全（`Sendable`），同输入同输出。
public protocol DistanceKernel: Sendable {
    /// 计算每个查询的 top‑k 近邻。
    ///
    /// - Parameters:
    ///   - queries: SoA `dims × m`（`queries[d * m + q]`）。
    ///   - m: 查询个数。
    ///   - candidates: SoA `dims × n`（`candidates[d * n + i]`）。
    ///   - n: 候选个数。
    ///   - dims: 维度。
    ///   - k: 请求的近邻个数（≥ 0）。
    ///   - mask: 可用候选掩码，长度必须为 `n`；`nil` 表示全部可用。
    /// - Returns: `TopKResult`，其 `k` 为实际返回个数。
    func topK(
        queries: UnsafeBufferPointer<Float>, m: Int,
        candidates: UnsafeBufferPointer<Float>, n: Int,
        dims: Int, k: Int, mask: BitMask?
    ) -> TopKResult

    /// 可取消版本：语义同上，但在计算过程中协作式检查取消。
    ///
    /// - Parameters:
    ///   - cancellation: 显式令牌；`nil` 时只检查调用线程所在 Task 的取消状态。
    ///   - progress: `(已完成查询组, 总查询组)`，可能在工作线程调用。
    /// - Throws: 取消时抛 `CancellationError`，不返回部分结果。
    /// 默认实现只在开始前/结束后检查取消（适合尚未支持分块检查的实现，如 Accelerate 占位）。
    func topK(
        queries: UnsafeBufferPointer<Float>, m: Int,
        candidates: UnsafeBufferPointer<Float>, n: Int,
        dims: Int, k: Int, mask: BitMask?,
        cancellation: CancellationToken?, progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) throws -> TopKResult
}

extension DistanceKernel {
    /// 默认的可取消实现：前后各检查一次。
    public func topK(
        queries: UnsafeBufferPointer<Float>, m: Int,
        candidates: UnsafeBufferPointer<Float>, n: Int,
        dims: Int, k: Int, mask: BitMask?,
        cancellation: CancellationToken?, progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) throws -> TopKResult {
        let check = CancellationCheck(token: cancellation)
        try check.check()
        let r = topK(queries: queries, m: m, candidates: candidates, n: n, dims: dims, k: k, mask: mask)
        try check.check()
        progress?(1, 1)
        return r
    }
}

extension DistanceKernel {
    /// 以 `FeatureMatrix` 为输入的安全封装：先校验维度与掩码长度。
    ///
    /// - Throws: `MosaicError.dimensionMismatch`、`MosaicError.countMismatch`、
    ///   `MosaicError.invalidConfiguration`（k < 0）。
    public func topK(queries: FeatureMatrix, candidates: FeatureMatrix, k: Int, mask: BitMask? = nil) throws -> TopKResult {
        try topK(queries: queries, candidates: candidates, k: k, mask: mask, cancellation: nil, progress: nil)
    }

    /// 可取消的 `FeatureMatrix` 封装。
    /// - Throws: 同上；取消时抛 `CancellationError`。
    public func topK(queries: FeatureMatrix, candidates: FeatureMatrix, k: Int, mask: BitMask?,
                     cancellation: CancellationToken?,
                     progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) throws -> TopKResult {
        guard queries.dimension == candidates.dimension else {
            throw MosaicError.dimensionMismatch(expected: candidates.dimension, actual: queries.dimension)
        }
        guard k >= 0 else { throw MosaicError.invalidConfiguration("k must be >= 0") }
        if let mask, mask.count != candidates.count {
            throw MosaicError.countMismatch(expected: candidates.count, actual: mask.count)
        }
        return try queries.storage.withUnsafeBufferPointer { q in
            try candidates.storage.withUnsafeBufferPointer { c in
                try topK(queries: q, m: queries.count, candidates: c, n: candidates.count,
                         dims: queries.dimension, k: k, mask: mask, cancellation: cancellation, progress: progress)
            }
        }
    }
}

/// 两个等长向量的平方欧氏距离（参考实现，便于测试与对拍）。
/// - Precondition: `a.count == b.count`。
public func squaredEuclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "vector length mismatch")
    var s: Float = 0
    for i in a.indices {
        let d = a[i] - b[i]
        s += d * d
    }
    return s
}
