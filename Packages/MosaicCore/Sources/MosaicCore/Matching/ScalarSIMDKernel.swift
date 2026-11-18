import Dispatch
import Foundation

/// 纯 Swift 的 CPU 暴力 top‑k 内核（参考实现，Linux / iOS 通用，技术方案 §3.3 推荐方案）。
///
/// 实现要点：
/// - 候选按 `candidateTileSize` 分块（12 维 × 1024 × 4 B ≈ 48 KB，可放进 L1/L2），
///   查询按 `queryBlockSize` 分组；同一组查询复用同一个候选块，减少内存带宽。
/// - 内层循环沿候选方向（SoA 连续）累加 `(c − q)²`，编译器可自动向量化。
/// - 每个查询维护大小为 k 的最大堆，比较键为 (距离, 下标)，结果与求和顺序无关的部分完全确定。
/// - `parallel == true` 时用 `DispatchQueue.concurrentPerform` 按查询组并行；
///   各组写入互不重叠的输出区间，结果与串行完全一致。
public struct ScalarSIMDKernel: DistanceKernel {
    /// 是否多核并行。
    public var parallel: Bool
    /// 每个并行任务处理的查询数。
    public var queryBlockSize: Int
    /// 候选分块大小。
    public var candidateTileSize: Int

    /// 创建内核。
    /// - Parameters:
    ///   - parallel: 是否并行，默认 true。
    ///   - queryBlockSize: 每组查询数，默认 16（≥ 1）。
    ///   - candidateTileSize: 候选分块大小，默认 1024（≥ 1）。
    public init(parallel: Bool = true, queryBlockSize: Int = 16, candidateTileSize: Int = 1024) {
        self.parallel = parallel
        self.queryBlockSize = max(1, queryBlockSize)
        self.candidateTileSize = max(1, candidateTileSize)
    }

    /// 见 `DistanceKernel.topK`。
    public func topK(
        queries: UnsafeBufferPointer<Float>, m: Int,
        candidates: UnsafeBufferPointer<Float>, n: Int,
        dims: Int, k: Int, mask: BitMask?
    ) -> TopKResult {
        // 不可取消路径：不传令牌且不看 Task 状态，因此不会抛错。
        // swiftlint:disable:next force_try
        try! run(queries: queries, m: m, candidates: candidates, n: n, dims: dims, k: k, mask: mask,
                 cancellation: nil, observeTask: false, progress: nil)
    }

    /// 可取消版本：每个查询组（默认 16 个查询 × 全部候选）开始前检查一次取消，
    /// 取消响应延迟 ≈ 一个查询组的耗时（5 万候选时约 1–3 ms / 核）。
    public func topK(
        queries: UnsafeBufferPointer<Float>, m: Int,
        candidates: UnsafeBufferPointer<Float>, n: Int,
        dims: Int, k: Int, mask: BitMask?,
        cancellation: CancellationToken?, progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) throws -> TopKResult {
        try run(queries: queries, m: m, candidates: candidates, n: n, dims: dims, k: k, mask: mask,
                cancellation: cancellation, observeTask: true, progress: progress)
    }

    private func run(
        queries: UnsafeBufferPointer<Float>, m: Int,
        candidates: UnsafeBufferPointer<Float>, n: Int,
        dims: Int, k: Int, mask: BitMask?,
        cancellation: CancellationToken?, observeTask: Bool,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) throws -> TopKResult {
        if observeTask { try CancellationCheck(token: cancellation).check() }
        precondition(dims > 0 && m >= 0 && n >= 0 && k >= 0, "invalid topK arguments")
        precondition(queries.count >= dims * m, "queries buffer too small")
        precondition(candidates.count >= dims * n, "candidates buffer too small")
        if let mask { precondition(mask.count == n, "mask length must equal candidate count") }

        let available = mask.map { $0.setCount } ?? n
        let kEff = min(k, available)
        guard m > 0, kEff > 0, let qBase = queries.baseAddress, let cBase = candidates.baseAddress else {
            return TopKResult(queryCount: m, k: kEff, indices: [], distances: [])
        }

        var outIndices = [UInt32](repeating: 0, count: m * kEff)
        var outDistances = [Float](repeating: 0, count: m * kEff)
        let maskWords: [UInt64]? = mask?.words
        let qb = queryBlockSize
        let tile = candidateTileSize
        let blockCount = (m + qb - 1) / qb
        // 内部停止标志：任一线程发现取消（令牌，或调用线程上的 Task 取消）即置位，其余组直接跳过。
        let stop = CancellationToken()
        let counter = ProgressCounter(total: blockCount, handler: progress)

        outIndices.withUnsafeMutableBufferPointer { oi in
            outDistances.withUnsafeMutableBufferPointer { od in
                let ptrs = KernelPointers(q: qBase, c: cBase, outIndices: oi.baseAddress!, outDistances: od.baseAddress!)
                let work: @Sendable (Int) -> Void = { block in
                    if stop.isCancelled { return }
                    if (cancellation?.isCancelled ?? false) || (observeTask && Task.isCancelled) {
                        stop.cancel()
                        return
                    }
                    let qStart = block * qb
                    let qEnd = min(m, qStart + qb)
                    // 每个候选块（tile）之间也检查一次：一组查询要扫完全部候选，只在组间检查时
                    // 取消延迟 = 一整组的耗时（Debug / 模拟器 2 万候选约 0.5–0.8 s，PR #1 CI 805 ms）。
                    let finished = ScalarSIMDKernel.processBlock(
                        qStart: qStart, qEnd: qEnd, m: m, q: ptrs.q,
                        n: n, c: ptrs.c, dims: dims, k: kEff, tile: tile,
                        maskWords: maskWords, outIndices: ptrs.outIndices, outDistances: ptrs.outDistances,
                        shouldStop: {
                            if stop.isCancelled { return true }
                            if cancellation?.isCancelled ?? false { stop.cancel(); return true }
                            return false
                        }
                    )
                    if finished { counter.increment() }
                }
                if parallel && blockCount > 1 {
                    DispatchQueue.concurrentPerform(iterations: blockCount, execute: work)
                } else {
                    for b in 0..<blockCount { work(b) }
                }
            }
        }
        // 任何一组被跳过 → 整体作废，不返回部分结果。
        if stop.isCancelled || (observeTask && CancellationCheck(token: cancellation).isCancelled) {
            throw CancellationError()
        }
        return TopKResult(queryCount: m, k: kEff, indices: outIndices, distances: outDistances)
    }

    // MARK: - 内部实现

    /// 处理一组查询。每个候选块开始前调用 `shouldStop`；返回 `false` 表示中途停止（输出未写，调用方须丢弃整体结果）。
    /// internal 供测试直接验证检查粒度。
    @discardableResult
    static func processBlock(
        qStart: Int, qEnd: Int, m: Int, q: UnsafePointer<Float>,
        n: Int, c: UnsafePointer<Float>, dims: Int, k: Int, tile: Int,
        maskWords: [UInt64]?,
        outIndices: UnsafeMutablePointer<UInt32>, outDistances: UnsafeMutablePointer<Float>,
        shouldStop: () -> Bool = { false }
    ) -> Bool {
        let qCount = qEnd - qStart
        // 每个查询一个大小为 k 的最大堆（根 = 当前最差候选）。
        let heapD = UnsafeMutablePointer<Float>.allocate(capacity: qCount * k)
        let heapI = UnsafeMutablePointer<UInt32>.allocate(capacity: qCount * k)
        var heapCount = [Int](repeating: 0, count: qCount)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: tile)
        let qv = UnsafeMutablePointer<Float>.allocate(capacity: dims)
        defer {
            heapD.deallocate()
            heapI.deallocate()
            scratch.deallocate()
            qv.deallocate()
        }

        var t0 = 0
        while t0 < n {
            if shouldStop() { return false }
            let t1 = min(n, t0 + tile)
            let len = t1 - t0
            for qi in 0..<qCount {
                let qIndex = qStart + qi
                for d in 0..<dims { qv[d] = q[d * m + qIndex] }

                // 距离：沿候选方向连续累加，便于自动向量化。
                scratch.initialize(repeating: 0, count: len)
                for d in 0..<dims {
                    let qd = qv[d]
                    let col = c + d * n + t0
                    for j in 0..<len {
                        let diff = col[j] - qd
                        scratch[j] += diff * diff
                    }
                }

                let hd = heapD + qi * k
                let hi = heapI + qi * k
                var count = heapCount[qi]
                for j in 0..<len {
                    let idx = t0 + j
                    let dist = scratch[j]
                    let uidx = UInt32(truncatingIfNeeded: idx)
                    // 评审 S5：先与堆顶比较（堆满后绝大多数候选在这里被淘汰），再查掩码。
                    if count == k, !isWorse(hd[0], hi[0], than: dist, uidx) { continue }
                    if let words = maskWords, (words[idx >> 6] >> UInt64(idx & 63)) & 1 == 0 { continue }
                    if count < k {
                        heapPush(hd, hi, &count, dist, uidx)
                    } else {
                        hd[0] = dist
                        hi[0] = uidx
                        siftDown(hd, hi, count, 0)
                    }
                }
                heapCount[qi] = count
            }
            t0 = t1
        }

        // 输出：按 (距离, 下标) 升序。
        var pairs = [(Float, UInt32)]()
        pairs.reserveCapacity(k)
        for qi in 0..<qCount {
            pairs.removeAll(keepingCapacity: true)
            let count = heapCount[qi]
            for j in 0..<count { pairs.append((heapD[qi * k + j], heapI[qi * k + j])) }
            pairs.sort { a, b in a.0 < b.0 || (a.0 == b.0 && a.1 < b.1) }
            let base = (qStart + qi) * k
            for j in 0..<count {
                outDistances[base + j] = pairs[j].0
                outIndices[base + j] = pairs[j].1
            }
        }
        return true
    }

    /// (d1, i1) 是否比 (d2, i2) 更差（距离更大，或距离相等但下标更大）。
    @inline(__always)
    private static func isWorse(_ d1: Float, _ i1: UInt32, than d2: Float, _ i2: UInt32) -> Bool {
        d1 > d2 || (d1 == d2 && i1 > i2)
    }

    @inline(__always)
    private static func heapPush(_ hd: UnsafeMutablePointer<Float>, _ hi: UnsafeMutablePointer<UInt32>,
                                 _ count: inout Int, _ d: Float, _ i: UInt32) {
        var pos = count
        hd[pos] = d
        hi[pos] = i
        count += 1
        while pos > 0 {
            let parent = (pos - 1) / 2
            if isWorse(hd[pos], hi[pos], than: hd[parent], hi[parent]) {
                hd.swapAt(pos, parent)
                hi.swapAt(pos, parent)
                pos = parent
            } else { break }
        }
    }

    @inline(__always)
    private static func siftDown(_ hd: UnsafeMutablePointer<Float>, _ hi: UnsafeMutablePointer<UInt32>,
                                 _ count: Int, _ start: Int) {
        var pos = start
        while true {
            let l = 2 * pos + 1
            let r = l + 1
            var worst = pos
            if l < count, isWorse(hd[l], hi[l], than: hd[worst], hi[worst]) { worst = l }
            if r < count, isWorse(hd[r], hi[r], than: hd[worst], hi[worst]) { worst = r }
            if worst == pos { return }
            hd.swapAt(pos, worst)
            hi.swapAt(pos, worst)
            pos = worst
        }
    }
}

/// 并行任务间共享的原始指针。
///
/// 安全性：输入缓冲区只读；每个任务只写入自己查询组对应的输出区间
/// `[qStart * k, qEnd * k)`，区间互不重叠，且 `concurrentPerform` 返回前所有任务均已结束，
/// 指针在 `withUnsafe…` 作用域内始终有效。
private struct KernelPointers: @unchecked Sendable {
    let q: UnsafePointer<Float>
    let c: UnsafePointer<Float>
    let outIndices: UnsafeMutablePointer<UInt32>
    let outDistances: UnsafeMutablePointer<Float>
}

extension UnsafeMutablePointer {
    @inline(__always)
    fileprivate func swapAt(_ a: Int, _ b: Int) {
        let t = self[a]
        self[a] = self[b]
        self[b] = t
    }
}

/// 线程安全的进度计数器（评审 ca6a4ca S-2）：**锁内只递增**，回调在计数锁之外调用，
/// 工作线程不会因为 App 的回调慢 / 阻塞而互相卡住。
///
/// 回调串行化由单独的 `reportLock` 负责：中间进度用 `try()`，拿不到就跳过这次上报（不阻塞工作线程）；
/// 只上报比上次大的值，所以 `completed` 单调；最后一次（done == total）用阻塞方式上报，保证 100% 一定送达。
/// 回调可能在任意工作线程上调用，不应做 `DispatchQueue.main.sync` 之类的阻塞操作。
final class ProgressCounter: Sendable {
    private let done = LockedState(0)
    /// 上报锁：保护"已上报的最大值"，同时把回调串行化。
    private let reported = LockedState(0)
    private let total: Int
    private let handler: (@Sendable (Int, Int) -> Void)?

    init(total: Int, handler: (@Sendable (Int, Int) -> Void)?) {
        self.total = total
        self.handler = handler
    }

    func increment() {
        guard let handler else { return }
        let now = done.withLock { d -> Int in d += 1; return d }
        let isFinal = now >= total
        let done = self.done
        let total = self.total
        let report: (inout Int) -> Void = { rep in
            // 拿到上报锁后读最新计数（可能已被别的线程推进），只报更大的值。
            let latest = done.get()
            if latest > rep {
                rep = latest
                handler(latest, total)
            }
        }
        if isFinal { reported.withLock(report) } else { _ = reported.withLockIfAvailable(report) }
    }
}
