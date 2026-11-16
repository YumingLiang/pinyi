import XCTest
@testable import MosaicCore

final class AssignmentTests: XCTestCase {
    private func makeCells(_ grid: MosaicGrid, seed: UInt64) -> FeatureMatrix {
        FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: seed))
    }

    // MARK: - 约束不变量

    func testDefaultConstraintsWithLargeLibrary() throws {
        let grid = try MosaicGrid(columns: 40, rows: 30)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 3000, seed: 1))
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: makeCells(grid, seed: 2), library: lib)
        XCTAssertEqual(a.tiles.count, 1200)
        XCTAssertEqual(a.statistics.resolvedCap, 1) // max(1, ceil(1200/3000×2)) = 1
        XCTAssertEqual(neighborhoodViolations(a, .eight), 0)
        XCTAssertLessThanOrEqual(useCounts(a, libraryCount: 3000).max()!, 1)
        XCTAssertFalse(a.statistics.relaxedConstraints)
        XCTAssertFalse(a.statistics.needsRepetition)
        XCTAssertEqual(a.statistics.distinctTilesUsed, 1200)
        XCTAssertEqual(a.statistics.count(at: .primary) + a.statistics.count(at: .expandedCandidates) + a.statistics.count(at: .batchDeepened) + a.statistics.count(at: .exhaustiveSearch), 1200)
    }

    /// 素材少于格子数：自动上限 = ceil(1200/300×2) = 8；仍满足相邻不重复。
    func testFewerMaterialsThanCellsAutomaticCap() throws {
        let grid = try MosaicGrid(columns: 40, rows: 30)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 300, seed: 3))
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: makeCells(grid, seed: 4), library: lib)
        XCTAssertEqual(a.statistics.resolvedCap, 8)
        XCTAssertTrue(a.statistics.needsRepetition)
        XCTAssertLessThanOrEqual(useCounts(a, libraryCount: 300).max()!, 8)
        XCTAssertEqual(neighborhoodViolations(a, .eight), 0)
        XCTAssertFalse(a.statistics.relaxedConstraints)
    }

    func testRadiusTwoNeighborhood() throws {
        let grid = try MosaicGrid(columns: 30, rows: 20)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 400, seed: 5))
        // v0.2：所有档位默认半径 1；半径 2 仍作为引擎内部可选项测试。
        XCTAssertEqual(AssignmentConfiguration.recommended(for: .fine).neighborhood, .eight)
        XCTAssertEqual(AssignmentConfiguration.recommended(for: .coarse).neighborhood, .eight)
        var config = AssignmentConfiguration(seed: 9)
        config.neighborhood = .moore(radius: 2)
        config.cap = .unlimited
        let a = try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: makeCells(grid, seed: 6), library: lib)
        XCTAssertEqual(neighborhoodViolations(a, .moore(radius: 2)), 0)
    }

    /// 固定上限 1、素材数 = 格子数：必须每张恰好用一次（会触发扩展候选回退）。
    func testCapOneWithExactlyEnoughMaterials() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 100, seed: 7))
        let config = AssignmentConfiguration(cap: .limited(1), seed: 1)
        let a = try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: makeCells(grid, seed: 8), library: lib)
        XCTAssertEqual(Set(a.tiles).count, 100)
        XCTAssertEqual(a.statistics.count(at: .capIgnored), 0)
        XCTAssertEqual(a.statistics.count(at: .neighborhoodIgnored), 0)
        XCTAssertGreaterThan(a.statistics.count(at: .expandedCandidates), 0, "k=32 的候选会被用完，应触发扩到 128")
    }

    /// 回退第 1 级：k 很小时扩展到 fallbackK。
    func testExpandedCandidatesFallback() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 400, seed: 9))
        let config = AssignmentConfiguration(k: 1, fallbackK: 128, cap: .limited(1), seed: 3)
        let a = try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: makeCells(grid, seed: 10), library: lib)
        XCTAssertGreaterThan(a.statistics.count(at: .expandedCandidates), 0)
        XCTAssertEqual(neighborhoodViolations(a, .eight), 0)
        XCTAssertEqual(Set(a.tiles).count, 100)
    }

    /// 上限 1 但素材只有 50 张：至少一半格子要忽略上限，且结果页需提示。
    func testCapIgnoredWhenMaterialsExhausted() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 50, seed: 11))
        let config = AssignmentConfiguration(cap: .limited(1), seed: 4)
        let a = try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: makeCells(grid, seed: 12), library: lib)
        XCTAssertGreaterThanOrEqual(a.statistics.count(at: .capIgnored) + a.statistics.count(at: .neighborhoodIgnored), 50)
        XCTAssertTrue(a.statistics.relaxedConstraints)
        // 忽略上限时仍保持 4 邻域不重复（素材足够多时最后一级不会出现）。
        XCTAssertEqual(a.statistics.count(at: .neighborhoodIgnored), 0)
        XCTAssertEqual(neighborhoodViolations(a, .four), 0)
    }

    /// 只有 2 张素材：8 邻域不可能满足，逐级放宽直至兜底，每格都有结果。
    func testTwoMaterialsRelaxesNeighborhood() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 2, seed: 13))
        let a = try GreedyAssigner(configuration: AssignmentConfiguration(seed: 5))
            .assign(grid: grid, cellFeatures: makeCells(grid, seed: 14), library: lib)
        XCTAssertEqual(a.tiles.count, 100)
        XCTAssertTrue(a.tiles.allSatisfy { $0 == 0 || $0 == 1 })
        XCTAssertTrue(a.statistics.relaxedConstraints)
        XCTAssertEqual(a.statistics.resolvedCap, 100)
        XCTAssertGreaterThan(a.statistics.count(at: .relaxedNeighborhood), 0)
        // 只有落到最后一级（忽略邻域）的格子才可能与 4 邻居重复。
        for i in 0..<100 {
            for j in grid.neighbors(of: i, in: .four) where a.tiles[i] == a.tiles[j] {
                XCTAssertTrue(a.levels[i] == .neighborhoodIgnored || a.levels[j] == .neighborhoodIgnored,
                              "cells \(i),\(j) repeat without being marked neighborhoodIgnored")
            }
        }
    }

    func testSingleMaterial() throws {
        let grid = try MosaicGrid(columns: 5, rows: 4)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 1, seed: 15))
        // 行优先：第一个格子无已分配邻居 → primary；其余都有左/上邻居 → 只能兜底。
        let a = try GreedyAssigner(configuration: AssignmentConfiguration(order: .rowMajor))
            .assign(grid: grid, cellFeatures: makeCells(grid, seed: 16), library: lib)
        XCTAssertEqual(a.tiles, [Int](repeating: 0, count: 20))
        XCTAssertEqual(a.statistics.count(at: .neighborhoodIgnored), 19)
        XCTAssertEqual(a.statistics.count(at: .primary), 1)
        // 随机顺序下同样每格都有结果。
        let b = try GreedyAssigner().assign(grid: grid, cellFeatures: makeCells(grid, seed: 16), library: lib)
        XCTAssertEqual(b.tiles, [Int](repeating: 0, count: 20))
        XCTAssertEqual(b.statistics.levelCounts.reduce(0, +), 20)
        XCTAssertEqual(a.statistics.maxUses, 20)
    }

    // MARK: - 可复现性

    /// A-16：同种子 + 同快照 + 同参数 ⇒ 逐格一致（另含换种子结果不同）。
    func testSameSeedSameResultDifferentSeedDifferentResult() throws {
        let grid = try MosaicGrid(columns: 40, rows: 30)
        let cells = makeCells(grid, seed: 17)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 2000, seed: 18))
        func run(_ seed: UInt64, _ kernel: ScalarSIMDKernel = ScalarSIMDKernel()) throws -> MosaicAssignment {
            try GreedyAssigner(configuration: AssignmentConfiguration(seed: seed), kernel: kernel)
                .assign(grid: grid, cellFeatures: cells, library: lib)
        }
        let a1 = try run(42)
        let a2 = try run(42)
        let a3 = try run(42, ScalarSIMDKernel(parallel: false, queryBlockSize: 5, candidateTileSize: 100))
        let b = try run(43)
        XCTAssertEqual(a1, a2)
        XCTAssertEqual(a1, a3, "结果与并行/分块参数无关")
        XCTAssertNotEqual(a1.tiles, b.tiles)
        XCTAssertEqual(b.seed, 43)
    }

    func testOrderOptions() throws {
        let grid = try MosaicGrid(columns: 6, rows: 5)
        let cells = makeCells(grid, seed: 19)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 100, seed: 20))
        let rowMajor = try GreedyAssigner(configuration: AssignmentConfiguration(order: .rowMajor))
            .assign(grid: grid, cellFeatures: cells, library: lib)
        let custom = try GreedyAssigner(configuration: AssignmentConfiguration(order: .custom(Array(0..<30))))
            .assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertEqual(rowMajor.tiles, custom.tiles)
        XCTAssertThrowsError(try GreedyAssigner(configuration: AssignmentConfiguration(order: .custom([0, 0])))
            .assign(grid: grid, cellFeatures: cells, library: lib))
        XCTAssertThrowsError(try GreedyAssigner(configuration: AssignmentConfiguration(order: .custom(Array(repeating: 0, count: 30))))
            .assign(grid: grid, cellFeatures: cells, library: lib))
    }

    // MARK: - 质量与惩罚

    /// 素材中含有每个格子的精确特征时，无约束、无惩罚应全部精确命中。
    func testExactMatchesWhenUnconstrained() throws {
        let grid = try MosaicGrid(columns: 8, rows: 8)
        let cellVectors = syntheticVectors(count: 64, seed: 21)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 500, seed: 22) + cellVectors)
        let config = AssignmentConfiguration(cap: .unlimited, neighborhood: .none, relaxedNeighborhood: .none).withAbsolutePenalties(usage: 0, lowDetail: 0)
        let a = try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: FeatureMatrix(vectors: cellVectors), library: lib)
        XCTAssertEqual(a.tiles, (0..<64).map { 500 + $0 })
        XCTAssertEqual(a.statistics.totalDistance, 0)
    }

    /// 只有一张"最佳"素材时：λ = 0 全部选它；λ 较大时会分散使用。
    func testUsagePenaltySpreadsUsage() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let target = FeatureVector(uniform: SIMD3(0.5, 0, 0))
        let cells = FeatureMatrix(vectors: Array(repeating: target, count: 100))
        var vs = [target]
        for i in 1...20 { vs.append(FeatureVector(uniform: SIMD3(0.5 + Float(i) * 0.01, 0, 0))) }
        let lib = FeatureMatrix(vectors: vs)
        let base = AssignmentConfiguration(cap: .unlimited, neighborhood: .none, relaxedNeighborhood: .none).withAbsolutePenalties(usage: 0, lowDetail: 0)
        let a0 = try GreedyAssigner(configuration: base).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertEqual(Set(a0.tiles), [0])
        var penalized = base
        penalized.usagePenalty = 0.01
        let a1 = try GreedyAssigner(configuration: penalized).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertGreaterThan(Set(a1.tiles).count, 5)
    }

    func testMaskIsRespected() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 1000, seed: 23))
        let allowed = Set(stride(from: 0, to: 1000, by: 5))
        let mask = BitMask(count: 1000, setIndices: allowed)
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: makeCells(grid, seed: 24), library: lib, mask: mask)
        XCTAssertTrue(a.tiles.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(a.statistics.availableCandidates, 200)
        XCTAssertEqual(a.statistics.resolvedCap, 1)
        XCTAssertEqual(neighborhoodViolations(a, .eight), 0)
    }

    // MARK: - 边界与错误

    func testEmptyGrid() throws {
        let grid = try MosaicGrid(columns: 0, rows: 0)
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: FeatureMatrix(vectors: []), library: FeatureMatrix(vectors: []))
        XCTAssertEqual(a.tiles, [])
        XCTAssertEqual(a.statistics.cellCount, 0)
        XCTAssertEqual(a.statistics.meanDistance, 0)
    }

    func testEmptyLibraryAndEmptyMaskThrow() throws {
        let grid = try MosaicGrid(columns: 3, rows: 3)
        let cells = makeCells(grid, seed: 25)
        XCTAssertThrowsError(try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: FeatureMatrix(vectors: []))) {
            XCTAssertEqual($0 as? MosaicError, .noCandidates)
        }
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 10, seed: 26))
        XCTAssertThrowsError(try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib, mask: BitMask(count: 10))) {
            XCTAssertEqual($0 as? MosaicError, .noCandidates)
        }
    }

    func testInputValidation() throws {
        let grid = try MosaicGrid(columns: 3, rows: 3)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 10, seed: 27))
        XCTAssertThrowsError(try GreedyAssigner().assign(grid: grid, cellFeatures: makeCells(try MosaicGrid(columns: 2, rows: 2), seed: 1), library: lib)) {
            XCTAssertEqual($0 as? MosaicError, .countMismatch(expected: 9, actual: 4))
        }
        XCTAssertThrowsError(try GreedyAssigner().assign(grid: grid, cellFeatures: makeCells(grid, seed: 1), library: lib, mask: BitMask(count: 3)))
        XCTAssertThrowsError(try GreedyAssigner(configuration: AssignmentConfiguration(k: 0)).assign(grid: grid, cellFeatures: makeCells(grid, seed: 1), library: lib))
        XCTAssertThrowsError(try GreedyAssigner(configuration: AssignmentConfiguration(cap: .limited(0))).assign(grid: grid, cellFeatures: makeCells(grid, seed: 1), library: lib))
        XCTAssertThrowsError(try GreedyAssigner(configuration: AssignmentConfiguration(usagePenalty: -1)).assign(grid: grid, cellFeatures: makeCells(grid, seed: 1), library: lib))
        XCTAssertThrowsError(try MosaicGrid(columns: -1, rows: 2))
        XCTAssertThrowsError(try MosaicGrid(columns: 0, rows: 2))
        XCTAssertThrowsError(try MosaicGrid(density: .coarse, imageWidth: 0, imageHeight: 10))
    }

    func testUsageCapResolution() {
        XCTAssertEqual(UsageCap.default.resolve(cellCount: 4800, availableCount: 50_000), 1)
        XCTAssertEqual(UsageCap.default.resolve(cellCount: 4800, availableCount: 1000), 10)
        XCTAssertEqual(UsageCap.default.resolve(cellCount: 10800, availableCount: 200), 108)
        XCTAssertEqual(UsageCap.default.resolve(cellCount: 1201, availableCount: 1200), 3) // ceil(2.0017)
        XCTAssertEqual(UsageCap.limited(3).resolve(cellCount: 1, availableCount: 1), 3)
        XCTAssertNil(UsageCap.unlimited.resolve(cellCount: 1, availableCount: 1))
    }

    func testNeighborhoodOffsets() throws {
        XCTAssertEqual(Neighborhood.eight.offsets.count, 8)
        XCTAssertEqual(Neighborhood.four.offsets.count, 4)
        XCTAssertEqual(Neighborhood.moore(radius: 2).offsets.count, 24)
        XCTAssertEqual(Neighborhood.vonNeumann(radius: 2).offsets.count, 12)
        XCTAssertEqual(Neighborhood.none.offsets.count, 0)
        let g = try MosaicGrid(columns: 3, rows: 3)
        XCTAssertEqual(g.neighbors(of: 0, in: .eight).sorted(), [1, 3, 4])
        XCTAssertEqual(g.neighbors(of: 4, in: .eight).count, 8)
        XCTAssertEqual(g.neighbors(of: 4, in: .four).sorted(), [1, 3, 5, 7])
    }

    // MARK: - 端到端

    func testPipelineEndToEnd() throws {
        // 左黑右白的 80×60 目标图；素材为 64 级灰度纯色。
        let w = 80, h = 60
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<(w / 2) { let o = (y * w + x) * 4; bytes[o] = 0; bytes[o + 1] = 0; bytes[o + 2] = 0 } }
        let target = try PixelBuffer(width: w, height: h, bytes: bytes)
        let extractor = FeatureExtractor()
        let library = try (0..<64).map { i -> FeatureRecord in
            let v = UInt8(i * 4)
            return try extractor.extract(from: PixelBuffer.solid(width: 4, height: 4, red: v, green: v, blue: v))
        }
        let pipeline = MosaicPipeline(assigner: GreedyAssigner(configuration: AssignmentConfiguration(cap: .unlimited, seed: 1)))
        let gen = try pipeline.generate(target: target, density: .custom(columns: 8), library: FeatureMatrix(records: library))
        let a = gen.assignment
        XCTAssertEqual(gen.supply, .insufficient(available: 64))
        XCTAssertEqual(gen.layout.cellSize, 10)
        XCTAssertEqual(a.grid.columns, 8)
        XCTAssertEqual(a.grid.rows, 6)
        XCTAssertEqual(neighborhoodViolations(a, .eight), 0)
        // 左半边选暗素材，右半边选亮素材。
        for r in 0..<6 {
            XCTAssertLessThan(a.tile(column: 0, row: r), 16)
            XCTAssertGreaterThan(a.tile(column: 7, row: r), 48)
        }
    }
}
