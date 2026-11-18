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
    /// 生成所用快照。启用清晰度探测时，这是**剔除了不够清楚的照片之后**的快照，「换一种拼法」沿用它。
    public var snapshot: IndexSnapshot
    /// 不够清楚而没用上的照片统计（来源页 `source.excluded_low_res` + 性能页）。
    public var lowRes: LowResReport = .disabled
    public var outcome: GenerationOutcome {
        var o = GenerationOutcome(generation)
        if lowRes.enabled { o.availableAfterFilter = snapshot.availableCount }
        return o
    }

    public init(generation: MosaicGeneration, snapshot: IndexSnapshot, lowRes: LowResReport = .disabled) {
        self.generation = generation
        self.snapshot = snapshot
        self.lowRes = lowRes
    }

    /// 每个格子对应的 localIdentifier（行优先）；渲染时据此取缩略图 / 原图。
    public var cellAssetIDs: [String?] { Self.cellAssetIDs(generation, snapshot) }

    static func cellAssetIDs(_ g: MosaicGeneration, _ snapshot: IndexSnapshot) -> [String?] {
        g.assignment.tiles.map { row in row >= 0 && row < snapshot.assetIDsByRow.count ? snapshot.assetIDsByRow[row] : nil }
    }
}

/// 执行生成（不含 UI）：计时 + 进度映射 + Task 取消 + （可选）清晰度探测与重配。平台层在后台 Task 里调用。
public struct GenerationRunner: Sendable {
    public var pipeline: MosaicPipeline
    public var perf: PerfRecorder?
    /// 「不能略糊」：注入后，匹配完只探测分到格子上的照片，不合格的剔除后重配（最多 `maxRematchRounds` 轮）。
    public var sharpness: LocalResolutionChecker?

    public init(pipeline: MosaicPipeline = MosaicPipeline(), perf: PerfRecorder? = nil, sharpness: LocalResolutionChecker? = nil) {
        self.pipeline = pipeline
        self.perf = perf
        self.sharpness = sharpness
    }

    /// App 生产环境用的生成器（`AppDependencies.live` 调它）。
    ///
    /// **不注入清晰度探测**（AndyL 11-16 决定取消 #5 的逐张检查）：生成只跑一次 `generateOnce`，
    /// 不做逐张 PhotoKit 请求、不剔除重配、不做最后兜底补格，速度回到 14ac550。
    /// `lowRes.enabled == false`，来源页「不够清楚」行 / 结果页筛选后「照片比较少」/ 进度页「检查清晰度」自然不出现。
    /// iCloud-only / 本机小图照旧按 14ac550：照常参与匹配，导出时取不到每格像素就退回 128px 缩略图（糊格子），
    /// 再取不到才是白格子——导出端兜底逻辑不变。
    /// 可选的 `sharpness` 路径与 `LocalResolutionChecker` 保留（测试与作品换照片复用），但不接入生成链路。
    public static func production(pipeline: MosaicPipeline, perf: PerfRecorder?) -> GenerationRunner {
        GenerationRunner(pipeline: pipeline, perf: perf, sharpness: nil)
    }

    /// - Parameter progress: 整体完成比例 0…1（取样 5% / 匹配 60% / 分配 35%）。
    /// - Throws: `CancellationError`（Task 取消，正常路径）或引擎错误。
    public func run(target: PixelBuffer, snapshot: IndexSnapshot, settings: GenerationSettings, seed: UInt64,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> GenerationProduct {
        try await run(target: target, snapshot: snapshot, settings: settings, seed: seed, progress: progress, stage: nil)
    }

    /// 同上，另报告阶段（匹配 / 检查清晰度），进度页据此换文案。
    /// - Throws: 另外在剔除后一张可用的都不剩时抛 `NoSharpPhotosError`（→ `GenerationFailure.noMaterial`）。
    public func run(target: PixelBuffer, snapshot: IndexSnapshot, settings: GenerationSettings, seed: UInt64,
                    progress: (@Sendable (Double) -> Void)?, stage: (@Sendable (GenerationStage) -> Void)?) async throws -> GenerationProduct {
        try await run(target: target, snapshot: snapshot, settings: settings, seed: seed, carriedExcluded: [],
                      progress: progress, stage: stage)
    }

    /// 「换一种拼法」：同一快照、同一参数，只换种子。
    public func reshuffle(_ previous: GenerationProduct, target: PixelBuffer, settings: GenerationSettings, seed: UInt64,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> GenerationProduct {
        try await reshuffle(previous, target: target, settings: settings, seed: seed, progress: progress, stage: nil)
    }

    public func reshuffle(_ previous: GenerationProduct, target: PixelBuffer, settings: GenerationSettings, seed: UInt64,
                          progress: (@Sendable (Double) -> Void)?, stage: (@Sendable (GenerationStage) -> Void)?) async throws -> GenerationProduct {
        try await run(target: target, snapshot: previous.snapshot, settings: settings, seed: seed,
                      carriedExcluded: previous.lowRes.excludedAssetIDs, progress: progress, stage: stage)
    }

    /// 相册变化：清掉「不合格」的缓存（照片可能刚下载回本机）。
    public func invalidateLocalResolution() { sharpness?.cache.removeUnusable() }

    // MARK: - 内部

    private func generateOnce(target: PixelBuffer, snapshot: IndexSnapshot, settings: GenerationSettings, seed: UInt64,
                              noteSuffix: String, progress: (@Sendable (Double) -> Void)?) async throws -> MosaicGeneration {
        let timer = perf.map { GenerationPhaseTimer(clock: $0.clock) }
        let g = try await pipeline.generate(target: target, density: settings.density.density, snapshot: snapshot.library,
                                            seed: seed) { p in
            timer?.observe(MosaicProgressPhase(rawValue: p.phase.rawValue) ?? .assigning)
            progress?(p.overallFraction)
        }
        if let timer, let perf {
            let note = "\(settings.density.rawValue) \(g.layout.columns)×\(g.layout.rows) 素材 \(snapshot.availableCount)\(noteSuffix)"
            for s in timer.finish(cells: g.layout.cellCount, note: note) { perf.record(s) }
        }
        return g
    }

    private func run(target: PixelBuffer, snapshot: IndexSnapshot, settings: GenerationSettings, seed: UInt64,
                     carriedExcluded: Set<String>, progress: (@Sendable (Double) -> Void)?,
                     stage: (@Sendable (GenerationStage) -> Void)?) async throws -> GenerationProduct {
        stage?(.matching)
        guard let checker = sharpness else {
            let g = try await generateOnce(target: target, snapshot: snapshot, settings: settings, seed: seed,
                                           noteSuffix: "", progress: progress)
            return GenerationProduct(generation: g, snapshot: snapshot)
        }
        // 进度分段：首轮生成 0–0.8、首轮探测 0.8–0.9，之后每轮重配（生成 + 探测）平分 0.9–1.0。
        let rounds = max(1, checker.maxRematchRounds)
        func segment(_ round: Int, probing: Bool) -> (Double, Double) {
            if round == 0 { return probing ? (0.8, 0.9) : (0, 0.8) }
            let w = 0.1 / Double(rounds)
            let lo = 0.9 + w * Double(min(round, rounds) - 1)
            return probing ? (lo + w / 2, lo + w) : (lo, lo + w / 2)
        }
        func scaled(_ seg: (Double, Double)) -> (@Sendable (Double) -> Void)? {
            guard let progress else { return nil }
            return { f in progress(seg.0 + (seg.1 - seg.0) * min(max(f, 0), 1)) }
        }

        let clock = perf?.clock ?? .system
        var excluded = carriedExcluded
        // 先剔掉缓存里已知不合格的（本会话之前探测过），减少重配轮数。
        let (initial, pre) = try snapshot.excluding(assetIDs: checker.cache.knownUnusable())
        var snap = initial
        excluded.formUnion(pre)
        var report = LowResReport(enabled: true)
        var seenInRun = Set<String>()
        var round = 0
        while true {
            stage?(.matching)
            if snap.availableCount == 0, !excluded.isEmpty { throw NoSharpPhotosError(excludedAssetIDs: excluded) }
            let g: MosaicGeneration
            do {
                g = try await generateOnce(target: target, snapshot: snap, settings: settings, seed: seed,
                                           noteSuffix: round == 0 ? "" : " 重配第 \(round) 轮",
                                           progress: scaled(segment(round, probing: false)))
            } catch let e as MosaicError {
                if case .noCandidates = e, !excluded.isEmpty { throw NoSharpPhotosError(excludedAssetIDs: excluded) }
                throw e
            }
            let cellIDs = GenerationProduct.cellAssetIDs(g, snap)
            stage?(.checkingSharpness)
            let probeSeg = scaled(segment(round, probing: true))
            let t0 = clock.now()
            let pass = try await checker.check(cellIDs.compactMap { $0 }) { done, total in
                probeSeg?(Double(done) / Double(max(total, 1)))
            }
            report.probeSeconds += clock.now() - t0
            report.probedCount += pass.probed
            report.cacheHits += pass.cacheHits
            let distinct = Set(cellIDs.compactMap { $0 })
            report.rounds.append(LowResReport.Round(assignedDistinct: distinct.count,
                                                    newlyIntroduced: distinct.subtracting(seenInRun).count,
                                                    probed: pass.probed, unusable: pass.unusable.count))
            seenInRun.formUnion(distinct)
            let bad = pass.unusable
            // 没有 ID 的格子（理论上不会出现）也当作不合格处理：最终每格都必须是探测通过的照片。
            let badCells = cellIDs.indices.filter { cellIDs[$0].map { bad.contains($0) } ?? true }
            if badCells.isEmpty {
                return finish(g, snap, excluded, round)
            }
            let (next, removed) = try snap.excluding(assetIDs: bad)
            excluded.formUnion(removed)
            snap = next
            if round < checker.maxRematchRounds {
                round += 1
                continue
            }
            // 最后兜底（架构师 PR #5 评审）：到达最多轮数仍有格子分到不合格照片 → 只把这些格子换成
            // 「已探测且通过」的照片，忽略单张使用上限（多重复几次也比糊强）。一张通过的都没有才走 noMaterial。
            let passed = checker.cache.knownUsable()
            var allowed = BitMask(count: snap.library.table.count)
            for row in 0..<min(snap.assetIDsByRow.count, allowed.count) where snap.library.mask[row] {
                if let id = snap.assetIDsByRow[row], passed.contains(id) { allowed[row] = true }
            }
            if allowed.setCount == 0 { throw NoSharpPhotosError(excludedAssetIDs: excluded) }
            let filled = try await pipeline.refill(g, target: target, snapshot: snap.library, cells: badCells, allowed: allowed)
            report.finalFallbackCellCount = badCells.count
            return finish(filled, snap, excluded, round)
        }

        func finish(_ g: MosaicGeneration, _ snap: IndexSnapshot, _ excluded: Set<String>, _ round: Int) -> GenerationProduct {
            report.excludedAssetIDs = excluded
            report.rematchRounds = round
            report.unresolvedCellCount = 0
            perf?.record(.sharpnessProbe, seconds: report.probeSeconds, items: report.probedCount, note: report.perfNote)
            progress?(1)
            return GenerationProduct(generation: g, snapshot: snap, lowRes: report)
        }
    }
}
