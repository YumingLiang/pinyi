import Dispatch

/// 全库搜索并行任务共享的原始指针。安全性：输入只读；每个任务只写自己块的 `dist[lo..<hi]` 与
/// `best*[c]`，互不重叠；`concurrentPerform` 返回前全部完成，指针在 `withUnsafe…` 作用域内有效。
private struct ScanPointers: @unchecked Sendable {
    let dist: UnsafeMutablePointer<Float>
    let lib: UnsafePointer<Float>
    let uses: UnsafePointer<Int32>
    let bestIdx: UnsafeMutablePointer<Int>
    let bestScore: UnsafeMutablePointer<Float>
    let bestDist: UnsafeMutablePointer<Float>
}

/// 单张素材的使用上限（技术方案 §3.4 第 3 步）。
public enum UsageCap: Hashable, Sendable {
    /// 自动：`cap = max(1, ceil(格子数 / 可用素材数 × multiplier))`，方案默认 multiplier = 2。
    case automatic(multiplier: Double)
    /// 固定上限（≥ 1）。对应用户可调的 1 / 2 / 3。
    case limited(Int)
    /// 不限。
    case unlimited

    /// 方案默认：`.automatic(multiplier: 2)`。
    public static let `default` = UsageCap.automatic(multiplier: 2)

    /// 求出具体上限；`nil` 表示不限。
    public func resolve(cellCount: Int, availableCount: Int) -> Int? {
        switch self {
        case .unlimited:
            return nil
        case .limited(let n):
            return max(1, n)
        case .automatic(let multiplier):
            guard availableCount > 0 else { return nil }
            let raw = (Double(cellCount) / Double(availableCount) * multiplier).rounded(.up)
            return max(1, Int(raw))
        }
    }
}

/// 格子的遍历顺序（技术方案 §3.4 第 2 步：随机顺序，避免左上→右下的质量偏差）。
public enum CellOrder: Hashable, Sendable {
    /// 用配置中的种子生成随机排列（默认）。
    case seededRandom
    /// 行优先（主要用于测试与对比）。
    case rowMajor
    /// 自定义顺序（必须是 `0..<格子数` 的一个排列），例如"显著区域优先"。
    case custom([Int])
}

/// 约束贪心的配置。
public struct AssignmentConfiguration: Hashable, Sendable {
    /// 首轮每格候选数（方案默认 32）。
    public var k: Int
    /// 回退第 1 步扩展后的候选数（方案默认 128）。
    public var fallbackK: Int
    /// 使用次数惩罚系数 λ：`score = dist + λ · uses(i)`。默认 0.005（OKLab 12 维平方距离尺度，待合成数据 A/B 调参）。
    public var usagePenalty: Float
    /// 单张素材使用上限。
    public var cap: UsageCap
    /// 主邻域：在其中已出现的素材不可再用（默认 8 邻域）。
    public var neighborhood: Neighborhood
    /// 回退时放宽后的邻域（默认 4 邻域）。
    public var relaxedNeighborhood: Neighborhood
    /// 随机种子；用户点"换一个"即换种子。
    public var seed: UInt64
    /// 遍历顺序。
    public var order: CellOrder
    /// 扩到 `fallbackK` 仍失败时，是否先在**全部**可用素材里找满足主邻域 + 上限的素材，再考虑放宽约束。
    /// 默认 true（对方案 §3.4 回退链的补充，待架构师确认）：避免目标图大片同色时 128 个近邻被上限用尽，
    /// 明明还有大量未用素材却"忽略上限"并误报素材不足。
    public var exhaustiveSearchBeforeRelaxing: Bool

    /// 创建配置；所有参数都有方案默认值。
    public init(
        k: Int = 32,
        fallbackK: Int = 128,
        usagePenalty: Float = 0.005,
        cap: UsageCap = .default,
        neighborhood: Neighborhood = .eight,
        relaxedNeighborhood: Neighborhood = .four,
        seed: UInt64 = 0,
        order: CellOrder = .seededRandom,
        exhaustiveSearchBeforeRelaxing: Bool = true
    ) {
        self.exhaustiveSearchBeforeRelaxing = exhaustiveSearchBeforeRelaxing
        self.k = k
        self.fallbackK = fallbackK
        self.usagePenalty = usagePenalty
        self.cap = cap
        self.neighborhood = neighborhood
        self.relaxedNeighborhood = relaxedNeighborhood
        self.seed = seed
        self.order = order
    }

    /// 按档位的默认配置。技术方案 v0.2 §3.4 / 产品决定第 10 条：**所有档位邻域半径默认 1（8 邻域）**；
    /// 120 档是否改 2 待合成测试 + TF2 目测后由架构师定（届时只改这里，作为引擎内部常量，不做 UI）。
    public static func recommended(for density: Density, seed: UInt64 = 0) -> AssignmentConfiguration {
        _ = density
        return AssignmentConfiguration(seed: seed)
    }

    /// 方案默认上限公式：`max(1, ceil(格子数 / 可用素材数 × 2))`（与 `UsageCap.default` 一致）。
    public static func defaultCap(cellCount: Int, availableCount: Int) -> Int {
        UsageCap.default.resolve(cellCount: cellCount, availableCount: max(1, availableCount)) ?? 1
    }

    /// 「换一种拼法」：只换种子、其余参数不变（产品决定第 4 条）。
    public func withSeed(_ seed: UInt64) -> AssignmentConfiguration {
        var c = self
        c.seed = seed
        return c
    }

    /// 校验参数。
    public func validate() throws {
        guard k >= 1 else { throw MosaicError.invalidConfiguration("k must be >= 1") }
        guard fallbackK >= 1 else { throw MosaicError.invalidConfiguration("fallbackK must be >= 1") }
        guard usagePenalty >= 0, usagePenalty.isFinite else {
            throw MosaicError.invalidConfiguration("usagePenalty must be finite and >= 0")
        }
        if case .automatic(let m) = cap, !(m > 0 && m.isFinite) {
            throw MosaicError.invalidConfiguration("automatic cap multiplier must be > 0")
        }
        if case .limited(let n) = cap, n < 1 {
            throw MosaicError.invalidConfiguration("limited cap must be >= 1")
        }
    }
}

/// 每个格子最终在哪一级回退上找到素材（技术方案 §3.4 第 4 步）。
public enum FallbackLevel: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// 首轮 top‑k，主邻域 + 上限都满足。
    case primary = 0
    /// top‑k 全被禁，扩到 `fallbackK` 重算该格后满足主邻域 + 上限。
    case expandedCandidates = 1
    /// 扩到 `fallbackK` 仍失败，在全部可用素材中找到满足主邻域 + 上限者（不算放宽）。
    case exhaustiveSearch = 2
    /// 放宽为 `relaxedNeighborhood`（默认 4 邻域），仍满足上限。
    case relaxedNeighborhood = 3
    /// 忽略上限（仍满足放宽后的邻域）。结果页应提示"素材不足"。
    case capIgnored = 4
    /// 最后兜底：忽略邻域与上限，取得分最低者（素材极少，例如只有 1–2 张）。
    case neighborhoodIgnored = 5

    /// 按原始值比较。
    public static func < (lhs: FallbackLevel, rhs: FallbackLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 分配结果统计，供结果页提示与性能页展示。
public struct AssignmentStatistics: Hashable, Sendable {
    /// 格子数。
    public var cellCount: Int
    /// 可用素材数（掩码后）。
    public var availableCandidates: Int
    /// 实际生效的单张上限；`nil` 表示不限。
    public var resolvedCap: Int?
    /// 各回退级别的格子数，下标为 `FallbackLevel.rawValue`。
    public var levelCounts: [Int]
    /// 实际用到的不同素材数。
    public var distinctTilesUsed: Int
    /// 单张素材的最大使用次数。
    public var maxUses: Int
    /// 所有格子匹配距离之和。
    public var totalDistance: Double

    /// 平均匹配距离。
    public var meanDistance: Double { cellCount == 0 ? 0 : totalDistance / Double(cellCount) }
    /// 某一级回退的格子数。
    public func count(at level: FallbackLevel) -> Int { levelCounts[level.rawValue] }
    /// 是否有格子用到了回退。
    public var usedFallback: Bool { levelCounts.dropFirst().contains { $0 > 0 } }
    /// 实际放宽过约束的格子数（放宽邻域 / 忽略上限 / 忽略邻域；**不含**仅扩大 k 的情况）。
    public var relaxationCount: Int {
        count(at: .relaxedNeighborhood) + count(at: .capIgnored) + count(at: .neighborhoodIgnored)
    }
    /// 是否实际放宽过约束（技术方案 v0.2 §3.4 `relaxedConstraints`）。
    /// 为 true 时结果页显示素材不足短版提示（文案 key 见 copy_v1.1）。
    public var relaxedConstraints: Bool { relaxationCount > 0 }
    /// 可用素材是否低于素材不足阈值（200 张，`MaterialSupply.insufficientThreshold`）。
    public var isBelowMaterialThreshold: Bool { MaterialSupply.evaluate(availableCount: availableCandidates) != .sufficient }
    /// 可用素材少于格子数，必然重复（对应文案"照片不够，会重复使用一些"）。
    public var needsRepetition: Bool { availableCandidates < cellCount }
}

/// 一次分配的结果：每个格子用哪张素材。
public struct MosaicAssignment: Hashable, Sendable {
    /// 网格。
    public let grid: MosaicGrid
    /// 行优先：每个格子选中的素材下标（`FeatureMatrix` 列号）。
    public let tiles: [Int]
    /// 每个格子的平方距离。
    public let distances: [Float]
    /// 每个格子的回退级别。
    public let levels: [FallbackLevel]
    /// 统计。
    public let statistics: AssignmentStatistics
    /// 生成时使用的种子。
    public let seed: UInt64

    /// 指定格子的素材下标。
    public func tile(column: Int, row: Int) -> Int { tiles[grid.index(column: column, row: row)] }
}

/// 带惩罚的随机顺序贪心分配器（技术方案 §3.4）。
///
/// 流程：
/// 1. 用 `kernel` 为每个格子算 top‑k（k = 32）。
/// 2. 按种子化随机顺序逐格处理。
/// 3. 对候选 i 打分 `score = dist(c, i) + λ · uses(i)`；
///    若 i 已出现在 c 的主邻域中（只看已分配的邻居）或 `uses(i) ≥ cap`，则禁用。取最低分，
///    平局按 (距离, 下标) 升序。
/// 4. 回退链（逐级尝试，记录在 `levels` 中）：
///    top‑k → 扩到 fallbackK 重算该格 →（补充）全库搜索 → 放宽为 4 邻域 → 忽略上限 → 忽略邻域。
///    只有后三级算"放宽约束"（`relaxedConstraints`）。
///
/// 因为每格只与"已分配"的邻居比较，且邻域关系对称，所以只要所有格子都在 `.primary/.expandedCandidates/.exhaustiveSearch`
/// 级别完成，最终结果中任意两个主邻域内的格子都不相同。
/// 结果只由（输入、配置、种子）决定，与线程数无关。
public struct GreedyAssigner: Sendable {
    /// 配置。
    public var configuration: AssignmentConfiguration
    /// 距离内核。
    public var kernel: any DistanceKernel

    /// 创建分配器。
    public init(configuration: AssignmentConfiguration = AssignmentConfiguration(), kernel: any DistanceKernel = ScalarSIMDKernel()) {
        self.configuration = configuration
        self.kernel = kernel
    }

    /// 执行分配。
    ///
    /// - Parameters:
    ///   - grid: 网格。
    ///   - cellFeatures: 每个格子的特征（行优先，个数 = `grid.cellCount`）。
    ///   - library: 素材特征矩阵。
    ///   - mask: 可用素材掩码（选相簿 / 排除已删除），长度 = `library.count`。
    /// - Returns: 分配结果。空网格返回空结果。
    /// - Throws: 维度/个数不一致、配置非法、无可用素材（`MosaicError.noCandidates`）。
    public func assign(grid: MosaicGrid, cellFeatures: FeatureMatrix, library: FeatureMatrix, mask: BitMask? = nil) throws -> MosaicAssignment {
        let config = configuration
        try config.validate()
        guard cellFeatures.count == grid.cellCount else {
            throw MosaicError.countMismatch(expected: grid.cellCount, actual: cellFeatures.count)
        }
        guard cellFeatures.dimension == library.dimension else {
            throw MosaicError.dimensionMismatch(expected: library.dimension, actual: cellFeatures.dimension)
        }
        if let mask, mask.count != library.count {
            throw MosaicError.countMismatch(expected: library.count, actual: mask.count)
        }

        let cellCount = grid.cellCount
        let available = mask?.setCount ?? library.count

        if cellCount == 0 {
            return MosaicAssignment(
                grid: grid, tiles: [], distances: [], levels: [],
                statistics: AssignmentStatistics(
                    cellCount: 0, availableCandidates: available,
                    resolvedCap: config.cap.resolve(cellCount: 0, availableCount: available),
                    levelCounts: Array(repeating: 0, count: FallbackLevel.allCases.count),
                    distinctTilesUsed: 0, maxUses: 0, totalDistance: 0),
                seed: config.seed)
        }
        guard available > 0 else { throw MosaicError.noCandidates }

        let cap = config.cap.resolve(cellCount: cellCount, availableCount: available)
        let order = try makeOrder(cellCount: cellCount, config: config)
        let topK = try kernel.topK(queries: cellFeatures, candidates: library, k: config.k, mask: mask)
        let canExpand = config.fallbackK > topK.k && available > topK.k

        var uses = [Int32](repeating: 0, count: library.count)
        var assigned = [Int](repeating: -1, count: cellCount)
        var distances = [Float](repeating: 0, count: cellCount)
        var levels = [FallbackLevel](repeating: .primary, count: cellCount)
        let lambda = config.usagePenalty

        let maskWords = mask?.words
        var scratch: [Float] = []   // 全库搜索时复用的距离缓冲（按需分配）
        var primaryTiles: [Int] = []
        var relaxedTiles: [Int] = []

        for cell in order {
            collectAssigned(cell, grid: grid, neighborhood: config.neighborhood, assigned: assigned, into: &primaryTiles)
            collectAssigned(cell, grid: grid, neighborhood: config.relaxedNeighborhood, assigned: assigned, into: &relaxedTiles)

            var list = topK.neighbors(forQuery: cell)
            var choice: (Neighbor, FallbackLevel)?

            if let n = pick(list, forbidden: primaryTiles, cap: cap, uses: uses, lambda: lambda) {
                choice = (n, .primary)
            } else {
                if canExpand {
                    list = try kernel.topK(queries: cellFeatures.subset(cell), candidates: library,
                                           k: config.fallbackK, mask: mask).neighbors(forQuery: 0)
                    if let n = pick(list, forbidden: primaryTiles, cap: cap, uses: uses, lambda: lambda) {
                        choice = (n, .expandedCandidates)
                    }
                }
                if choice == nil, config.exhaustiveSearchBeforeRelaxing, available > list.count {
                    if let n = exhaustivePick(cell: cell, cellFeatures: cellFeatures, library: library, maskWords: maskWords,
                                              forbidden: primaryTiles, cap: cap, uses: uses, lambda: lambda, scratch: &scratch) {
                        choice = (n, .exhaustiveSearch)
                    } else {
                        // 极少走到：全部可用素材都已到上限或在主邻域内，后续放宽级别也在全库上选。
                        list = allCandidates(scratch: scratch, maskWords: maskWords)
                    }
                }
                if choice == nil, let n = pick(list, forbidden: relaxedTiles, cap: cap, uses: uses, lambda: lambda) {
                    choice = (n, .relaxedNeighborhood)
                }
                if choice == nil, let n = pick(list, forbidden: relaxedTiles, cap: nil, uses: uses, lambda: lambda) {
                    choice = (n, .capIgnored)
                }
                if choice == nil, let n = pick(list, forbidden: [], cap: nil, uses: uses, lambda: lambda) {
                    choice = (n, .neighborhoodIgnored)
                }
            }

            // list 非空（available > 0 且 k ≥ 1），最后一级必然成功。
            guard let (n, level) = choice else { throw MosaicError.noCandidates }
            assigned[cell] = n.index
            distances[cell] = n.distance
            levels[cell] = level
            uses[n.index] += 1
        }

        var levelCounts = [Int](repeating: 0, count: FallbackLevel.allCases.count)
        for l in levels { levelCounts[l.rawValue] += 1 }
        let stats = AssignmentStatistics(
            cellCount: cellCount,
            availableCandidates: available,
            resolvedCap: cap,
            levelCounts: levelCounts,
            distinctTilesUsed: uses.reduce(0) { $0 + ($1 > 0 ? 1 : 0) },
            maxUses: Int(uses.max() ?? 0),
            totalDistance: distances.reduce(0) { $0 + Double($1) }
        )
        return MosaicAssignment(grid: grid, tiles: assigned, distances: distances, levels: levels,
                                statistics: stats, seed: config.seed)
    }

    // MARK: - 内部

    private func makeOrder(cellCount: Int, config: AssignmentConfiguration) throws -> [Int] {
        switch config.order {
        case .seededRandom:
            var rng = Xoshiro256StarStar(seed: config.seed)
            return rng.permutation(count: cellCount)
        case .rowMajor:
            return Array(0..<cellCount)
        case .custom(let order):
            guard order.count == cellCount else {
                throw MosaicError.countMismatch(expected: cellCount, actual: order.count)
            }
            var seen = [Bool](repeating: false, count: cellCount)
            for i in order {
                guard i >= 0, i < cellCount, !seen[i] else {
                    throw MosaicError.invalidConfiguration("custom order must be a permutation of 0..<\(cellCount)")
                }
                seen[i] = true
            }
            return order
        }
    }

    /// 全库搜索：按候选分块并行计算距离并就地选优（上限、惩罚、主邻域），不分配候选列表。
    /// 各块的局部最优按 (得分, 距离, 下标) 归并，结果与线程数无关、与"对全部候选调用 `pick`"一致。
    private func exhaustivePick(cell: Int, cellFeatures: FeatureMatrix, library: FeatureMatrix, maskWords: [UInt64]?,
                                forbidden: [Int], cap: Int?, uses: [Int32], lambda: Float,
                                scratch: inout [Float]) -> Neighbor? {
        let n = library.count
        let dims = library.dimension
        if scratch.count != n { scratch = [Float](repeating: 0, count: n) }
        let query = (0..<dims).map { cellFeatures.value(dimension: $0, index: cell) }
        let capValue = cap.map { Int32(clamping: $0) } ?? Int32.max
        let chunk = 8192
        let chunkCount = (n + chunk - 1) / chunk
        var bestIdx = [Int](repeating: -1, count: chunkCount)
        var bestScore = [Float](repeating: .infinity, count: chunkCount)
        var bestDist = [Float](repeating: .infinity, count: chunkCount)

        scratch.withUnsafeMutableBufferPointer { dist in
            library.storage.withUnsafeBufferPointer { lib in
                uses.withUnsafeBufferPointer { u in
                    bestIdx.withUnsafeMutableBufferPointer { bi in
                        bestScore.withUnsafeMutableBufferPointer { bs in
                            bestDist.withUnsafeMutableBufferPointer { bd in
                                let p = ScanPointers(dist: dist.baseAddress!, lib: lib.baseAddress!, uses: u.baseAddress!,
                                                     bestIdx: bi.baseAddress!, bestScore: bs.baseAddress!, bestDist: bd.baseAddress!)
                                let work: @Sendable (Int) -> Void = { c in
                                    let lo = c * chunk
                                    let hi = min(n, lo + chunk)
                                    let q0 = query[0]
                                    for i in lo..<hi {
                                        let t = p.lib[i] - q0
                                        p.dist[i] = t * t
                                    }
                                    var d = 1
                                    while d < dims {
                                        let q = query[d]
                                        let base = d * n
                                        for i in lo..<hi {
                                            let t = p.lib[base + i] - q
                                            p.dist[i] += t * t
                                        }
                                        d += 1
                                    }
                                    var bIdx = -1
                                    var bScore = Float.infinity
                                    var bDist = Float.infinity
                                    for i in lo..<hi {
                                        if let w = maskWords, (w[i >> 6] >> UInt64(i & 63)) & 1 == 0 { continue }
                                        let ui = p.uses[i]
                                        if ui >= capValue { continue }
                                        let dd = p.dist[i]
                                        let score = dd + lambda * Float(ui)
                                        // 下标升序遍历：只在严格更优时替换，等价于 (得分, 距离, 下标) 平局规则。
                                        if score < bScore || (score == bScore && dd < bDist) {
                                            if forbidden.contains(i) { continue }
                                            bIdx = i
                                            bScore = score
                                            bDist = dd
                                        }
                                    }
                                    p.bestIdx[c] = bIdx
                                    p.bestScore[c] = bScore
                                    p.bestDist[c] = bDist
                                }
                                if chunkCount > 1 {
                                    DispatchQueue.concurrentPerform(iterations: chunkCount, execute: work)
                                } else {
                                    work(0)
                                }
                            }
                        }
                    }
                }
            }
        }
        var result: Neighbor?
        var rScore = Float.infinity
        for c in 0..<chunkCount where bestIdx[c] >= 0 {  // 块按下标升序，归并规则同上
            if result == nil || bestScore[c] < rScore || (bestScore[c] == rScore && bestDist[c] < result!.distance) {
                result = Neighbor(index: bestIdx[c], distance: bestDist[c])
                rScore = bestScore[c]
            }
        }
        return result
    }

    /// 由最近一次全库距离缓冲构造全部可用候选列表（仅在全库搜索也失败时使用）。
    private func allCandidates(scratch: [Float], maskWords: [UInt64]?) -> [Neighbor] {
        var out: [Neighbor] = []
        for i in scratch.indices {
            if let w = maskWords, (w[i >> 6] >> UInt64(i & 63)) & 1 == 0 { continue }
            out.append(Neighbor(index: i, distance: scratch[i]))
        }
        return out
    }

    private func collectAssigned(_ cell: Int, grid: MosaicGrid, neighborhood: Neighborhood, assigned: [Int], into out: inout [Int]) {
        out.removeAll(keepingCapacity: true)
        for nb in grid.neighbors(of: cell, in: neighborhood) {
            let t = assigned[nb]
            if t >= 0 { out.append(t) }
        }
    }

    /// 在候选列表中选出得分最低且未被禁用的素材；全部被禁时返回 nil。
    private func pick(_ list: [Neighbor], forbidden: [Int], cap: Int?, uses: [Int32], lambda: Float) -> Neighbor? {
        var best: Neighbor?
        var bestScore = Float.infinity
        for cand in list {
            if forbidden.contains(cand.index) { continue }
            let u = uses[cand.index]
            if let cap, Int(u) >= cap { continue }
            let score = cand.distance + lambda * Float(u)
            if let b = best {
                if score < bestScore || (score == bestScore && (cand.distance < b.distance
                    || (cand.distance == b.distance && cand.index < b.index))) {
                    best = cand
                    bestScore = score
                }
            } else {
                best = cand
                bestScore = score
            }
        }
        return best
    }
}
