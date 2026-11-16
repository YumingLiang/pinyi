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
    let penalty: UnsafePointer<Float>?
}

/// 单张素材的使用上限（技术方案 §3.4 第 3 步）。
public enum UsageCap: Hashable, Sendable {
    /// 自动：`cap = max(1, ceil(格子数 / 可用素材数 × multiplier))`，方案默认 multiplier = 2。
    case automatic(multiplier: Double)
    /// 固定上限（≥ 1）。产品决定第 10 条：MVP 不开放给用户，仅供测试/内部调参。
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
    /// 回退第 1 步：逐格扩展后的候选数（方案默认 128）。
    public var fallbackK: Int
    /// 回退第 2 步「分批加深」（评审 M1）：逐格扩到 `fallbackK` 仍失败的格子先延后，主轮结束后按这些深度**批量**重算 top‑k。
    /// 默认 [512, 2048]；大于可用素材数的深度会被钳到可用数，不大于前一级的深度被跳过。
    public var batchDepths: [Int]
    /// 逐格扩到 `fallbackK` 的格子数上限（默认 256）：超过后剩余失败格直接进入分批加深（第一级 512 ≥ 128，质量不降）。
    /// 逐格扩展每次都要扫全库，整张同色图会有上万格走到这里，批量做才省时间（评审 M1"成本在扫库"）。
    public var perCellExpansionLimit: Int
    /// 分批加深时每组查询数上限（默认 1,024；top‑2048 时候选表约 16.8 MB）。
    public var batchQueryGroupSize: Int
    /// 回退第 3 步：分批加深后仍失败的格子 **≤ 此数** 时才逐格扫全库（默认 256，0 = 关闭）。
    public var exhaustiveCellLimit: Int
    /// 使用次数惩罚的**相对**系数 α（评审 M3）：`λ_eff = α × 本次生成所有格子 top‑1 距离的中位数`。默认 0.1。
    /// 设为 `nil` 时改用绝对值 `usagePenalty`（仅供测试）。
    public var usagePenaltyRelative: Float?
    /// 使用次数惩罚的绝对值 λ（只在 `usagePenaltyRelative == nil` 时生效）。
    public var usagePenalty: Float
    /// 单张素材使用上限。
    public var cap: UsageCap
    /// 主邻域：在其中已出现的素材不可再用（默认 8 邻域）。
    public var neighborhood: Neighborhood
    /// 回退时放宽后的邻域（默认 4 邻域）。
    public var relaxedNeighborhood: Neighborhood
    /// 随机种子；用户点「换一种拼法」即换种子。
    public var seed: UInt64
    /// 遍历顺序。
    public var order: CellOrder
    /// 低细节（纯色）惩罚的**相对**系数 β（技术方案 §2.1：亮度方差"用于惩罚纯色图过度使用"）。
    ///
    /// `score = dist + λ_eff · uses(i) + μ_eff · flatness(i)`，`flatness = max(0, 1 − σ²_L(i) / lowDetailVarianceReference)`，
    /// `μ_eff = β × top‑1 距离中位数`（与 λ 同一尺度，M3）。默认 β = 0.04 = 0.4 α：纯色惩罚弱于"多用一次"的惩罚；
    /// 在 5 万张合成库上（中位数约 0.074）μ_eff ≈ 0.003，约合每维 0.016 的 OKLab 差，低于常用可察觉差 ~0.02，
    /// 只有当有纹理的素材"几乎一样接近"时才压过纯色图。`nil` 时改用绝对值 `lowDetailPenalty`；0 = 关闭。待 A/B 调参。
    public var lowDetailPenaltyRelative: Float?
    /// 纯色惩罚绝对值 μ（只在 `lowDetailPenaltyRelative == nil` 时生效，仅供测试）。
    public var lowDetailPenalty: Float
    /// 方差参考值 σ²_ref（L 归一到 0…1）：方差 ≥ 它的素材不受惩罚。默认 0.0004（σ_L = 0.02），
    /// 与 `FeatureExtractor.lowDetailVarianceThreshold` / `FeatureFlags.lowDetail` 阈值一致。方差不随距离尺度变化。
    public var lowDetailVarianceReference: Float
    /// 分配循环每处理多少个格子检查一次取消（另外每次扩 k / 批量加深 / 全库搜索前也检查）。默认 64。
    public var cancellationCheckInterval: Int

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
        batchDepths: [Int] = [512, 2048],
        batchQueryGroupSize: Int = 1024,
        perCellExpansionLimit: Int = 256,
        exhaustiveCellLimit: Int = 256,
        usagePenaltyRelative: Float? = 0.1,
        lowDetailPenaltyRelative: Float? = 0.04,
        lowDetailPenalty: Float = 0.002,
        lowDetailVarianceReference: Float = 0.0004,
        cancellationCheckInterval: Int = 64
    ) {
        self.k = k
        self.fallbackK = fallbackK
        self.usagePenalty = usagePenalty
        self.cap = cap
        self.neighborhood = neighborhood
        self.relaxedNeighborhood = relaxedNeighborhood
        self.seed = seed
        self.order = order
        self.batchDepths = batchDepths
        self.batchQueryGroupSize = batchQueryGroupSize
        self.perCellExpansionLimit = perCellExpansionLimit
        self.exhaustiveCellLimit = exhaustiveCellLimit
        self.usagePenaltyRelative = usagePenaltyRelative
        self.lowDetailPenaltyRelative = lowDetailPenaltyRelative
        self.lowDetailPenalty = lowDetailPenalty
        self.lowDetailVarianceReference = lowDetailVarianceReference
        self.cancellationCheckInterval = cancellationCheckInterval
    }

    /// 便捷：使用绝对 λ / μ（关闭相对尺度），用于需要精确阈值的测试。
    public func withAbsolutePenalties(usage: Float, lowDetail: Float) -> AssignmentConfiguration {
        var c = self
        c.usagePenaltyRelative = nil
        c.lowDetailPenaltyRelative = nil
        c.usagePenalty = usage
        c.lowDetailPenalty = lowDetail
        return c
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
        guard batchDepths.allSatisfy({ $0 >= 1 }) else { throw MosaicError.invalidConfiguration("batchDepths must be >= 1") }
        guard batchQueryGroupSize >= 1 else { throw MosaicError.invalidConfiguration("batchQueryGroupSize must be >= 1") }
        guard perCellExpansionLimit >= 0 else { throw MosaicError.invalidConfiguration("perCellExpansionLimit must be >= 0") }
        guard exhaustiveCellLimit >= 0 else { throw MosaicError.invalidConfiguration("exhaustiveCellLimit must be >= 0") }
        for r in [usagePenaltyRelative, lowDetailPenaltyRelative] {
            if let r, !(r >= 0 && r.isFinite) { throw MosaicError.invalidConfiguration("relative penalties must be finite and >= 0") }
        }
        guard usagePenalty >= 0, usagePenalty.isFinite else {
            throw MosaicError.invalidConfiguration("usagePenalty must be finite and >= 0")
        }
        guard lowDetailPenalty >= 0, lowDetailPenalty.isFinite else {
            throw MosaicError.invalidConfiguration("lowDetailPenalty must be finite and >= 0")
        }
        guard lowDetailVarianceReference > 0, lowDetailVarianceReference.isFinite else {
            throw MosaicError.invalidConfiguration("lowDetailVarianceReference must be > 0")
        }
        guard cancellationCheckInterval >= 1 else {
            throw MosaicError.invalidConfiguration("cancellationCheckInterval must be >= 1")
        }
        if case .automatic(let m) = cap, !(m > 0 && m.isFinite) {
            throw MosaicError.invalidConfiguration("automatic cap multiplier must be > 0")
        }
        if case .limited(let n) = cap, n < 1 {
            throw MosaicError.invalidConfiguration("limited cap must be >= 1")
        }
    }
}

/// 每个格子最终在哪一级回退上找到素材（技术方案 §3.4 第 4 步 + 评审 M1 的分批加深）。
public enum FallbackLevel: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// 首轮 top‑k，主邻域 + 上限都满足。
    case primary = 0
    /// top‑k 全被禁，逐格扩到 `fallbackK` 后满足主邻域 + 上限。
    case expandedCandidates = 1
    /// 延后到主轮结束，批量加深（默认 top‑512 → top‑2048）后满足主邻域 + 上限（不算放宽）。
    case batchDeepened = 2
    /// 加深后仍失败且剩余格子 ≤ `exhaustiveCellLimit`，逐格全库搜索找到满足主邻域 + 上限者（不算放宽）。
    case exhaustiveSearch = 3
    /// 放宽为 `relaxedNeighborhood`（默认 4 邻域），仍满足上限。
    case relaxedNeighborhood = 4
    /// 忽略上限（仍满足放宽后的邻域）。
    case capIgnored = 5
    /// 最后兜底：忽略邻域与上限，取得分最低者（素材极少，例如只有 1–2 张）。
    case neighborhoodIgnored = 6

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
    /// 本次所有格子 top‑1 距离的中位数（M3 的尺度）。
    public var top1MedianDistance: Float
    /// 实际生效的使用次数惩罚 λ_eff。
    public var effectiveUsagePenalty: Float
    /// 实际生效的纯色惩罚 μ_eff（未提供亮度方差时为 0）。
    public var effectiveLowDetailPenalty: Float

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
    /// 是否实际放宽过约束（技术方案 v0.2 §3.4 `relaxedConstraints`）。结果页是否提示由 App 判断，
    /// 见 `ShortageHint.shouldShowResultHint`（决定 v0.3：可用 < 200 且实际放宽才显示 `shortage.result`）。
    public var relaxedConstraints: Bool { relaxationCount > 0 }
    /// 放宽了邻域的格子数（主邻域不再保证）：`.relaxedNeighborhood` + `.capIgnored` + `.neighborhoodIgnored`。
    public var neighborhoodRelaxedCount: Int {
        count(at: .relaxedNeighborhood) + count(at: .capIgnored) + count(at: .neighborhoodIgnored)
    }
    /// 忽略了单张上限的格子数：`.capIgnored` + `.neighborhoodIgnored`。
    public var capIgnoredCount: Int { count(at: .capIgnored) + count(at: .neighborhoodIgnored) }
    /// 可用素材是否低于素材不足阈值（200 张，`MaterialSupply.insufficientThreshold`）。
    public var isBelowMaterialThreshold: Bool { MaterialSupply.evaluate(availableCount: availableCandidates) != .sufficient }
    /// 结果页是否显示 `shortage.result`「有些照片重复用了几次」（产品决定 v0.3 01:10 / QA 缺陷 9）：
    /// **仅当**可用照片 < 200 张（`isBelowMaterialThreshold`）**且**匹配器实际放宽了约束（`relaxedConstraints`）。
    /// 素材充足但因颜色集中而放宽时不显示。App 只看这一个属性。
    public var shouldShowShortageNotice: Bool { ShortageHint.shouldShow(isBelowMaterialThreshold: isBelowMaterialThreshold,
                                                                        relaxedConstraints: relaxedConstraints) }
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

/// 带惩罚的随机顺序贪心分配器（技术方案 §3.4，回退链按架构师评审 M1 改为「分批加深」）。
///
/// 流程：
/// 1. 用 `kernel` 为每个格子算 top‑k（k = 32）；求所有格子 top‑1 距离中位数 `med`，
///    `λ_eff = α · med`、`μ_eff = β · med`（M3，相对尺度）。
/// 2. 按种子化随机顺序逐格处理，打分 `score = dist + λ_eff · uses(i) + μ_eff · flatness(i)`；
///    若 i 已出现在主邻域中（只看已分配的邻居）或 `uses(i) ≥ cap` 则禁用。取最低分，平局按 (距离, 下标)。
/// 3. 回退链（逐级，记录在 `levels`）：
///    ① 逐格扩到 top‑128 → ② 仍失败的格子**延后**，主轮结束后按原顺序**批量** top‑512、再批量 top‑2048
///    → ③ 剩余 ≤ 256 格时逐格全库搜索 → ④ 放宽为 4 邻域 → ⑤ 忽略上限 → ⑥ 忽略邻域。
///    只有 ④⑤⑥ 算"放宽约束"（`relaxedConstraints`），并分别计入 `neighborhoodRelaxedCount` / `capIgnoredCount`。
///
/// 每格只与"已分配"的邻居比较，且邻域关系对称，所以只要所有格子都在 ①–③ 级完成，
/// 最终结果中任意两个主邻域内的格子都不相同。结果只由（输入、配置、种子）决定，与线程数、分组大小无关。
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
        try assign(grid: grid, cellFeatures: cellFeatures, library: library, mask: mask,
                   lightnessVariance: nil, cancellation: nil, progress: nil)
    }

    /// 以 `FeatureTable` 为素材的便捷入口：自动带上亮度方差，并排除 tombstone 行。
    public func assign(grid: MosaicGrid, cellFeatures: FeatureMatrix, table: FeatureTable, mask: BitMask? = nil,
                       cancellation: CancellationToken? = nil, progress: MosaicProgressHandler? = nil) throws -> MosaicAssignment {
        if let mask, mask.count != table.count {
            throw MosaicError.countMismatch(expected: table.count, actual: mask.count)
        }
        let live = table.liveMask
        let m = mask.map { $0.intersection(live) } ?? live
        return try assign(grid: grid, cellFeatures: cellFeatures, library: table.matrix, mask: m,
                          lightnessVariance: table.lightnessVariance, cancellation: cancellation, progress: progress)
    }

    /// 执行分配（完整版：亮度方差打分 + 可取消 + 进度）。
    ///
    /// - Parameters:
    ///   - lightnessVariance: 每张素材的亮度方差（长度 = `library.count`）；`nil` 表示不启用纯色惩罚。
    ///   - cancellation: 取消令牌；同时检查调用线程所在 Task 的取消状态。
    ///   - progress: 进度回调（`.matching` 与 `.assigning` 两个阶段）。
    /// - Throws: 除上述错误外，取消时抛 `CancellationError`（不返回部分结果）。
    ///   取消与否不改变随机序列：未取消的运行结果只由（输入、配置、种子）决定。
    public func assign(grid: MosaicGrid, cellFeatures: FeatureMatrix, library: FeatureMatrix, mask: BitMask?,
                       lightnessVariance: [Float]?, cancellation: CancellationToken?,
                       progress: MosaicProgressHandler?) throws -> MosaicAssignment {
        let config = configuration
        let check = CancellationCheck(token: cancellation)
        try check.check()
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
        if let lightnessVariance, lightnessVariance.count != library.count {
            throw MosaicError.countMismatch(expected: library.count, actual: lightnessVariance.count)
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
                    distinctTilesUsed: 0, maxUses: 0, totalDistance: 0,
                    top1MedianDistance: 0, effectiveUsagePenalty: 0, effectiveLowDetailPenalty: 0),
                seed: config.seed)
        }
        guard available > 0 else { throw MosaicError.noCandidates }

        let cap = config.cap.resolve(cellCount: cellCount, availableCount: available)
        let order = try makeOrder(cellCount: cellCount, config: config)
        let topK = try kernel.topK(queries: cellFeatures, candidates: library, k: config.k, mask: mask,
                                   cancellation: cancellation,
                                   progress: progress.map { p in { @Sendable done, total in
                                       p(MosaicProgress(phase: .matching, completed: done, total: total)) } })
        try check.check()

        // M3：惩罚系数相对于本次 top‑1 距离中位数（确定、可复现；整体缩放特征时结果不变）。
        let median = GreedyAssigner.top1Median(topK)
        let lambda = config.usagePenaltyRelative.map { $0 * median } ?? config.usagePenalty
        let mu: Float = lightnessVariance == nil ? 0 : (config.lowDetailPenaltyRelative.map { $0 * median } ?? config.lowDetailPenalty)
        // 每张素材的静态（与使用次数无关）惩罚：μ · flatness(i)。
        let staticPenalty: [Float]? = lightnessVariance.flatMap { v -> [Float]? in
            guard mu > 0 else { return nil }
            let ref = config.lowDetailVarianceReference
            return v.map { mu * max(0, 1 - max(0, $0) / ref) }
        }
        let interval = config.cancellationCheckInterval

        let expandedK = min(config.fallbackK, available)
        let canExpand = expandedK > topK.k
        var depths: [Int] = []
        var prev = max(topK.k, canExpand ? expandedK : 0)
        for d in config.batchDepths {
            let e = min(d, available)
            if e > prev { depths.append(e); prev = e }
        }

        var uses = [Int32](repeating: 0, count: library.count)
        var assigned = [Int](repeating: -1, count: cellCount)
        var distances = [Float](repeating: 0, count: cellCount)
        var levels = [FallbackLevel](repeating: .primary, count: cellCount)
        var assignedCount = 0
        let maskWords = mask?.words
        var scratch: [Float] = []   // 全库搜索时复用的距离缓冲（按需分配）
        var primaryTiles: [Int] = []
        var relaxedTiles: [Int] = []

        func commit(_ cell: Int, _ n: Neighbor, _ level: FallbackLevel) {
            assigned[cell] = n.index
            distances[cell] = n.distance
            levels[cell] = level
            uses[n.index] += 1
            assignedCount += 1
        }
        /// 主邻域 + 上限下尝试；成功即落子。
        func tryStrict(_ cell: Int, _ list: [Neighbor], _ level: FallbackLevel) -> Bool {
            collectAssigned(cell, grid: grid, neighborhood: config.neighborhood, assigned: assigned, into: &primaryTiles)
            guard let n = pick(list, forbidden: primaryTiles, cap: cap, uses: uses, lambda: lambda, penalty: staticPenalty) else {
                return false
            }
            commit(cell, n, level)
            return true
        }
        /// 放宽链：4 邻域 + 上限 → 忽略上限 → 忽略邻域。list 非空（available > 0 且 k ≥ 1），最后一级必然成功。
        func relax(_ cell: Int, _ list: [Neighbor]) throws {
            collectAssigned(cell, grid: grid, neighborhood: config.relaxedNeighborhood, assigned: assigned, into: &relaxedTiles)
            if let n = pick(list, forbidden: relaxedTiles, cap: cap, uses: uses, lambda: lambda, penalty: staticPenalty) {
                commit(cell, n, .relaxedNeighborhood)
            } else if let n = pickMinimalOverflow(list, forbidden: relaxedTiles, uses: uses, lambda: lambda, penalty: staticPenalty) {
                commit(cell, n, .capIgnored)
            } else if let n = pick(list, forbidden: [], cap: nil, uses: uses, lambda: lambda, penalty: staticPenalty) {
                commit(cell, n, .neighborhoodIgnored)
            } else {
                throw MosaicError.noCandidates
            }
        }

        // 最后一级加深仍失败的格子：剩余 ≤ exhaustiveCellLimit 时暂存，最后逐格全库搜索；
        // 一旦超过上限，全库搜索整体关闭，已暂存的按原顺序放宽，之后的失败格就地放宽。
        var stash: [(cell: Int, list: [Neighbor])] = []
        var exhaustiveOpen = config.exhaustiveCellLimit > 0
        func finalFailure(_ cell: Int, _ list: [Neighbor]) throws {
            if exhaustiveOpen, list.count < available {
                if stash.count < config.exhaustiveCellLimit {
                    stash.append((cell, list))
                    return
                }
                exhaustiveOpen = false
                for item in stash { try relax(item.cell, item.list) }
                stash.removeAll()
            }
            try relax(cell, list)
        }

        // 第 1 轮：随机顺序，top‑k → 逐格扩到 fallbackK；仍失败者延后。
        progress?(MosaicProgress(phase: .assigning, completed: 0, total: cellCount))
        var deferred: [Int] = []
        var perCellExpansions = 0
        for (step, cell) in order.enumerated() {
            if step % interval == 0 {
                try check.check()
                if step > 0 { progress?(MosaicProgress(phase: .assigning, completed: assignedCount, total: cellCount)) }
            }
            var list = topK.neighbors(forQuery: cell)
            if tryStrict(cell, list, .primary) { continue }
            if canExpand, perCellExpansions < config.perCellExpansionLimit || depths.isEmpty {
                perCellExpansions += 1
                try check.check()
                list = try kernel.topK(queries: cellFeatures.subset(cell), candidates: library,
                                       k: expandedK, mask: mask).neighbors(forQuery: 0)
                if tryStrict(cell, list, .expandedCandidates) { continue }
            }
            if depths.isEmpty { try finalFailure(cell, list) } else { deferred.append(cell) }
        }

        // 第 2 轮：分批加深（延后队列按原随机顺序，分组批量算 top‑d）。
        for (di, depth) in depths.enumerated() where !deferred.isEmpty {
            let isLast = di == depths.count - 1
            let queue = deferred
            deferred = []
            var g0 = 0
            while g0 < queue.count {
                try check.check()
                let group = Array(queue[g0..<min(queue.count, g0 + config.batchQueryGroupSize)])
                let res = try kernel.topK(queries: cellFeatures.gather(group), candidates: library, k: depth, mask: mask,
                                          cancellation: cancellation, progress: nil)
                for (qi, cell) in group.enumerated() {
                    if qi % interval == 0 { try check.check() }
                    let list = res.neighbors(forQuery: qi)
                    if tryStrict(cell, list, .batchDeepened) { continue }
                    if isLast { try finalFailure(cell, list) } else { deferred.append(cell) }
                }
                progress?(MosaicProgress(phase: .assigning, completed: assignedCount, total: cellCount))
                g0 += group.count
            }
        }

        // 第 3 轮：少量剩余格逐格全库搜索；失败者在全部可用素材上走放宽链。
        for item in stash {
            try check.check()
            collectAssigned(item.cell, grid: grid, neighborhood: config.neighborhood, assigned: assigned, into: &primaryTiles)
            if let n = exhaustivePick(cell: item.cell, cellFeatures: cellFeatures, library: library, maskWords: maskWords,
                                      forbidden: primaryTiles, cap: cap, uses: uses, lambda: lambda,
                                      penalty: staticPenalty, scratch: &scratch) {
                commit(item.cell, n, .exhaustiveSearch)
            } else {
                try relax(item.cell, allCandidates(scratch: scratch, maskWords: maskWords))
            }
        }

        try check.check()
        progress?(MosaicProgress(phase: .assigning, completed: cellCount, total: cellCount))
        var levelCounts = [Int](repeating: 0, count: FallbackLevel.allCases.count)
        for l in levels { levelCounts[l.rawValue] += 1 }
        let stats = AssignmentStatistics(
            cellCount: cellCount,
            availableCandidates: available,
            resolvedCap: cap,
            levelCounts: levelCounts,
            distinctTilesUsed: uses.reduce(0) { $0 + ($1 > 0 ? 1 : 0) },
            maxUses: Int(uses.max() ?? 0),
            totalDistance: distances.reduce(0) { $0 + Double($1) },
            top1MedianDistance: median,
            effectiveUsagePenalty: lambda,
            effectiveLowDetailPenalty: staticPenalty == nil ? 0 : mu
        )
        return MosaicAssignment(grid: grid, tiles: assigned, distances: distances, levels: levels,
                                statistics: stats, seed: config.seed)
    }

    /// 所有格子 top‑1 距离的中位数（下中位数，确定）。
    static func top1Median(_ r: TopKResult) -> Float {
        guard r.k > 0, r.queryCount > 0 else { return 0 }
        var xs = (0..<r.queryCount).map { r.distances[$0 * r.k] }
        xs.sort()
        return xs[(xs.count - 1) / 2]
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
                                forbidden: [Int], cap: Int?, uses: [Int32], lambda: Float, penalty: [Float]?,
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

        let penaltyStorage = penalty ?? []
        penaltyStorage.withUnsafeBufferPointer { penBuf in
        scratch.withUnsafeMutableBufferPointer { dist in
            library.storage.withUnsafeBufferPointer { lib in
                uses.withUnsafeBufferPointer { u in
                    bestIdx.withUnsafeMutableBufferPointer { bi in
                        bestScore.withUnsafeMutableBufferPointer { bs in
                            bestDist.withUnsafeMutableBufferPointer { bd in
                                let p = ScanPointers(dist: dist.baseAddress!, lib: lib.baseAddress!, uses: u.baseAddress!,
                                                     bestIdx: bi.baseAddress!, bestScore: bs.baseAddress!, bestDist: bd.baseAddress!,
                                                     penalty: penalty == nil ? nil : penBuf.baseAddress)
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
                                        var score = dd + lambda * Float(ui)
                                        if let pp = p.penalty { score += pp[i] }
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

    /// 忽略上限时按"最小超额"选：先找候选中（邻域允许的）最少的使用次数 u，再在 uses ≤ u 的候选里按得分选。
    /// 等价于把上限逐级抬高 1，使超额使用尽量均摊（整张同色图时单张最多约 ⌈格子数 / 候选数⌉ 次，而不是集中在少数几张）。
    private func pickMinimalOverflow(_ list: [Neighbor], forbidden: [Int], uses: [Int32], lambda: Float, penalty: [Float]?) -> Neighbor? {
        var minUse = Int32.max
        for c in list where uses[c.index] < minUse && !forbidden.contains(c.index) { minUse = uses[c.index] }
        guard minUse != .max else { return nil }
        return pick(list, forbidden: forbidden, cap: Int(minUse) + 1, uses: uses, lambda: lambda, penalty: penalty)
    }

    /// 在候选列表中选出得分最低且未被禁用的素材；全部被禁时返回 nil。
    private func pick(_ list: [Neighbor], forbidden: [Int], cap: Int?, uses: [Int32], lambda: Float,
                      penalty: [Float]?) -> Neighbor? {
        var best: Neighbor?
        var bestScore = Float.infinity
        for cand in list {
            if forbidden.contains(cand.index) { continue }
            let u = uses[cand.index]
            if let cap, Int(u) >= cap { continue }
            let score = cand.distance + lambda * Float(u) + (penalty?[cand.index] ?? 0)
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

/// 结果页素材不足提示的判定（纯函数，便于 App / QA 真值表测试）。
public enum ShortageHint {
    /// `isBelowMaterialThreshold && relaxedConstraints`。
    public static func shouldShow(isBelowMaterialThreshold: Bool, relaxedConstraints: Bool) -> Bool {
        isBelowMaterialThreshold && relaxedConstraints
    }

    /// 由可用张数与两项放宽计数判定（可用 < `MaterialSupply.insufficientThreshold` 且发生过任一放宽）。
    public static func shouldShow(availableCount: Int, neighborhoodRelaxedCount: Int, capIgnoredCount: Int) -> Bool {
        shouldShow(isBelowMaterialThreshold: availableCount < MaterialSupply.insufficientThreshold,
                   relaxedConstraints: neighborhoodRelaxedCount > 0 || capIgnoredCount > 0)
    }
}
