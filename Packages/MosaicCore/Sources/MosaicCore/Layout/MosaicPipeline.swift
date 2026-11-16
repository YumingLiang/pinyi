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
        let layout = try Layout.grid(width: target.width, height: target.height, density: density)
        let cells = try sampler.cellFeatures(of: target, layout: layout)
        var assigner = self.assigner
        if let seed { assigner.configuration = assigner.configuration.withSeed(seed) }
        let assignment = try assigner.assign(grid: layout.grid, cellFeatures: FeatureMatrix(records: cells),
                                             library: library, mask: mask)
        return MosaicGeneration(layout: layout, assignment: assignment,
                                supply: MaterialSupply.evaluate(library: library, mask: mask), density: density)
    }

    /// 「换一种拼法」：同一目标图、同一素材快照、同一参数，只把种子换成 `MosaicSeed.next(after:)`
    /// （或指定的 `newSeed`）。
    public func reshuffle(_ previous: MosaicGeneration, target: PixelBuffer, library: FeatureMatrix,
                          mask: BitMask? = nil, newSeed: UInt64? = nil) throws -> MosaicGeneration {
        try generate(target: target, density: previous.density, library: library, mask: mask,
                     seed: newSeed ?? MosaicSeed.next(after: previous.seed))
    }
}
