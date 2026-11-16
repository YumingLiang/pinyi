import XCTest
@testable import MosaicCore

/// 素材不足阈值、换一种拼法、多来源并集（技术方案 v0.2 §2.6 / §2.7 / §3.4，产品决定 2、3、4）。
final class SupplyAndReshuffleTests: XCTestCase {
    func testMaterialSupplyThreshold() {
        XCTAssertEqual(MaterialSupply.insufficientThreshold, 200)
        XCTAssertEqual(MaterialSupply.evaluate(availableCount: 0), .empty)
        XCTAssertEqual(MaterialSupply.evaluate(availableCount: 1), .insufficient(available: 1))
        XCTAssertEqual(MaterialSupply.evaluate(availableCount: 199), .insufficient(available: 199))
        XCTAssertEqual(MaterialSupply.evaluate(availableCount: 200), .sufficient)
        XCTAssertFalse(MaterialSupply.empty.allowsGeneration)
        XCTAssertTrue(MaterialSupply.insufficient(available: 5).allowsGeneration) // 不阻止生成
        XCTAssertTrue(MaterialSupply.insufficient(available: 5).needsWarning)
        XCTAssertFalse(MaterialSupply.sufficient.needsWarning)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 300, seed: 1))
        XCTAssertEqual(MaterialSupply.evaluate(library: lib, mask: nil), .sufficient)
        XCTAssertEqual(MaterialSupply.evaluate(library: lib, mask: BitMask(count: 300, setIndices: 0..<150)), .insufficient(available: 150))
    }

    func testRelaxedConstraintsFlagExcludesPureKExpansion() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let cells = FeatureMatrix(vectors: syntheticVectors(count: 100, seed: 2))
        // 只扩 k：不算放宽。
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 400, seed: 3))
        let a = try GreedyAssigner(configuration: AssignmentConfiguration(k: 1, cap: .limited(1)))
            .assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertGreaterThan(a.statistics.count(at: .expandedCandidates), 0)
        XCTAssertFalse(a.statistics.relaxedConstraints)
        XCTAssertEqual(a.statistics.relaxationCount, 0)
        XCTAssertFalse(a.statistics.isBelowMaterialThreshold)
        // 素材极少：实际放宽。
        let few = FeatureMatrix(vectors: syntheticVectors(count: 3, seed: 4))
        let b = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: few)
        XCTAssertTrue(b.statistics.relaxedConstraints)
        XCTAssertGreaterThan(b.statistics.relaxationCount, 0)
        XCTAssertTrue(b.statistics.isBelowMaterialThreshold)
    }

    // MARK: - 换一种拼法

    private func fixture() throws -> (PixelBuffer, FeatureMatrix) {
        // 平滑渐变目标图 + 多样素材。
        let w = 160, h = 120
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                bytes[o] = UInt8(x * 255 / (w - 1))
                bytes[o + 1] = UInt8(y * 255 / (h - 1))
                bytes[o + 2] = 128
            }
        }
        return (try PixelBuffer(width: w, height: h, bytes: bytes), FeatureMatrix(vectors: syntheticVectors(count: 1500, seed: 5)))
    }

    /// A-16（及 A-17 换一种拼法）：同种子重跑 pipeline 逐格一致。
    func testReshuffleChangesResultSameSeedReproduces() throws {
        let (target, lib) = try fixture()
        let pipeline = MosaicPipeline(assigner: GreedyAssigner(configuration: AssignmentConfiguration(seed: 2026)))
        let first = try pipeline.generate(target: target, density: .coarse, library: lib)
        XCTAssertEqual(first.seed, 2026)

        // 同种子 → 逐格一致（也是切后台后自动重跑的前提）。
        let again = try pipeline.generate(target: target, density: .coarse, library: lib, seed: 2026)
        XCTAssertEqual(first, again)

        // 换一种拼法 → 种子变、结果变、参数不变。
        let shuffled = try pipeline.reshuffle(first, target: target, library: lib)
        XCTAssertEqual(shuffled.seed, MosaicSeed.next(after: 2026))
        XCTAssertNotEqual(shuffled.seed, first.seed)
        XCTAssertNotEqual(shuffled.assignment.tiles, first.assignment.tiles)
        XCTAssertEqual(shuffled.layout, first.layout)
        XCTAssertEqual(shuffled.density, first.density)
        XCTAssertEqual(shuffled.assignment.statistics.resolvedCap, first.assignment.statistics.resolvedCap)
        XCTAssertEqual(neighborhoodViolations(shuffled.assignment, .eight), 0)

        // 换的序列本身可复现。
        let shuffledAgain = try pipeline.reshuffle(first, target: target, library: lib)
        XCTAssertEqual(shuffled, shuffledAgain)

        // 指定种子。
        let explicit = try pipeline.reshuffle(first, target: target, library: lib, newSeed: 7)
        XCTAssertEqual(explicit.seed, 7)
    }

    /// 评审 M1 / T2：平滑渐变目标图（1,500 张、1,200 格、cap 2），相邻格的 128 近邻高度重叠，上限很快用尽。
    /// 方案原回退链（只到 k = 128）会在素材充足时"忽略上限"并误报不足（评审实测 262 格）；
    /// 分批加深（512 → 2048）后放宽次数为 0，且不需要逐格全库搜索。
    func testBatchDeepeningAvoidsFalseShortage() throws {
        let (target, lib) = try fixture()
        // 与评审探针同口径：绝对 λ = 0.005。
        let base = AssignmentConfiguration(seed: 2026).withAbsolutePenalties(usage: 0.005, lowDetail: 0)
        func run(_ c: AssignmentConfiguration) throws -> MosaicAssignment {
            try MosaicPipeline(assigner: GreedyAssigner(configuration: c)).generate(target: target, density: .coarse, library: lib).assignment
        }
        var legacy = base
        legacy.batchDepths = []
        legacy.exhaustiveCellLimit = 0
        let old = try run(legacy)
        print("[M1] legacy chain levels=\(old.statistics.levelCounts)")
        XCTAssertGreaterThan(old.statistics.capIgnoredCount, 0)
        XCTAssertTrue(old.statistics.relaxedConstraints)

        var noExhaustive = base
        noExhaustive.exhaustiveCellLimit = 0
        let deep = try run(noExhaustive)
        print("[M1] batch-deepening levels=\(deep.statistics.levelCounts)")
        XCTAssertGreaterThan(deep.statistics.count(at: .batchDeepened), 0)
        XCTAssertEqual(deep.statistics.relaxationCount, 0)
        XCTAssertEqual(deep.statistics.count(at: .exhaustiveSearch), 0)
        XCTAssertEqual(neighborhoodViolations(deep, .eight), 0)
        XCTAssertLessThanOrEqual(useCounts(deep, libraryCount: lib.count).max()!, 2)

        // 评审数据点：fallbackK = 512（逐格）也能降到 0。
        var k512 = legacy
        k512.fallbackK = 512
        XCTAssertEqual(try run(k512).statistics.relaxationCount, 0)

        // 默认配置（相对 λ + 全部回退级）同样不放宽；结果可复现。
        let def = try run(AssignmentConfiguration(seed: 2026))
        XCTAssertFalse(def.statistics.relaxedConstraints)
        XCTAssertEqual(try run(AssignmentConfiguration(seed: 2026)), def)
    }

    /// T2：延后队列的处理是确定的——与分组大小无关、同种子逐格一致。
    /// A-16 前提（A-15 相关）：延后队列结果与分组大小无关。
    func testDeferredQueueDeterministicAcrossGroupSizes() throws {
        let grid = try MosaicGrid(columns: 30, rows: 20)
        let cells = FeatureMatrix(vectors: Array(repeating: FeatureVector(uniform: SIMD3(0.6, 0.02, 0.05)), count: grid.cellCount))
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 3000, seed: 5))
        var c = AssignmentConfiguration(seed: 9)
        c.cap = .limited(1)
        let a = try GreedyAssigner(configuration: c).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertGreaterThan(a.statistics.count(at: .batchDeepened), 0)
        for g in [1, 7, 100, 5000] {
            var cg = c
            cg.batchQueryGroupSize = g
            XCTAssertEqual(try GreedyAssigner(configuration: cg).assign(grid: grid, cellFeatures: cells, library: lib), a, "group \(g)")
        }
        XCTAssertEqual(neighborhoodViolations(a, .eight), 0)
    }

    /// M1 第 5 步：剩余 ≤ exhaustiveCellLimit 时才逐格全库搜索；超过则跳过全库、直接放宽。
    func testExhaustiveOnlyWhenFewCellsRemain() throws {
        let grid = try MosaicGrid(columns: 30, rows: 20)
        let cells = FeatureMatrix(vectors: Array(repeating: FeatureVector(uniform: SIMD3(0.6, 0.02, 0.05)), count: grid.cellCount))
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 3000, seed: 5))
        var c = AssignmentConfiguration(seed: 9, batchDepths: [64])
        c.k = 8; c.fallbackK = 16; c.cap = .limited(1)
        c.exhaustiveCellLimit = 10_000
        let a = try GreedyAssigner(configuration: c).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertGreaterThan(a.statistics.count(at: .exhaustiveSearch), 0)
        XCTAssertFalse(a.statistics.relaxedConstraints)
        c.exhaustiveCellLimit = 5
        let b = try GreedyAssigner(configuration: c).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertEqual(b.statistics.count(at: .exhaustiveSearch), 0)
        XCTAssertGreaterThan(b.statistics.relaxationCount, 5)
    }

    func testSeedDerivationSequenceIsDistinct() {
        var seeds: Set<UInt64> = [0]
        var s: UInt64 = 0
        for _ in 0..<1000 {
            s = MosaicSeed.next(after: s)
            XCTAssertFalse(seeds.contains(s))
            seeds.insert(s)
        }
        XCTAssertEqual(AssignmentConfiguration(seed: 1).withSeed(9).seed, 9)
        XCTAssertEqual(AssignmentConfiguration(k: 7, seed: 1).withSeed(9).k, 7)
    }

    // MARK: - 多来源并集

    func testMultipleSourcesUnionAndDedupe() throws {
        // 两个相簿有重叠照片（行 40..<60 同时在两个相簿里）。
        let albumA = Array(0..<60)
        let albumB = Array(40..<120) + [45, 50] // 自身重复也去重
        let mask = try BitMask(count: 500, sources: [albumA, albumB])
        XCTAssertEqual(mask.setCount, 120)
        let viaMasks = try BitMask.union([BitMask(count: 500, setIndices: albumA), BitMask(count: 500, setIndices: albumB)], count: 500)
        XCTAssertEqual(viaMasks, mask)
        XCTAssertEqual(try BitMask.union([], count: 500).setCount, 0)
        XCTAssertThrowsError(try BitMask.union([BitMask(count: 3)], count: 500))
        XCTAssertThrowsError(try BitMask(count: 10, sources: [[10]]))

        let lib = FeatureMatrix(vectors: syntheticVectors(count: 500, seed: 6))
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: FeatureMatrix(vectors: syntheticVectors(count: 100, seed: 7)), library: lib, mask: mask)
        XCTAssertEqual(a.statistics.availableCandidates, 120) // 重叠只算一次
        XCTAssertTrue(a.tiles.allSatisfy { $0 < 120 })
        XCTAssertEqual(neighborhoodViolations(a, .eight), 0)
    }
}
