// 由 QA 骨架 qa/examples/ConstrainedMatchingTests.swift 移植而来（用例 A-11 … A-17），
// 已改用 MosaicCore 实际 API 并可在 Linux 编译运行。API 对照见仓库 CHANGES.md「QA 骨架对齐」。
import XCTest
@testable import MosaicCore

final class ConstrainedMatchingTests: XCTestCase {

    // MARK: - 可复现性（A-16 / A-17）

    func testSameSeedSameInputYieldsIdenticalAssignment() throws {
        let fixture = SyntheticFixture.diverseGrid(columns: 16, rows: 12, candidateCount: 400)
        let constraints = AssignmentConfiguration(seed: 0xA11CE5EED)
        let first = try fixture.assign(constraints)
        let second = try fixture.assign(constraints)
        XCTAssertEqual(first.tiles, second.tiles, "同种子同输入必须得到同一套格子分配")
        XCTAssertEqual(first.statistics.relaxationCount, second.statistics.relaxationCount)
    }

    func testDifferentSeedsChangePRNGSequence() throws {
        var a = SplitMix64(seed: 1)
        var b = SplitMix64(seed: 2)
        let seqA = (0..<32).map { _ in a.next() }
        let seqB = (0..<32).map { _ in b.next() }
        XCTAssertNotEqual(seqA, seqB, "不同种子不应产生同一段 SplitMix64 序列")
        var again = SplitMix64(seed: 1)
        XCTAssertEqual(seqA, (0..<32).map { _ in again.next() }, "同一种子的 PRNG 序列必须可复现")

        let fixture = SyntheticFixture.diverseGrid(columns: 16, rows: 12, candidateCount: 400)
        let left = try fixture.assign(AssignmentConfiguration(seed: 11))
        let right = try fixture.assign(AssignmentConfiguration(seed: 19))
        XCTAssertEqual(left.tiles.count, fixture.cellCount)
        // 本夹具是确定的，已验证两种子结果不同；保留 QA 的意图（换种子应看出差异）。
        XCTAssertNotEqual(left.tiles, right.tiles)
    }

    // MARK: - 防重复与上限（A-13 / A-14）

    func testEightNeighborhoodHasNoDuplicateWhenSupplyIsAmple() throws {
        let fixture = SyntheticFixture.diverseGrid(columns: 20, rows: 15, candidateCount: 800)
        let assignment = try fixture.assign(AssignmentConfiguration(seed: 42))
        XCTAssertEqual(assignment.tiles.count, fixture.cellCount)
        let violations = NeighborInvariant.duplicateNeighbors(indices: assignment.tiles, columns: fixture.columns, rows: fixture.rows, radius: 1)
        XCTAssertTrue(violations.isEmpty, "8 邻域出现重复：\(violations.prefix(8))")
        XCTAssertEqual(assignment.statistics.relaxationCount, 0)
    }

    func testUsageNeverExceedsCapAndDefaultFormula() throws {
        XCTAssertEqual(AssignmentConfiguration.defaultCap(cellCount: 10, availableCount: 10), 2)
        XCTAssertEqual(AssignmentConfiguration.defaultCap(cellCount: 1200, availableCount: 400), 6)
        XCTAssertEqual(AssignmentConfiguration.defaultCap(cellCount: 100, availableCount: 1000), 1)

        let fixture = SyntheticFixture.diverseGrid(columns: 20, rows: 15, candidateCount: 200)
        let assignment = try fixture.assign(AssignmentConfiguration(cap: .limited(2), seed: 7))
        var usage: [Int: Int] = [:]
        for t in assignment.tiles { usage[t, default: 0] += 1 }
        for (index, count) in usage {
            XCTAssertLessThanOrEqual(count, 2, "素材 \(index) 使用了 \(count) 次，超过 cap=2")
        }
    }

    // MARK: - 掩码与并列平局（A-11 / A-12）

    func testBitMaskExcludesCandidatesFromTopKAndAssignment() throws {
        let fixture = SyntheticFixture.diverseGrid(columns: 8, rows: 6, candidateCount: 64)
        var mask = BitMask(count: fixture.candidateCount, allSet: true)
        for i in fixture.candidateCount / 2 ..< fixture.candidateCount { mask[i] = false }

        let topK = try ScalarSIMDKernel().topK(queries: fixture.queries, candidates: fixture.candidates, k: 32, mask: mask)
        XCTAssertFalse(topK.indices.contains { $0 >= UInt32(fixture.candidateCount / 2) }, "被掩码关掉的候选不应出现在 top-k")

        let assignment = try fixture.assign(AssignmentConfiguration(seed: 3), mask: mask)
        XCTAssertFalse(assignment.tiles.contains { $0 >= fixture.candidateCount / 2 }, "被掩码关掉的候选不应被分配到格子")
    }

    func testEqualDistanceTiesBreakByAscendingIndex() throws {
        let query = [Float](repeating: 0.25, count: 12)
        let candidates = [Float](repeating: 0.25, count: 36) // 3 个完全相同的候选（SoA 12×3）
        let result = query.withUnsafeBufferPointer { q in
            candidates.withUnsafeBufferPointer { c in
                ScalarSIMDKernel().topK(queries: q, m: 1, candidates: c, n: 3, dims: 12, k: 3, mask: nil)
            }
        }
        XCTAssertEqual(Array(result.indices.prefix(3)), [0, 1, 2], "距离并列时必须按索引升序")
    }

    // MARK: - 回退链（A-15）

    func testFallbackChainCountsMaterialShortageAndFillsAllCells() throws {
        let fixture = SyntheticFixture.nearDuplicateCandidates(columns: 8, rows: 6, candidateCount: 4)
        let assignment = try fixture.assign(AssignmentConfiguration(cap: .limited(1), seed: 99))
        XCTAssertEqual(assignment.tiles.count, fixture.cellCount, "回退后仍须填满全部格子，且不崩溃")
        XCTAssertGreaterThan(assignment.statistics.relaxationCount, 0, "应计数放宽次数，供结果页短版提示")
        XCTAssertTrue(assignment.statistics.relaxedConstraints)
        XCTAssertTrue(assignment.statistics.needsRepetition)
    }
}

// MARK: - 不变量与夹具

/// 指定半径的 Chebyshev 邻域重复检查（不依赖 MosaicCore 的邻域实现，独立对拍）。
enum NeighborInvariant {
    struct Hit: CustomStringConvertible {
        let cell: Int
        let neighbor: Int
        let asset: Int
        var description: String { "cell \(cell) 与邻格 \(neighbor) 都使用了 \(asset)" }
    }

    static func duplicateNeighbors(indices: [Int], columns: Int, rows: Int, radius: Int) -> [Hit] {
        var hits: [Hit] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let i = r * columns + c
                for dr in -radius...radius {
                    for dc in -radius...radius where !(dr == 0 && dc == 0) {
                        let rr = r + dr, cc = c + dc
                        guard rr >= 0, rr < rows, cc >= 0, cc < columns else { continue }
                        let j = rr * columns + cc
                        if j > i, indices[i] == indices[j] { hits.append(Hit(cell: i, neighbor: j, asset: indices[i])) }
                    }
                }
            }
        }
        return hits
    }
}

/// QA 骨架中的合成夹具，按其注释实现。
struct SyntheticFixture {
    let columns: Int
    let rows: Int
    let queries: FeatureMatrix
    let candidates: FeatureMatrix
    var cellCount: Int { columns * rows }
    var candidateCount: Int { candidates.count }

    /// 候选彼此可分（确定性扰动）；query 取自平滑渐变。
    static func diverseGrid(columns: Int, rows: Int, candidateCount: Int) -> SyntheticFixture {
        var qs: [FeatureVector] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let l = Float(c) / Float(max(1, columns - 1))
                let a = (Float(r) / Float(max(1, rows - 1)) - 0.5) * 0.3
                qs.append(FeatureVector(blocks: [SIMD3(l, a, 0), SIMD3(l, a, 0.02), SIMD3(l, a, -0.02), SIMD3(l, a, 0)]))
            }
        }
        return SyntheticFixture(columns: columns, rows: rows, queries: FeatureMatrix(vectors: qs),
                                candidates: FeatureMatrix(vectors: syntheticVectors(count: candidateCount, seed: 0xF1)))
    }

    /// 少量几乎相同的候选，用于触发回退链。
    static func nearDuplicateCandidates(columns: Int, rows: Int, candidateCount: Int) -> SyntheticFixture {
        let base = diverseGrid(columns: columns, rows: rows, candidateCount: 1)
        let vs = (0..<candidateCount).map { FeatureVector(uniform: SIMD3(0.5 + Float($0) * 1e-4, 0, 0)) }
        return SyntheticFixture(columns: columns, rows: rows, queries: base.queries, candidates: FeatureMatrix(vectors: vs))
    }

    func assign(_ config: AssignmentConfiguration, mask: BitMask? = nil) throws -> MosaicAssignment {
        try GreedyAssigner(configuration: config)
            .assign(grid: MosaicGrid(columns: columns, rows: rows), cellFeatures: queries, library: candidates, mask: mask)
    }
}
