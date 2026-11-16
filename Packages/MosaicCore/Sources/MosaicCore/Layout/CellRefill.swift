/// 定点补格（App 层「不能略糊」的最后兜底，hd-export-req-v0.2 F5）。
///
/// 用法：常规分配（含放宽链）重配几轮后，仍有格子分到了不能用的素材（例如本机版本不够清楚），
/// 只把这些格子换成 `allowed` 掩码内的素材，其余格子原样保留。
/// 规则：**忽略单张使用上限**（多重复几次也比糊强）；在 `allowed` 的 top‑k 里优先选主邻域里还没出现过的
/// （记 `.capIgnored`），都撞邻居时取最近的（记 `.neighborhoodIgnored`）。只按特征距离选，不加使用 / 纯色惩罚。
extension MosaicPipeline {
    /// 补格时每格看的候选数。
    public static let refillCandidateCount = 16

    /// - Parameters:
    ///   - generation: 待修补的结果（`layout` 与 `target` 对应）。
    ///   - snapshot: 生成所用快照（取特征表；口径须与取样器一致）。
    ///   - cells: 要换掉的格子下标（行优先；重复、越界的忽略）。
    ///   - allowed: 允许使用的素材行（长度 = 特征表行数；会再与快照掩码求交）。
    /// - Throws: `allowed ∧ 快照` 为空时抛 `MosaicError.noCandidates`；取消时抛 `CancellationError`。
    public func refill(_ generation: MosaicGeneration, target: PixelBuffer, snapshot: LibrarySnapshot, cells: [Int],
                       allowed: BitMask, cancellation: CancellationToken? = nil) throws -> MosaicGeneration {
        let check = CancellationCheck(token: cancellation)
        try check.check()
        let targetSpec = sampler.extractor.spec
        guard snapshot.table.spec == targetSpec else {
            throw MosaicError.featureSpecMismatch(library: snapshot.table.spec, target: targetSpec)
        }
        guard allowed.count == snapshot.table.count else {
            throw MosaicError.countMismatch(expected: snapshot.table.count, actual: allowed.count)
        }
        let mask = allowed.intersection(snapshot.mask)
        guard mask.setCount > 0 else { throw MosaicError.noCandidates }
        let a = generation.assignment
        let cellCount = a.tiles.count
        let todo = Array(Set(cells.filter { $0 >= 0 && $0 < cellCount })).sorted()
        guard !todo.isEmpty else { return generation }

        let all = try sampler.cellFeatures(of: target, layout: generation.layout)
        try check.check()
        let queries = FeatureMatrix(records: todo.map { all[$0] })
        let k = min(Self.refillCandidateCount, mask.setCount)
        let top = try assigner.kernel.topK(queries: queries, candidates: snapshot.table.matrix, k: k, mask: mask,
                                           cancellation: cancellation, progress: nil)
        try check.check()

        var tiles = a.tiles
        var distances = a.distances
        var levels = a.levels
        let neighborhood = assigner.configuration.neighborhood
        for (q, cell) in todo.enumerated() {
            let cands = top.neighbors(forQuery: q).filter { $0.distance.isFinite }
            guard let best = cands.first else { continue }
            let near = Set(a.grid.neighbors(of: cell, in: neighborhood).map { tiles[$0] })
            if let ok = cands.first(where: { !near.contains($0.index) }) {
                tiles[cell] = ok.index; distances[cell] = ok.distance; levels[cell] = .capIgnored
            } else {
                tiles[cell] = best.index; distances[cell] = best.distance; levels[cell] = .neighborhoodIgnored
            }
        }

        var stats = a.statistics
        var levelCounts = Array(repeating: 0, count: FallbackLevel.allCases.count)
        for l in levels { levelCounts[l.rawValue] += 1 }
        var uses: [Int: Int] = [:]
        for t in tiles { uses[t, default: 0] += 1 }
        stats.levelCounts = levelCounts
        stats.distinctTilesUsed = uses.count
        stats.maxUses = uses.values.max() ?? 0
        stats.totalDistance = distances.reduce(0) { $0 + Double($1) }
        let assignment = MosaicAssignment(grid: a.grid, tiles: tiles, distances: distances, levels: levels,
                                          statistics: stats, seed: a.seed)
        return MosaicGeneration(layout: generation.layout, assignment: assignment, supply: generation.supply,
                                density: generation.density)
    }

    /// `refill` 的 Swift 并发入口：Task 取消即停，抛 `CancellationError`。
    public func refill(_ generation: MosaicGeneration, target: PixelBuffer, snapshot: LibrarySnapshot, cells: [Int],
                       allowed: BitMask) async throws -> MosaicGeneration {
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try refill(generation, target: target, snapshot: snapshot, cells: cells, allowed: allowed, cancellation: token)
        } onCancel: {
            token.cancel()
        }
    }
}
