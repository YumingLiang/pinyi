/// 一次生成的完整结果：网格划分 + 分配 + 素材供给判断。
public struct MosaicGeneration: Hashable, Sendable {
    /// 网格划分（含裁切矩形，渲染/导出用）。
    public let layout: GridLayout
    /// 分配结果（含种子与统计）。
    public let assignment: MosaicAssignment
    /// 生成时的素材供给档位（< 200 张时 UI 应已在生成前提示过）。
    public let supply: MaterialSupply
    /// 生成所用密度。
    public let density: Density

    /// 生成所用种子。
    public var seed: UInt64 { assignment.seed }
    /// 结果页是否显示 `shortage.result`（见 `AssignmentStatistics.shouldShowShortageNotice`）。
    public var shouldShowShortageNotice: Bool { assignment.statistics.shouldShowShortageNotice }
}

/// 端到端便捷入口：目标图像素 → 网格划分（§3.6）→ 每格特征 → 约束分配。
///
/// iOS 侧只需把 PhotosPicker/ImageIO 解码结果转成 `PixelBuffer`、把素材特征装进 `FeatureMatrix`，
/// 即可调用本类型；渲染（预览 / 导出）在 Renderer 包中按 `MosaicGeneration` 绘制。
public struct MosaicPipeline: Sendable {
    /// 目标图取样器（颜色空间须与素材特征一致）。
    public var sampler: TargetSampler
    /// 约束分配器（其配置中的种子即本次种子）。
    public var assigner: GreedyAssigner

    /// 创建流水线。
    public init(sampler: TargetSampler = TargetSampler(), assigner: GreedyAssigner = GreedyAssigner()) {
        self.sampler = sampler
        self.assigner = assigner
    }

    /// 生成马赛克。
    /// - Parameters:
    ///   - target: 目标图（建议先用 ImageIO 降采样，例如长边 ≤ 2048）。
    ///   - density: 密度档位。
    ///   - library: 素材特征（渐进可用时为生成那一刻的快照）。
    ///   - mask: 可用素材掩码（来源 ∧ 已扫描）；多相簿可先用 `BitMask.union` 合并。
    ///   - seed: 覆盖配置中的种子；`nil` 用配置值。
    /// - Throws: 无可用素材时抛 `MosaicError.noCandidates`（UI 应先按 `MaterialSupply.empty` 走空状态）。
    public func generate(target: PixelBuffer, density: Density, library: FeatureMatrix,
                         mask: BitMask? = nil, seed: UInt64? = nil) throws -> MosaicGeneration {
        try generate(target: target, density: density, library: library, mask: mask, seed: seed,
                     lightnessVariance: nil, cancellation: nil, progress: nil)
    }

    /// 生成马赛克（完整版：亮度方差打分 + 可取消 + 进度）。
    ///
    /// - Parameters:
    ///   - lightnessVariance: 每张素材亮度方差；`nil` = 不启用纯色惩罚。
    ///   - cancellation: 取消令牌；同步调用时也会检查当前 Task 的取消状态。
    ///   - progress: 进度回调（取样 → 匹配 → 分配）。
    /// - Throws: 取消时抛 `CancellationError`，不产生任何半成品；同种子重跑结果与未被取消时完全一致。
    public func generate(target: PixelBuffer, density: Density, library: FeatureMatrix, mask: BitMask?,
                         seed: UInt64?, lightnessVariance: [Float]?, cancellation: CancellationToken?,
                         progress: MosaicProgressHandler?) throws -> MosaicGeneration {
        let check = CancellationCheck(token: cancellation)
        try check.check()
        let layout = try Layout.grid(width: target.width, height: target.height, density: density)
        progress?(MosaicProgress(phase: .sampling, completed: 0, total: 1))
        let cells = try sampler.cellFeatures(of: target, layout: layout)
        progress?(MosaicProgress(phase: .sampling, completed: 1, total: 1))
        try check.check()
        var assigner = self.assigner
        if let seed { assigner.configuration = assigner.configuration.withSeed(seed) }
        let assignment = try assigner.assign(grid: layout.grid, cellFeatures: FeatureMatrix(records: cells),
                                             library: library, mask: mask, lightnessVariance: lightnessVariance,
                                             cancellation: cancellation, progress: progress)
        return MosaicGeneration(layout: layout, assignment: assignment,
                                supply: MaterialSupply.evaluate(library: library, mask: mask), density: density)
    }

    /// 以 `FeatureTable`（`features.bin` 读出的形态）为素材：自动带亮度方差并排除 tombstone 行。
    /// - Throws: 另外在素材口径与取样器口径不一致时抛 `MosaicError.featureSpecMismatch`（评审 S4）。
    public func generate(target: PixelBuffer, density: Density, table: FeatureTable, mask: BitMask? = nil,
                         seed: UInt64? = nil, cancellation: CancellationToken? = nil,
                         progress: MosaicProgressHandler? = nil) throws -> MosaicGeneration {
        try generate(target: target, density: density, snapshot: LibrarySnapshot(table: table, sourceMask: mask),
                     seed: seed, cancellation: cancellation, progress: progress)
    }

    /// 以快照为素材（推荐的 App 入口，评审 S6）：只会选中快照内（来源 ∧ 已扫描 ∧ 未删除）的行。
    public func generate(target: PixelBuffer, density: Density, snapshot: LibrarySnapshot, seed: UInt64? = nil,
                         cancellation: CancellationToken? = nil,
                         progress: MosaicProgressHandler? = nil) throws -> MosaicGeneration {
        let targetSpec = sampler.extractor.spec
        guard snapshot.table.spec == targetSpec else {
            throw MosaicError.featureSpecMismatch(library: snapshot.table.spec, target: targetSpec)
        }
        return try generate(target: target, density: density, library: snapshot.table.matrix, mask: snapshot.mask, seed: seed,
                            lightnessVariance: snapshot.table.lightnessVariance, cancellation: cancellation, progress: progress)
    }

    /// Swift 并发入口：Task 被取消时（例如 App 进后台、后台任务到期）立刻通知内核各工作线程停止，
    /// 抛 `CancellationError`。重活在当前执行器上同步进行，App 侧应在 `Task.detached(priority: .userInitiated)`
    /// 或自建 actor 中调用，避免占住主线程。
    public func generate(target: PixelBuffer, density: Density, table: FeatureTable, mask: BitMask? = nil,
                         seed: UInt64? = nil, progress: MosaicProgressHandler? = nil) async throws -> MosaicGeneration {
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try generate(target: target, density: density, table: table, mask: mask, seed: seed,
                         cancellation: token, progress: progress)
        } onCancel: {
            token.cancel()
        }
    }

    /// `FeatureMatrix` 版本的 Swift 并发入口（不启用纯色惩罚，除非传入 `lightnessVariance`）。
    public func generate(target: PixelBuffer, density: Density, library: FeatureMatrix, mask: BitMask? = nil,
                         seed: UInt64? = nil, lightnessVariance: [Float]? = nil,
                         progress: MosaicProgressHandler? = nil) async throws -> MosaicGeneration {
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try generate(target: target, density: density, library: library, mask: mask, seed: seed,
                         lightnessVariance: lightnessVariance, cancellation: token, progress: progress)
        } onCancel: {
            token.cancel()
        }
    }

    /// 「换一种拼法」：同一目标图、同一素材快照、同一参数，只把种子换成 `MosaicSeed.next(after:)`
    /// （或指定的 `newSeed`）。
    public func reshuffle(_ previous: MosaicGeneration, target: PixelBuffer, library: FeatureMatrix,
                          mask: BitMask? = nil, newSeed: UInt64? = nil) throws -> MosaicGeneration {
        try generate(target: target, density: previous.density, library: library, mask: mask,
                     seed: newSeed ?? MosaicSeed.next(after: previous.seed))
    }

    /// 「换一种拼法」（`FeatureTable` 版，可取消）。
    public func reshuffle(_ previous: MosaicGeneration, target: PixelBuffer, table: FeatureTable,
                          mask: BitMask? = nil, newSeed: UInt64? = nil,
                          cancellation: CancellationToken? = nil) throws -> MosaicGeneration {
        try generate(target: target, density: previous.density, table: table, mask: mask,
                     seed: newSeed ?? MosaicSeed.next(after: previous.seed), cancellation: cancellation)
    }
}
