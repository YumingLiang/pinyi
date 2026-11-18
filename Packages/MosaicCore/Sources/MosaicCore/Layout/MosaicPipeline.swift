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
    /// 格子掩码（形状 / 文字拼图）；`nil` = 普通拼图（全部格子都有照片）。
    /// 非 `nil` 时掩码外 `assignment.tiles[i] == -1`，预览 / 导出把这些格子画成背景色（S3）。
    public var activeCells: CellMask? = nil

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

    /// 生成马赛克（`FeatureMatrix` 入口：**测试 / 内部用**，不做口径校验、不带方差；App 只走 `snapshot:` 入口，评审 S-4/S-5）。
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
    ///   - activeCells: 格子掩码（形状 / 文字拼图）；尺寸须等于按 `target` 与 `density` 算出的网格
    ///     （调用方先调 `Layout.grid` 再建掩码），否则抛 `MosaicError.countMismatch`。`nil` 时与原行为逐位一致。
    public func generate(target: PixelBuffer, density: Density, library: FeatureMatrix, mask: BitMask?,
                         seed: UInt64?, lightnessVariance: [Float]?, cancellation: CancellationToken?,
                         progress: MosaicProgressHandler?, activeCells: CellMask? = nil) throws -> MosaicGeneration {
        let check = CancellationCheck(token: cancellation)
        try check.check()
        let layout = try Layout.grid(width: target.width, height: target.height, density: density)
        if let activeCells, !activeCells.matches(layout.grid) {
            throw MosaicError.countMismatch(expected: layout.cellCount, actual: activeCells.cellCount)
        }
        progress?(MosaicProgress(phase: .sampling, completed: 0, total: 1))
        let cells = try sampler.cellFeatures(of: target, layout: layout)
        progress?(MosaicProgress(phase: .sampling, completed: 1, total: 1))
        try check.check()
        var assigner = self.assigner
        if let seed { assigner.configuration = assigner.configuration.withSeed(seed) }
        let assignment = try assigner.assign(grid: layout.grid, cellFeatures: FeatureMatrix(records: cells),
                                             library: library, mask: mask, lightnessVariance: lightnessVariance,
                                             cancellation: cancellation, progress: progress, activeCells: activeCells)
        return MosaicGeneration(layout: layout, assignment: assignment,
                                supply: MaterialSupply.evaluate(library: library, mask: mask), density: density,
                                activeCells: activeCells)
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
                         progress: MosaicProgressHandler? = nil, activeCells: CellMask? = nil) throws -> MosaicGeneration {
        let targetSpec = sampler.extractor.spec
        guard snapshot.table.spec == targetSpec else {
            throw MosaicError.featureSpecMismatch(library: snapshot.table.spec, target: targetSpec)
        }
        return try generate(target: target, density: density, library: snapshot.table.matrix, mask: snapshot.mask, seed: seed,
                            lightnessVariance: snapshot.table.lightnessVariance, cancellation: cancellation, progress: progress,
                            activeCells: activeCells)
    }

    /// Swift 并发入口（**推荐的 App 入口**，评审 ca6a4ca S-4）：快照 + 口径校验 + 方差 + 可取消。
    ///
    /// Task 被取消时（例如 App 进后台、后台任务到期）立刻通知内核各工作线程停止，抛 `CancellationError`。
    /// 执行位置（评审 S-3）：nonisolated async 函数在 Swift 6 下跑在**全局并发池**，同步重活会占住一个协作线程
    /// （内核另用 `concurrentPerform` 并行）。App 侧不要从 MainActor 直接 `await` 后就做别的 UI 等待；
    /// 建议在 `Task.detached(priority: .userInitiated)` 或专用 `DispatchQueue` 中调用。
    public func generate(target: PixelBuffer, density: Density, snapshot: LibrarySnapshot, seed: UInt64? = nil,
                         progress: MosaicProgressHandler? = nil,
                         activeCells: CellMask? = nil) async throws -> MosaicGeneration {
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try generate(target: target, density: density, snapshot: snapshot, seed: seed,
                         cancellation: token, progress: progress, activeCells: activeCells)
        } onCancel: {
            token.cancel()
        }
    }

    /// `FeatureTable` 版 Swift 并发入口（执行位置说明同 `snapshot:` 版）。
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

    /// `FeatureMatrix` 版本的 Swift 并发入口（测试 / 内部用；不启用纯色惩罚，除非传入 `lightnessVariance`）。
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
    /// `FeatureMatrix` 版（测试 / 内部用）：若首次生成传了 `lightnessVariance`，这里也须传同一份，否则打分口径不同（评审 S-4）。
    public func reshuffle(_ previous: MosaicGeneration, target: PixelBuffer, library: FeatureMatrix,
                          mask: BitMask? = nil, newSeed: UInt64? = nil,
                          lightnessVariance: [Float]? = nil) throws -> MosaicGeneration {
        try generate(target: target, density: previous.density, library: library, mask: mask,
                     seed: newSeed ?? MosaicSeed.next(after: previous.seed),
                     lightnessVariance: lightnessVariance, cancellation: nil, progress: nil,
                     activeCells: previous.activeCells)
    }

    /// 「换一种拼法」（快照版，推荐的 App 入口；可取消）。
    public func reshuffle(_ previous: MosaicGeneration, target: PixelBuffer, snapshot: LibrarySnapshot,
                          newSeed: UInt64? = nil, cancellation: CancellationToken? = nil,
                          progress: MosaicProgressHandler? = nil) throws -> MosaicGeneration {
        try generate(target: target, density: previous.density, snapshot: snapshot,
                     seed: newSeed ?? MosaicSeed.next(after: previous.seed), cancellation: cancellation, progress: progress,
                     activeCells: previous.activeCells)
    }

    /// 「换一种拼法」（快照版 Swift 并发入口）。
    public func reshuffle(_ previous: MosaicGeneration, target: PixelBuffer, snapshot: LibrarySnapshot,
                          newSeed: UInt64? = nil, progress: MosaicProgressHandler? = nil) async throws -> MosaicGeneration {
        try await generate(target: target, density: previous.density, snapshot: snapshot,
                           seed: newSeed ?? MosaicSeed.next(after: previous.seed), progress: progress,
                           activeCells: previous.activeCells)
    }

    /// 「换一种拼法」（`FeatureTable` 版，可取消）。
    public func reshuffle(_ previous: MosaicGeneration, target: PixelBuffer, table: FeatureTable,
                          mask: BitMask? = nil, newSeed: UInt64? = nil,
                          cancellation: CancellationToken? = nil) throws -> MosaicGeneration {
        try generate(target: target, density: previous.density, table: table, mask: mask,
                     seed: newSeed ?? MosaicSeed.next(after: previous.seed), cancellation: cancellation)
    }
}
