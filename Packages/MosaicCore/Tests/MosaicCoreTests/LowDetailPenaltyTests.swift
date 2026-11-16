import XCTest
@testable import MosaicCore

/// 亮度方差参与打分（纯色惩罚）。
final class LowDetailPenaltyTests: XCTestCase {
    private let target = FeatureVector(uniform: SIMD3(0.5, 0, 0))

    /// 与 target 的平方距离恰为 `d` 的向量（只偏移 L，4 个子块各 √(d/4)）。
    private func at(distance d: Float) -> FeatureVector {
        FeatureVector(uniform: SIMD3(0.5 + (d / 4).squareRoot(), 0, 0))
    }

    private func assignOne(library: [FeatureVector], variance: [Float]?,
                           config: AssignmentConfiguration = AssignmentConfiguration().withAbsolutePenalties(usage: 0.005, lowDetail: 0.002))
        throws -> MosaicAssignment {
        let grid = try MosaicGrid(columns: 1, rows: 1)
        return try GreedyAssigner(configuration: config).assign(
            grid: grid, cellFeatures: FeatureMatrix(vectors: [target]), library: FeatureMatrix(vectors: library),
            mask: nil, lightnessVariance: variance, cancellation: nil, progress: nil)
    }

    func testPenaltyFlipsNearTie() throws {
        // 0 = 纯色但略近，1 = 有纹理略远（差 0.001 < μ = 0.002）
        let lib = [at(distance: 0.001), at(distance: 0.002)]
        XCTAssertEqual(try assignOne(library: lib, variance: nil).tiles, [0])
        XCTAssertEqual(try assignOne(library: lib, variance: [0, 0.001]).tiles, [1])
        let off = AssignmentConfiguration().withAbsolutePenalties(usage: 0.005, lowDetail: 0)
        XCTAssertEqual(try assignOne(library: lib, variance: [0, 0.001], config: off).tiles, [0])
        // 报告的距离仍是纯颜色距离，不含惩罚。
        XCTAssertEqual(try assignOne(library: lib, variance: [0, 0.001]).distances[0], 0.002, accuracy: 1e-6)
    }

    func testPenaltyDoesNotOverrideClearlyBetterColor() throws {
        // 差 0.01 ≫ μ：纯色图仍然胜出。
        let lib = [at(distance: 0.001), at(distance: 0.011)]
        XCTAssertEqual(try assignOne(library: lib, variance: [0, 0.001]).tiles, [0])
    }

    func testFlatnessRampIsLinear() throws {
        // 方差 = ref/2 → 惩罚 μ/2 = 0.001。距离差 0.0009 → 翻转；0.0011 → 不翻转。
        let ref: Float = 0.0004
        XCTAssertEqual(try assignOne(library: [at(distance: 0.001), at(distance: 0.0019)], variance: [ref / 2, ref]).tiles, [1])
        XCTAssertEqual(try assignOne(library: [at(distance: 0.001), at(distance: 0.0021)], variance: [ref / 2, ref]).tiles, [0])
        // 方差 ≥ ref 不受惩罚：两张都有纹理，按距离。
        XCTAssertEqual(try assignOne(library: [at(distance: 0.001), at(distance: 0.0011)], variance: [ref, 1]).tiles, [0])
    }

    func testPenaltyAlsoAppliesInExhaustiveSearch() throws {
        // 2 格同色、行优先；k = fallbackK = 1，第 2 格 top‑1（素材 0）在邻域内被禁 → 走全库搜索。
        let grid = try MosaicGrid(columns: 2, rows: 1)
        let lib = FeatureMatrix(vectors: [at(distance: 0), at(distance: 0.0005), at(distance: 0.001)])
        let cells = FeatureMatrix(vectors: [target, target])
        let config = AssignmentConfiguration(k: 1, fallbackK: 1, cap: .limited(1), order: .rowMajor, batchDepths: [])
            .withAbsolutePenalties(usage: 0.005, lowDetail: 0.002)
        let without = try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertEqual(without.tiles, [0, 1])
        let with = try GreedyAssigner(configuration: config).assign(
            grid: grid, cellFeatures: cells, library: lib, mask: nil,
            lightnessVariance: [0.001, 0, 0.001], cancellation: nil, progress: nil)
        XCTAssertEqual(with.tiles, [0, 2])
        XCTAssertEqual(with.levels[1], .exhaustiveSearch)
    }

    /// M3：μ 与 λ 同为相对尺度——μ_eff = β × top‑1 中位数，默认 β = 0.04。
    func testRelativeLowDetailPenaltyScale() throws {
        let lib = [at(distance: 0.001), at(distance: 0.002)]
        let a = try assignOne(library: lib, variance: [0, 0.001], config: AssignmentConfiguration())
        XCTAssertEqual(a.statistics.top1MedianDistance, 0.001, accuracy: 1e-7)
        XCTAssertEqual(a.statistics.effectiveLowDetailPenalty, 0.04 * 0.001, accuracy: 1e-9)
        XCTAssertEqual(a.statistics.effectiveUsagePenalty, 0.1 * 0.001, accuracy: 1e-9)
        XCTAssertEqual(a.tiles, [0])   // μ_eff = 4e-5 ≪ 0.001 的距离差
        var big = AssignmentConfiguration(); big.lowDetailPenaltyRelative = 2   // μ_eff = 0.002
        XCTAssertEqual(try assignOne(library: lib, variance: [0, 0.001], config: big).tiles, [1])
        // 无方差输入时 μ_eff 记为 0。
        XCTAssertEqual(try assignOne(library: lib, variance: nil, config: AssignmentConfiguration()).statistics.effectiveLowDetailPenalty, 0)
    }

    func testFlatTilesUsedLessOnSyntheticLibrary() throws {
        // 一半素材是纯色、与另一半几乎相同颜色但略近：默认 μ 下纯色使用显著减少，平均距离只略增。
        let base = syntheticVectors(count: 400, seed: 31)
        var vecs: [FeatureVector] = []
        var variance: [Float] = []
        for v in base {
            vecs.append(v); variance.append(0.002)                       // 有纹理
            var c = v.components; c[0] += 0.003                           // 纯色，略偏
            vecs.append(FeatureVector(c)); variance.append(0)
        }
        let grid = try MosaicGrid(columns: 20, rows: 15)
        let cells = FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: 32))
        let lib = FeatureMatrix(vectors: vecs)
        func run(_ v: [Float]?) throws -> MosaicAssignment {
            try GreedyAssigner(configuration: AssignmentConfiguration(seed: 5)).assign(
                grid: grid, cellFeatures: cells, library: lib, mask: nil, lightnessVariance: v, cancellation: nil, progress: nil)
        }
        let plain = try run(nil), penal = try run(variance)
        let flatPlain = plain.tiles.filter { $0 % 2 == 1 }.count
        let flatPenal = penal.tiles.filter { $0 % 2 == 1 }.count
        print("[bench] flat tiles used: without penalty \(flatPlain), with \(flatPenal); mean dist \(plain.statistics.meanDistance) → \(penal.statistics.meanDistance)")
        // cap = 1：有纹理的那张用掉后纯色副本仍可能是次优，故不是降到 0，而是约减半。
        XCTAssertLessThan(Double(flatPenal), Double(flatPlain) * 0.6)
        XCTAssertLessThan(penal.statistics.meanDistance, plain.statistics.meanDistance * 1.5)
        XCTAssertEqual(neighborhoodViolations(penal, .eight), 0)
        XCTAssertEqual(try run(variance), penal)   // 可复现
    }

    func testNilVarianceMatchesLegacyAPI() throws {
        let grid = try MosaicGrid(columns: 12, rows: 9)
        let cells = FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: 3))
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 500, seed: 4))
        let legacy = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib)
        let full = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib, mask: nil,
                                               lightnessVariance: nil, cancellation: nil, progress: nil)
        XCTAssertEqual(legacy, full)
        // 全部素材都有足够纹理时，开启方差也不改变结果。
        let textured = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib, mask: nil,
                                                   lightnessVariance: Array(repeating: 0.01, count: 500), cancellation: nil, progress: nil)
        XCTAssertEqual(textured.tiles, legacy.tiles)
    }

    func testValidation() throws {
        var c = AssignmentConfiguration(); c.lowDetailPenalty = -1
        XCTAssertThrowsError(try c.validate())
        c = AssignmentConfiguration(); c.lowDetailVarianceReference = 0
        XCTAssertThrowsError(try c.validate())
        XCTAssertThrowsError(try assignOne(library: [target], variance: [0, 0]))
    }

    func testExtractorVarianceFeedsTable() throws {
        // 纯色图 → 方差 0、lowDetail；FeatureTable 把它带进打分。
        let flat = try FeatureExtractor().extract(from: PixelBuffer.solid(width: 8, height: 8, red: 128, green: 128, blue: 128))
        XCTAssertEqual(flat.lightnessVariance, 0, accuracy: 1e-7)
        XCTAssertTrue(flat.flags.contains(.lowDetail))
        let t = FeatureTable(records: [flat])
        XCTAssertEqual(t.lightnessVariance, [flat.lightnessVariance])
    }
}
