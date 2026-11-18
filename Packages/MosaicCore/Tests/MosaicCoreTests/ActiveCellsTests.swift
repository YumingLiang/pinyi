import Foundation
import XCTest
@testable import MosaicCore

/// 形状 / 文字拼图：格子掩码 `activeCells`（设计 shape-mosaic-v0.1 §5，架构师 S2 接口 1、2）。
final class ActiveCellsTests: XCTestCase {
    // MARK: - 夹具

    private func cells(_ grid: MosaicGrid, seed: UInt64) -> FeatureMatrix {
        FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: seed))
    }

    private func gradientTarget(width: Int = 64, height: Int = 48) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                bytes[o] = UInt8((x * 4) & 255)
                bytes[o + 1] = UInt8((y * 5) & 255)
                bytes[o + 2] = UInt8(((x + y) * 2) & 255)
            }
        }
        return try PixelBuffer(width: width, height: height, bytes: bytes)
    }

    private func table(_ n: Int, seed: UInt64) -> FeatureTable {
        let records = syntheticVectors(count: n, seed: seed).enumerated().map { i, v in
            FeatureRecord(vector: v, lightnessVariance: Float(i % 7) * 0.0002, aspectRatio: 1)
        }
        return FeatureTable(records: records)
    }

    /// 中心椭圆形「形状」。
    private func ellipse(_ grid: MosaicGrid) -> CellMask {
        let cx = Double(grid.columns) / 2, cy = Double(grid.rows) / 2
        return CellMask(grid: grid) { c, r in
            let dx = (Double(c) + 0.5 - cx) / cx
            let dy = (Double(r) + 0.5 - cy) / cy
            return dx * dx + dy * dy <= 0.8
        }
    }

    private func digest(_ a: MosaicAssignment) -> UInt64 { NilPathDigestTests.digest(a) }

    // MARK: - nil 回归
    // 跨提交逐位金标准（只在 x86_64 Linux 上比）见 `NilPathDigestTests`；下面两条在所有平台都断言。

    /// 显式传 nil、以及全 1 掩码，都与不传完全相同。
    func testExplicitNilAndAllActiveMaskEqualDefault() throws {
        let grid = try MosaicGrid(columns: 40, rows: 30)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 300, seed: 3))
        let assigner = GreedyAssigner(configuration: AssignmentConfiguration(seed: 42))
        let f = cells(grid, seed: 4)
        let base = try assigner.assign(grid: grid, cellFeatures: f, library: lib)
        let explicitNil = try assigner.assign(grid: grid, cellFeatures: f, library: lib, mask: nil, lightnessVariance: nil,
                                              cancellation: nil, progress: nil, activeCells: nil)
        let all = try assigner.assign(grid: grid, cellFeatures: f, library: lib, mask: nil, lightnessVariance: nil,
                                      cancellation: nil, progress: nil,
                                      activeCells: CellMask(columns: 40, rows: 30, allActive: true))
        XCTAssertEqual(explicitNil, base)
        XCTAssertEqual(all, base)
    }

    /// 流水线：传 nil 与传全 1 掩码结果完全相同（所有平台）；摘要打印到日志，便于各平台对照。
    func testPipelineNilAndAllActiveMaskAreIdentical() throws {
        let snap = try LibrarySnapshot(table: table(500, seed: 11))
        let target = try gradientTarget()
        let pipe = MosaicPipeline()
        let layout = try Layout.grid(width: target.width, height: target.height, density: .coarse)
        let none = try pipe.generate(target: target, density: .coarse, snapshot: snap, seed: 7)
        let explicitNil = try pipe.generate(target: target, density: .coarse, snapshot: snap, seed: 7, activeCells: nil)
        let allMask = try CellMask(columns: layout.grid.columns, rows: layout.grid.rows, allActive: true)
        let all = try pipe.generate(target: target, density: .coarse, snapshot: snap, seed: 7, activeCells: allMask)
        print("PIPELINE-DIGEST platform=\(NilPathDigestTests.platform) nil=\(digest(none.assignment)) allActive=\(digest(all.assignment))")
        XCTAssertNil(none.activeCells)
        XCTAssertEqual(explicitNil.assignment, none.assignment)
        XCTAssertEqual(all.assignment, none.assignment)
        XCTAssertEqual(digest(all.assignment), digest(none.assignment))
        XCTAssertEqual(all.assignment.statistics.cellCount, layout.cellCount)
    }

    // MARK: - 掩码内外

    func testOnlyActiveCellsGetTilesAndStatsCountActiveOnly() throws {
        let grid = try MosaicGrid(columns: 40, rows: 30)
        let mask = ellipse(grid)
        let active = mask.activeCount
        XCTAssertGreaterThan(active, 400)
        XCTAssertLessThan(active, 1200)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 300, seed: 3))
        let a = try GreedyAssigner(configuration: AssignmentConfiguration(seed: 42))
            .assign(grid: grid, cellFeatures: cells(grid, seed: 4), library: lib, mask: nil, lightnessVariance: nil,
                    cancellation: nil, progress: nil, activeCells: mask)
        for i in 0..<grid.cellCount {
            if mask.isActive(i) {
                XCTAssertGreaterThanOrEqual(a.tiles[i], 0, "形状内格 \(i) 必须有照片")
            } else {
                XCTAssertEqual(a.tiles[i], -1, "形状外格 \(i) 不分配照片")
                XCTAssertEqual(a.distances[i], 0)
            }
        }
        XCTAssertEqual(a.statistics.cellCount, active)
        XCTAssertEqual(a.statistics.levelCounts.reduce(0, +), active)
        // 上限按形状内格数：ceil(active / 300 × 2)。
        let expectedCap = Int((Double(active) / 300 * 2).rounded(.up))
        XCTAssertEqual(a.statistics.resolvedCap, expectedCap)
        var uses = [Int](repeating: 0, count: 300)
        for t in a.tiles where t >= 0 { uses[t] += 1 }
        XCTAssertEqual(uses.reduce(0, +), active, "照片配额只算形状内格子")
        XCTAssertLessThanOrEqual(uses.max() ?? 0, expectedCap)
        XCTAssertEqual(a.statistics.distinctTilesUsed, uses.filter { $0 > 0 }.count)
        // 形状内相邻不重复（-1 不算）。
        var violations = 0
        for i in 0..<grid.cellCount where a.tiles[i] >= 0 {
            for j in grid.neighbors(of: i, in: .eight) where j > i && a.tiles[j] == a.tiles[i] { violations += 1 }
        }
        XCTAssertEqual(violations, 0)
    }

    /// 形状外格子不进 top‑k 查询：内核只收到形状内的格子。
    func testKernelOnlySeesActiveCells() throws {
        let grid = try MosaicGrid(columns: 20, rows: 16)
        let mask = ellipse(grid)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 2000, seed: 5))
        let kernel = CountingKernel()
        _ = try GreedyAssigner(configuration: AssignmentConfiguration(seed: 1), kernel: kernel)
            .assign(grid: grid, cellFeatures: cells(grid, seed: 6), library: lib, mask: nil, lightnessVariance: nil,
                    cancellation: nil, progress: nil, activeCells: mask)
        XCTAssertEqual(kernel.queryCounts.first, mask.activeCount)
        XCTAssertEqual(kernel.queryCounts.reduce(0, +), mask.activeCount, "素材充足时只有首轮查询")
    }

    /// 同种子同掩码结果稳定；换种子顺序变化。
    func testSameSeedStableWithMask() throws {
        let grid = try MosaicGrid(columns: 40, rows: 30)
        let mask = ellipse(grid)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 300, seed: 3))
        let f = cells(grid, seed: 4)
        func run(_ seed: UInt64) throws -> MosaicAssignment {
            try GreedyAssigner(configuration: AssignmentConfiguration(seed: seed))
                .assign(grid: grid, cellFeatures: f, library: lib, mask: nil, lightnessVariance: nil,
                        cancellation: nil, progress: nil, activeCells: mask)
        }
        XCTAssertEqual(try run(9), try run(9))
        XCTAssertNotEqual(try run(9).tiles, try run(10).tiles)
    }

    func testMaskSizeMismatchThrows() throws {
        let grid = try MosaicGrid(columns: 10, rows: 8)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 50, seed: 3))
        let wrong = try CellMask(columns: 8, rows: 10, allActive: true)
        XCTAssertThrowsError(try GreedyAssigner().assign(grid: grid, cellFeatures: cells(grid, seed: 1), library: lib, mask: nil,
                                                         lightnessVariance: nil, cancellation: nil, progress: nil,
                                                         activeCells: wrong)) { e in
            XCTAssertEqual(e as? MosaicError, .countMismatch(expected: 80, actual: 80))
        }
        let snap = try LibrarySnapshot(table: table(100, seed: 2))
        let wrongForPipeline = try CellMask(columns: 39, rows: 30, allActive: true)
        XCTAssertThrowsError(try MosaicPipeline().generate(target: gradientTarget(), density: .coarse, snapshot: snap,
                                                           activeCells: wrongForPipeline))
    }

    func testEmptyMaskGivesNoTilesWithoutThrowing() throws {
        let grid = try MosaicGrid(columns: 10, rows: 8)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 50, seed: 3))
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: cells(grid, seed: 1), library: lib, mask: nil,
                                            lightnessVariance: nil, cancellation: nil, progress: nil,
                                            activeCells: CellMask(columns: 10, rows: 8, allActive: false))
        XCTAssertEqual(a.tiles, [Int](repeating: -1, count: 80))
        XCTAssertEqual(a.statistics.cellCount, 0)
    }

    // MARK: - 流水线 / 换一种拼法 / 补格

    func testPipelineCarriesMaskThroughReshuffleAndRefillSkipsOutside() throws {
        let snap = try LibrarySnapshot(table: table(400, seed: 12))
        let target = try gradientTarget()
        let pipe = MosaicPipeline()
        let layout = try Layout.grid(width: target.width, height: target.height, density: .coarse)
        let mask = ellipse(layout.grid)
        let g = try pipe.generate(target: target, density: .coarse, snapshot: snap, seed: 3, activeCells: mask)
        XCTAssertEqual(g.activeCells, mask)
        XCTAssertEqual(g.assignment.tiles.filter { $0 < 0 }.count, layout.cellCount - mask.activeCount)
        // 设计 v0.1.1 §3：形状模式下统计里的 cellCount = 形状内格数（不是整张网格）。
        XCTAssertEqual(g.assignment.statistics.cellCount, mask.activeCount)
        XCTAssertLessThan(mask.activeCount, layout.cellCount)

        let r = try pipe.reshuffle(g, target: target, snapshot: snap)
        XCTAssertEqual(r.activeCells, mask, "换一种拼法沿用同一掩码")
        XCTAssertEqual(r.assignment.statistics.cellCount, mask.activeCount)
        for i in 0..<layout.cellCount { XCTAssertEqual(r.assignment.tiles[i] < 0, !mask.isActive(i)) }

        let outside = (0..<layout.cellCount).filter { !mask.isActive($0) }
        let inside = (0..<layout.cellCount).filter { mask.isActive($0) }
        let allowed = BitMask(count: 400, setIndices: [5, 9])
        let f = try pipe.refill(g, target: target, snapshot: snap, cells: outside + [inside[0]], allowed: allowed)
        for c in outside { XCTAssertEqual(f.assignment.tiles[c], -1, "补格不碰形状外") }
        XCTAssertTrue([5, 9].contains(f.assignment.tiles[inside[0]]))
        XCTAssertEqual(f.activeCells, mask)
        XCTAssertEqual(f.assignment.statistics.cellCount, mask.activeCount)
        XCTAssertEqual(f.assignment.statistics.levelCounts.reduce(0, +), mask.activeCount)
    }

    // MARK: - bits-v1

    func testBitsV1RoundTripAndLayout() throws {
        let grid = try MosaicGrid(columns: 5, rows: 3) // 15 位 → 2 字节
        let mask = CellMask(grid: grid) { c, r in (c + r) % 3 == 0 }
        let bytes = mask.bitsV1Bytes
        XCTAssertEqual(bytes.count, 2)
        // 第 0 格 (0,0) 置 1 → 第 0 字节最低位。
        XCTAssertEqual(bytes[0] & 1, 1)
        XCTAssertEqual(try CellMask(columns: 5, rows: 3, bitsV1: bytes), mask)
        XCTAssertThrowsError(try CellMask(columns: 5, rows: 3, bitsV1: [0]))
        XCTAssertThrowsError(try CellMask(columns: 5, rows: 3, bitsV1: [0, 0x80]), "补齐位必须为 0")

        let big = CellMask(grid: try MosaicGrid(columns: 120, rows: 104)) { c, r in (c * 7 + r * 3) % 5 < 2 }
        XCTAssertEqual(big.bitsV1Bytes.count, 1560)
        XCTAssertEqual(try CellMask(columns: 120, rows: 104, bitsV1: big.bitsV1Bytes), big)
        XCTAssertEqual(big.activeIndices.count, big.activeCount)
        XCTAssertTrue(big.activeIndices.allSatisfy { big.isActive($0) })
    }
}

/// 记录每次 top‑k 查询行数的内核（包一层 ScalarSIMDKernel）。
private final class CountingKernel: DistanceKernel, @unchecked Sendable {
    private let inner = ScalarSIMDKernel()
    private let lock = NSLock()
    private var counts: [Int] = []
    var queryCounts: [Int] { lock.lock(); defer { lock.unlock() }; return counts }

    func topK(queries: UnsafeBufferPointer<Float>, m: Int, candidates: UnsafeBufferPointer<Float>, n: Int,
              dims: Int, k: Int, mask: BitMask?) -> TopKResult {
        record(m)
        return inner.topK(queries: queries, m: m, candidates: candidates, n: n, dims: dims, k: k, mask: mask)
    }

    func topK(queries: UnsafeBufferPointer<Float>, m: Int, candidates: UnsafeBufferPointer<Float>, n: Int,
              dims: Int, k: Int, mask: BitMask?, cancellation: CancellationToken?,
              progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) throws -> TopKResult {
        record(m)
        return try inner.topK(queries: queries, m: m, candidates: candidates, n: n, dims: dims, k: k, mask: mask,
                              cancellation: cancellation, progress: progress)
    }

    private func record(_ m: Int) { lock.lock(); counts.append(m); lock.unlock() }
}
