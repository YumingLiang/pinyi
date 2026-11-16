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

    /// 平滑渐变目标图：相邻格的 128 近邻高度重叠，上限 2 很快用尽。
    /// 方案原回退链（无全库搜索）会在素材充足（1500 张 ≥ 1200 格）时仍"忽略上限"并误报素材不足；
    /// 补充的全库搜索级别可避免。
    func testExhaustiveSearchAvoidsFalseShortage() throws {
        let (target, lib) = try fixture()
        var strict = AssignmentConfiguration(seed: 2026)
        strict.exhaustiveSearchBeforeRelaxing = false
        let withoutSearch = try MosaicPipeline(assigner: GreedyAssigner(configuration: strict))
            .generate(target: target, density: .coarse, library: lib)
        XCTAssertGreaterThan(withoutSearch.assignment.statistics.count(at: .capIgnored), 0)
        XCTAssertTrue(withoutSearch.assignment.statistics.relaxedConstraints)

        let withSearch = try MosaicPipeline(assigner: GreedyAssigner(configuration: AssignmentConfiguration(seed: 2026)))
            .generate(target: target, density: .coarse, library: lib)
        XCTAssertGreaterThan(withSearch.assignment.statistics.count(at: .exhaustiveSearch), 0)
        XCTAssertFalse(withSearch.assignment.statistics.relaxedConstraints)
        XCTAssertEqual(neighborhoodViolations(withSearch.assignment, .eight), 0)
        XCTAssertLessThanOrEqual(useCounts(withSearch.assignment, libraryCount: lib.count).max()!, 2)
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
