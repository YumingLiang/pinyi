import MosaicCore

/// 生成参数（设置页）。
public struct GenerationSettings: Sendable, Hashable {
    public var density: DensityChoice = .medium
    /// 原图叠加 0…0.3（技术方案 §3.5），默认 0（「更能看清照片」端）。
    public var overlayAlpha: Double = 0
    public init(density: DensityChoice = .medium, overlayAlpha: Double = 0) {
        self.density = density
        self.overlayAlpha = OverlayBlendLimits.clamp(overlayAlpha)
    }
}

public enum OverlayBlendLimits {
    public static let maxAlpha = 0.3
    public static func clamp(_ a: Double) -> Double { min(max(a, 0), maxAlpha) }
}

/// 密度三档（UI 用；映射到 `MosaicCore.Density`）。
public enum DensityChoice: String, Sendable, Hashable, CaseIterable, Codable {
    case coarse, medium, fine

    public var density: Density {
        switch self {
        case .coarse: return .coarse
        case .medium: return .medium
        case .fine: return .fine
        }
    }
    public var titleKey: L10nKey {
        switch self {
        case .coarse: return .densityCoarse
        case .medium: return .densityMedium
        case .fine: return .densityFine
        }
    }
    public var descriptionKey: L10nKey {
        switch self {
        case .coarse: return .densityCoarseDesc
        case .medium: return .densityMediumDesc
        case .fine: return .densityFineDesc
        }
    }
}

/// 目标图解码尺寸（PhotosPicker → ImageIO 降采样；`MosaicPipeline` 建议长边 ≤ 2048）。
public enum TargetImagePolicy {
    public static let maxLongEdge = 2048
    /// 降采样后的像素尺寸（保持宽高比，不放大）。
    public static func downsampledSize(width: Int, height: Int, maxLongEdge: Int = maxLongEdge) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let long = max(width, height)
        guard long > maxLongEdge else { return (width, height) }
        let s = Double(maxLongEdge) / Double(long)
        return (max(1, Int((Double(width) * s).rounded())), max(1, Int((Double(height) * s).rounded())))
    }
}

/// 一次生成的产物：结果 + 快照（「换一种拼法」复用同一快照，参数不变，决定 4）。
public struct GenerationProduct: Sendable {
    public var generation: MosaicGeneration
    public var snapshot: IndexSnapshot
    public var outcome: GenerationOutcome { GenerationOutcome(generation) }

    /// 每个格子对应的 localIdentifier（行优先）；渲染时据此取缩略图 / 原图。
    public var cellAssetIDs: [String?] {
        generation.assignment.tiles.map { row in row >= 0 && row < snapshot.assetIDsByRow.count ? snapshot.assetIDsByRow[row] : nil }
    }
}

/// 执行生成（不含 UI）：计时 + 进度映射 + Task 取消。平台层在后台 Task 里调用。
public struct GenerationRunner: Sendable {
    public var pipeline: MosaicPipeline
    public var perf: PerfRecorder?

    public init(pipeline: MosaicPipeline = MosaicPipeline(), perf: PerfRecorder? = nil) {
        self.pipeline = pipeline
        self.perf = perf
    }

    /// - Parameter progress: 整体完成比例 0…1（取样 5% / 匹配 60% / 分配 35%）。
    /// - Throws: `CancellationError`（Task 取消，正常路径）或引擎错误。
    public func run(target: PixelBuffer, snapshot: IndexSnapshot, settings: GenerationSettings, seed: UInt64,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> GenerationProduct {
        let timer = perf.map { GenerationPhaseTimer(clock: $0.clock) }
        let g = try await pipeline.generate(target: target, density: settings.density.density, snapshot: snapshot.library,
                                            seed: seed) { p in
            timer?.observe(MosaicProgressPhase(rawValue: p.phase.rawValue) ?? .assigning)
            progress?(p.overallFraction)
        }
        if let timer, let perf {
            let note = "\(settings.density.rawValue) \(g.layout.columns)×\(g.layout.rows) 素材 \(snapshot.availableCount)"
            for s in timer.finish(cells: g.layout.cellCount, note: note) { perf.record(s) }
        }
        return GenerationProduct(generation: g, snapshot: snapshot)
    }

    /// 「换一种拼法」：同一快照、同一参数，只换种子。
    public func reshuffle(_ previous: GenerationProduct, target: PixelBuffer, settings: GenerationSettings, seed: UInt64,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> GenerationProduct {
        try await run(target: target, snapshot: previous.snapshot, settings: settings, seed: seed, progress: progress)
    }
}
