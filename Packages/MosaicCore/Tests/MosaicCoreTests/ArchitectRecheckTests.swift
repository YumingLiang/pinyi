import Dispatch
import Foundation
import XCTest
@testable import MosaicCore

/// 架构师复审 ca6a4ca（`reviews/mosaic-core-ca6a4ca.md`）的必须修 / 拍板补测 / 建议项。
final class ArchitectRecheckTests: XCTestCase {
    private let black = FeatureVector(uniform: SIMD3(0, 0, 0))
    private let white = FeatureVector(uniform: SIMD3(1, 0, 0))

    // MARK: MF-2：惩罚尺度为 0 时的退化

    /// 大片纯黑目标（> 一半格子）+ 库里有一张完全同色的纯黑图：旧实现 median = 0 ⇒ λ = μ = 0。
    /// 现在只在 top‑1 > 0 的格子上取中位数，λ_eff、μ_eff 都 > 0。
    func testMF2MostlyBlackTargetWithIdenticalBlackTileKeepsPenalties() throws {
        let grid = try MosaicGrid(columns: 20, rows: 15)                // 300 格
        let others = syntheticVectors(count: grid.cellCount, seed: 9)
        let cells = (0..<grid.cellCount).map { $0 % 5 < 3 ? black : others[$0] }   // 60% 纯黑
        let libVectors = [black, white] + syntheticVectors(count: 400, seed: 10)
        let variance: [Float] = [0, 0] + Array(repeating: 0.001, count: 400)
        let a = try GreedyAssigner(configuration: AssignmentConfiguration(seed: 2))
            .assign(grid: grid, cellFeatures: FeatureMatrix(vectors: cells), library: FeatureMatrix(vectors: libVectors),
                    mask: nil, lightnessVariance: variance, cancellation: nil, progress: nil)
        let st = a.statistics
        XCTAssertEqual(st.penaltyScaleSource, PenaltyScale.Source.top1Median)
        XCTAssertGreaterThan(st.penaltyScale, 0)
        XCTAssertEqual(st.top1MedianDistance, st.penaltyScale)
        XCTAssertEqual(st.effectiveUsagePenalty, 0.1 * st.penaltyScale, accuracy: 1e-9)
        XCTAssertEqual(st.effectiveLowDetailPenalty, 0.04 * st.penaltyScale, accuracy: 1e-9)
        XCTAssertGreaterThan(st.effectiveUsagePenalty, 0)
        XCTAssertGreaterThan(st.effectiveLowDetailPenalty, 0)
        // 与"正距离中位数"定义一致。
        let topK = try ScalarSIMDKernel().topK(queries: FeatureMatrix(vectors: cells), candidates: FeatureMatrix(vectors: libVectors), k: 32)
        let positives = (0..<topK.queryCount).map { topK.distances[$0 * topK.k] }.filter { $0 > 0 }.sorted()
        XCTAssertEqual(st.penaltyScale, positives[(positives.count - 1) / 2])
    }

    /// 全部格子 top‑1 都为 0（整张纯白 + 库里有纯白图）：退到第 k 名距离的下中位数。
    func testMF2AllZeroTop1FallsBackToKthMedian() throws {
        let grid = try MosaicGrid(columns: 12, rows: 10)
        let cells = FeatureMatrix(vectors: Array(repeating: white, count: grid.cellCount))
        let lib = FeatureMatrix(vectors: [white, black] + syntheticVectors(count: 200, seed: 11))
        let a = try GreedyAssigner(configuration: AssignmentConfiguration(seed: 1)).assign(grid: grid, cellFeatures: cells, library: lib)
        let st = a.statistics
        XCTAssertEqual(st.top1MedianDistance, 0)
        XCTAssertEqual(st.penaltyScaleSource, PenaltyScale.Source.kthMedian)
        let topK = try ScalarSIMDKernel().topK(queries: cells, candidates: lib, k: 32)
        let kth = (0..<topK.queryCount).map { topK.distances[$0 * 32 + 31] }.sorted()
        XCTAssertEqual(st.penaltyScale, kth[(kth.count - 1) / 2])
        XCTAssertGreaterThan(st.effectiveUsagePenalty, 0)
    }

    /// 全库与目标完全相同（距离全为 0）：用小常数兜底，λ_eff > 0，使用次数被均摊。
    func testMF2AllDistancesZeroUsesDegenerateConstant() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)                 // 100 格
        let cells = FeatureMatrix(vectors: Array(repeating: black, count: 100))
        let lib = FeatureMatrix(vectors: Array(repeating: black, count: 50))
        let a = try GreedyAssigner(configuration: AssignmentConfiguration(seed: 4)).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertEqual(a.statistics.penaltyScaleSource, PenaltyScale.Source.degenerateConstant)
        XCTAssertEqual(a.statistics.penaltyScale, TuningDefaults.degeneratePenaltyScale)
        XCTAssertEqual(a.statistics.effectiveUsagePenalty, 0.1 * TuningDefaults.degeneratePenaltyScale, accuracy: 1e-12)
        // 距离全相同 ⇒ 每格 top‑32 是同一批 32 张（按下标平局）。λ > 0 时在这 32 张里均摊（使用次数差 ≤ 1）。
        func spread(_ m: MosaicAssignment) -> Int {
            var uses: [Int: Int] = [:]
            for t in m.tiles { uses[t, default: 0] += 1 }
            return (uses.values.max() ?? 0) - (uses.values.min() ?? 0)
        }
        XCTAssertEqual(a.statistics.distinctTilesUsed, 32)
        XCTAssertLessThanOrEqual(spread(a), 1, "λ > 0 时均摊")
        let zero = try GreedyAssigner(configuration: AssignmentConfiguration(seed: 4).withAbsolutePenalties(usage: 0, lowDetail: 0))
            .assign(grid: grid, cellFeatures: cells, library: lib)
        // 对照（即 MF-2 修复前 λ = 0 的行为）：按下标把靠前的素材用满到上限，用到的张数更少。
        XCTAssertLessThan(zero.statistics.distinctTilesUsed, a.statistics.distinctTilesUsed)
        var bad = AssignmentConfiguration(); bad.degeneratePenaltyScale = 0
        XCTAssertThrowsError(try bad.validate())
    }

    /// 拍板 (3)：σ²_ref 与 `.lowDetail` 标志阈值同源，α/β 默认值集中在 `TuningDefaults`。
    func testTuningDefaultsSingleSource() {
        let c = AssignmentConfiguration()
        XCTAssertEqual(c.usagePenaltyRelative, TuningDefaults.usagePenaltyRelative)
        XCTAssertEqual(c.lowDetailPenaltyRelative, TuningDefaults.lowDetailPenaltyRelative)
        XCTAssertEqual(c.lowDetailVarianceReference, TuningDefaults.lowDetailVarianceReference)
        XCTAssertEqual(FeatureExtractor().lowDetailVarianceThreshold, c.lowDetailVarianceReference)
        XCTAssertEqual(TuningDefaults.usagePenaltyRelative, 0.1)
        XCTAssertEqual(TuningDefaults.lowDetailPenaltyRelative, 0.04)
        XCTAssertEqual(TuningDefaults.lowDetailVarianceReference, 0.0004)
    }

    // MARK: T-2（探针 P5）：带方差、非 2 的幂缩放时分配不变

    func testM3ScaleInvarianceWithVarianceAndNonPowerOfTwoFactors() throws {
        let grid = try MosaicGrid(columns: 24, rows: 18)
        let lib = syntheticVectors(count: 300, seed: 41)
        let cells = syntheticVectors(count: grid.cellCount, seed: 42)
        var rng = Xoshiro256StarStar(seed: 77)
        let variance: [Float] = (0..<300).map { _ in Float(rng.nextBounded(1000)) * 1e-6 }   // 0…0.001，跨过 σ²_ref
        func scaled(_ v: [FeatureVector], _ c: Float) -> FeatureMatrix {
            FeatureMatrix(vectors: v.map { FeatureVector($0.components.map { $0 * c }) })
        }
        let config = AssignmentConfiguration(seed: 3)
        func run(_ c: Float) throws -> MosaicAssignment {
            try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: scaled(cells, c), library: scaled(lib, c),
                                                            mask: nil, lightnessVariance: variance, cancellation: nil, progress: nil)
        }
        let base = try run(1)
        XCTAssertGreaterThan(base.statistics.effectiveLowDetailPenalty, 0)
        for c: Float in [4, 3, 1.7, 0.3, 10] {
            XCTAssertEqual(try run(c).tiles, base.tiles, "scale \(c)")
        }
    }

    // MARK: 拍板 (1) / S-6：最小超额路径同种子重跑一致

    func testMinimalOverflowPathIsReproducible() throws {
        let grid = try MosaicGrid(columns: 30, rows: 20)
        let cells = FeatureMatrix(vectors: Array(repeating: FeatureVector(uniform: SIMD3(0.6, 0.02, 0.05)), count: 600))
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 3000, seed: 5))
        var c = AssignmentConfiguration(seed: 1, batchDepths: [100], exhaustiveCellLimit: 0)
        c.cap = .limited(1)
        let a = try GreedyAssigner(configuration: c).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertGreaterThan(a.statistics.count(at: .capIgnored), 0, "确实走到最小超额路径")
        XCTAssertEqual(try GreedyAssigner(configuration: c).assign(grid: grid, cellFeatures: cells, library: lib), a)
        // 不同分块 / 分组下也一致。
        var g = c; g.batchQueryGroupSize = 7
        XCTAssertEqual(try GreedyAssigner(configuration: g, kernel: ScalarSIMDKernel(queryBlockSize: 3, candidateTileSize: 777)).assign(grid: grid, cellFeatures: cells, library: lib).tiles, a.tiles)
    }

    // MARK: T-1（探针 P4）：在批量加深阶段取消，同种子重跑逐格一致

    func testCancelDuringBatchDeepeningThenRerunIsIdentical() throws {
        let grid = try MosaicGrid(columns: 30, rows: 20)
        let cells = FeatureMatrix(vectors: Array(repeating: FeatureVector(uniform: SIMD3(0.6, 0.02, 0.05)), count: 600))
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 5000, seed: 5))
        var c = AssignmentConfiguration(seed: 6); c.cap = .limited(1)
        let baseline = try GreedyAssigner(configuration: c).assign(grid: grid, cellFeatures: cells, library: lib)
        let mainRound = baseline.statistics.count(at: .primary) + baseline.statistics.count(at: .expandedCandidates)
        XCTAssertGreaterThan(baseline.statistics.count(at: .batchDeepened), 64, "夹具确实有批量加深")
        let token = CancellationToken()
        let cancelledAt = Box<Int>(-1)
        XCTAssertThrowsError(try GreedyAssigner(configuration: c).assign(grid: grid, cellFeatures: cells, library: lib, mask: nil,
                                                                         lightnessVariance: nil, cancellation: token) { p in
            if p.phase == .assigning, p.completed > mainRound, !token.isCancelled {
                cancelledAt.mutate { $0 = p.completed }
                token.cancel()
            }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThan(cancelledAt.value, mainRound, "取消发生在主轮之后（批量加深阶段）")
        XCTAssertEqual(try GreedyAssigner(configuration: c).assign(grid: grid, cellFeatures: cells, library: lib), baseline)
    }

    // MARK: S-1 / 拍板 (4)：叠加时两图颜色空间不一致先转 sRGB

    func testOverlayConvertsMismatchedColorSpaces() throws {
        let tileBytes: [UInt8] = Array(repeating: [30, 160, 220, 255], count: 4).flatMap { $0 }
        let targetBytes: [UInt8] = Array(repeating: [230, 40, 20, 255], count: 4).flatMap { $0 }
        let tile = try PixelBuffer(width: 2, height: 2, bytes: tileBytes)
        let targetP3 = try PixelBuffer(width: 2, height: 2, colorSpace: .displayP3, bytes: targetBytes)
        let out = try OverlayBlend.blend(tile: tile, target: targetP3, alpha: 0.3)
        let expected = try OverlayBlend.blend(tile: tile, target: targetP3.convertedToSRGB(), alpha: 0.3)
        XCTAssertEqual(out.bytes, expected.bytes)
        XCTAssertEqual(out.colorSpace, .sRGB)
        let naive = try OverlayBlend.blend(tile: tile, target: try PixelBuffer(width: 2, height: 2, bytes: targetBytes), alpha: 0.3)
        XCTAssertNotEqual(out.bytes, naive.bytes, "P3 编码值不能直接当 sRGB 混合")
        // 两张都是 P3 时按 P3 编码值混合，结果仍标 P3。
        let tileP3 = try PixelBuffer(width: 2, height: 2, colorSpace: .displayP3, bytes: tileBytes)
        XCTAssertEqual(try OverlayBlend.blend(tile: tileP3, target: targetP3, alpha: 0.3).colorSpace, .displayP3)
    }

    // MARK: S-4：snapshot 版 async 入口、reshuffle 不丢方差

    func testSnapshotAsyncAndReshuffleKeepVariance() async throws {
        let img = try gradientImage(width: 160, height: 120)
        var rng = Xoshiro256StarStar(seed: 5)
        let records = syntheticVectors(count: 1500, seed: 5).map {
            FeatureRecord(vector: $0, lightnessVariance: Float(rng.nextBounded(800)) * 1e-6)
        }
        let table = FeatureTable(records: records)
        let snap = try LibrarySnapshot(table: table)
        let pipeline = MosaicPipeline()
        let sync = try pipeline.generate(target: img, density: .medium, snapshot: snap, seed: 9, cancellation: nil)
        let async = try await pipeline.generate(target: img, density: .medium, snapshot: snap, seed: 9)
        XCTAssertEqual(async, sync)
        XCTAssertGreaterThan(sync.assignment.statistics.effectiveLowDetailPenalty, 0)
        let next = try pipeline.reshuffle(sync, target: img, snapshot: snap, cancellation: nil)
        XCTAssertEqual(next.seed, MosaicSeed.next(after: 9))
        let direct = try pipeline.generate(target: img, density: .medium, snapshot: snap, seed: next.seed, cancellation: nil)
        XCTAssertEqual(next, direct)
        let nextAsync = try await pipeline.reshuffle(sync, target: img, snapshot: snap)
        XCTAssertEqual(nextAsync, next)
        // FeatureMatrix 版 reshuffle 传同一份方差时与快照版一致；不传则口径不同（λ 相同但 μ = 0）。
        let viaMatrix = try pipeline.reshuffle(sync, target: img, library: table.matrix, lightnessVariance: table.lightnessVariance)
        XCTAssertEqual(viaMatrix.assignment, next.assignment)
        let noVariance = try pipeline.reshuffle(sync, target: img, library: table.matrix)
        XCTAssertEqual(noVariance.assignment.statistics.effectiveLowDetailPenalty, 0)
    }

    // MARK: S-7 / 拍板 (5)：真实 v1 文件 → v2 引擎

    /// 由 d6ef584（`featureVersion` = 1）的 `FeatureFile.encode` 生成的 3 条记录文件（248 字节，原样保存）。
    /// 生成方式：在 d6ef584 的 worktree 里对
    /// `FeatureTable(records: (0..<3).map { FeatureRecord(vector: .init(uniform: SIMD3(0.25·i + 0.1, 0.01·i, −0.02)), lightnessVariance: 0.0005·(i+1)) })`
    /// 调 `FeatureFile.encode` 后 base64。
    static let v1FixtureBase64 = "UE1GRUFUAAABAEAAAQAAAAwAAAADAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgxwEIAAAAAM3MzD0zM7M+mpkZPwAAAAAK1yM8CtejPArXo7wK16O8CtejvM3MzD0zM7M+mpkZPwAAAAAK1yM8CtejPArXo7wK16O8CtejvM3MzD0zM7M+mpkZPwAAAAAK1yM8CtejPArXo7wK16O8CtejvM3MzD0zM7M+mpkZPwAAAAAK1yM8CtejPArXo7wK16O8CtejvG8SAzpvEoM6ppvEOgAAgD8AAIA/AACAPwAAAAAAAAAAAAAAAApkyLw="

    func testRealV1FileIsDiscardedAndRebuilt() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.v1FixtureBase64))
        XCTAssertEqual(data.count, 64 + 3 * 60 + 4)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v1fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("features.bin")
        try data.write(to: url)
        // 头部本身合法（CRC 正确），只有特征版本过期。
        let header = try FeatureFile.readHeader(from: url)
        XCTAssertEqual(header.featureVersion, 1)
        XCTAssertEqual(header.recordCount, 3)
        for mode in [FeatureFileRecovery.keepValidPrefix, .discardAndRebuild] {
            XCTAssertThrowsError(try FeatureFile.read(from: url, recovery: mode)) { e in
                XCTAssertEqual(e as? FeatureFileError, .featureVersionMismatch(found: 1, expected: MosaicCoreInfo.featureVersion))
                XCTAssertEqual((e as? FeatureFileError)?.recommendedRecovery, .discardAndRebuild)
            }
        }
        // 显式按 v1 读取时数据完好（证明 fixture 确实是旧写入器的合法输出，而不是坏文件）。
        let old = try FeatureFile.read(from: url, expectedSpec: FeatureSpec(featureVersion: 1))
        XCTAssertEqual(old.table.count, 3)
        XCTAssertEqual(old.table.lightnessVariance[2], 0.0015, accuracy: 1e-9)
    }

    // MARK: S-2：进度回调不在计数锁内，慢回调不拖住工作线程，仍单调且最终 = total

    func testSlowProgressCallbackStaysMonotonicAndCompletes() throws {
        let queries = FeatureMatrix(vectors: syntheticVectors(count: 640, seed: 1))
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 4000, seed: 2))
        let seen = Box<[Int]>([])
        let total = Box<Int>(0)
        let r = try ScalarSIMDKernel().topK(queries: queries, candidates: lib, k: 8, mask: nil, cancellation: nil) { done, t in
            seen.mutate { $0.append(done) }
            total.mutate { $0 = t }
            usleep(2_000)
        }
        XCTAssertEqual(r, try ScalarSIMDKernel().topK(queries: queries, candidates: lib, k: 8))
        XCTAssertEqual(seen.value, seen.value.sorted())
        XCTAssertEqual(Set(seen.value).count, seen.value.count, "不重复上报")
        XCTAssertEqual(seen.value.last, total.value)
    }
}
