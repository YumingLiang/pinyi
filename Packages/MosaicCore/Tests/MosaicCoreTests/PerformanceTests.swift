import Foundation
import XCTest
@testable import MosaicCore

/// 性能基线（技术方案 §7：`measure {}`）。
/// 默认规模较小以免拖慢 CI；设置环境变量 `MOSAIC_BENCH=1` 并用
/// `swift test -c release --filter PerformanceTests` 跑方案中的全规模（10,800 格 × 50,000 素材）。
final class PerformanceTests: XCTestCase {
    private var fullScale: Bool { ProcessInfo.processInfo.environment["MOSAIC_BENCH"] == "1" }
    /// 软阈值默认**只打印警告**（CI 的 runner 核数与 box 不同，只记录不阻断）；
    /// 设 `MOSAIC_BENCH_ASSERT=1` 才变成断言（本地 / 固定硬件上用）。
    /// ⚠️ Linux 耗时不能作为 iPhone 11 性能退出线的证据，需真机验证。
    private var assertSoftLimits: Bool { ProcessInfo.processInfo.environment["MOSAIC_BENCH_ASSERT"] == "1" }

    private func checkSoftLimit(_ ms: Double, _ limitMs: Double, _ label: String) {
        guard ms >= limitMs else { return }
        if assertSoftLimits {
            XCTFail("\(label): \(String(format: "%.1f", ms)) ms ≥ 软阈值 \(limitMs) ms")
        } else {
            // GitHub Actions 识别 `::warning::` 并在摘要里显示。
            print("::warning::[bench] \(label): \(String(format: "%.1f", ms)) ms ≥ soft limit \(limitMs) ms (not enforced; set MOSAIC_BENCH_ASSERT=1)")
        }
    }

    func testTopKPerformanceBaseline() throws {
        let cells = fullScale ? 10_800 : 1_200
        let library = fullScale ? 50_000 : 5_000
        let lib = FeatureMatrix(vectors: syntheticVectors(count: library, seed: 1))
        let queries = FeatureMatrix(vectors: syntheticVectors(count: cells, seed: 2))
        let kernel = ScalarSIMDKernel()
        // swift-corelibs-xctest 不支持 XCTMeasureOptions，用默认 measure（10 次）。
        measure {
            _ = try? kernel.topK(queries: queries, candidates: lib, k: 32)
        }
    }

    func testEndToEndAssignmentTiming() throws {
        let cols = fullScale ? 120 : 40
        let rows = fullScale ? 90 : 30
        let library = fullScale ? 50_000 : 5_000
        let grid = try MosaicGrid(columns: cols, rows: rows)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: library, seed: 3))
        let cells = FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: 4))
        let start = DispatchTime.now().uptimeNanoseconds
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print("[bench] assign \(cols)x\(rows) cells × \(library) candidates: \(String(format: "%.1f", ms)) ms; levels=\(a.statistics.levelCounts); cap=\(a.statistics.resolvedCap.map(String.init) ?? "∞")")
        XCTAssertEqual(neighborhoodViolations(a, .eight), 0)
    }

    /// 最坏情况（评审 M1 / S8）：整张目标图同一颜色（如大片天空）、合成 5 万张、cap = 1。
    /// 每格的 128 近邻很快被用尽，大量格子走「分批加深」。`MOSAIC_BENCH=1` 时对照 release 软阈值（默认只警告）。
    ///
    /// 技术方案 v0.2 §11.3：CI 不比绝对秒数，比**同一次运行内**的相对值
    /// `最坏耗时 ÷ 同次 top‑32 基准耗时`（10,800 格 × 同一素材库），超过 box 标定值的 1.5 倍
    /// 打印 `[bench][WARN]`（并输出 `::warning::`），不失败。box 标定：细档 ≈ 7.5×、中档 ≈ 3.5×、80×80 ≈ 4.5×。
    /// 绝对毫秒软阈值只在 `MOSAIC_BENCH_ASSERT=1` 时断言。
    private func worstCase(cols: Int, rows: Int, library: Int, softLimitMs: Double?, boxRatio: Double) throws {
        let grid = try MosaicGrid(columns: cols, rows: rows)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: library, seed: 5))
        var baselineMs: Double?
        if fullScale {
            let queries = FeatureMatrix(vectors: syntheticVectors(count: 10_800, seed: 2))
            let kernel = ScalarSIMDKernel()
            _ = try kernel.topK(queries: queries, candidates: lib, k: 32)   // 预热
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try kernel.topK(queries: queries, candidates: lib, k: 32)
            baselineMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        }
        let cells = FeatureMatrix(vectors: Array(repeating: FeatureVector(uniform: SIMD3(0.6, 0.02, 0.05)), count: grid.cellCount))
        var config = AssignmentConfiguration()
        config.cap = .limited(1)
        let start = DispatchTime.now().uptimeNanoseconds
        let a = try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: cells, library: lib)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        let st = a.statistics
        print("[bench] worst-case uniform \(cols)x\(rows) × \(library), cap=1: \(String(format: "%.1f", ms)) ms; levels=\(st.levelCounts); neighborhoodRelaxed=\(st.neighborhoodRelaxedCount) capIgnored=\(st.capIgnoredCount) maxUses=\(st.maxUses)")
        XCTAssertEqual(neighborhoodViolations(a, .four), 0, "放宽后仍保证 4 邻域不重复")
        if let baselineMs, baselineMs > 0 {
            let ratio = ms / baselineMs
            let limit = boxRatio * 1.5
            print("[bench] worst-case \(cols)x\(rows) ratio = \(String(format: "%.2f", ratio))× top-32 baseline (\(String(format: "%.1f", baselineMs)) ms); warn above \(String(format: "%.2f", limit))×")
            if ratio > limit {
                print("[bench][WARN] worst-case \(cols)x\(rows) ratio \(String(format: "%.2f", ratio))× > \(String(format: "%.2f", limit))× (box \(boxRatio)× × 1.5)")
                print("::warning::[bench] worst-case \(cols)x\(rows) ratio \(String(format: "%.2f", ratio))× exceeds \(String(format: "%.2f", limit))×")
            }
        }
        if fullScale, let softLimitMs { checkSoftLimit(ms, softLimitMs, "worst-case \(cols)x\(rows)") }
    }

    func testWorstCaseUniformTargetTiming() throws {   // 细档 120×90
        try worstCase(cols: fullScale ? 120 : 30, rows: fullScale ? 90 : 20, library: fullScale ? 50_000 : 3_000, softLimitMs: 2_500, boxRatio: 7.5)
    }

    func testWorstCaseUniformMediumTiming() throws {   // 中档 80×60
        try worstCase(cols: fullScale ? 80 : 20, rows: fullScale ? 60 : 15, library: fullScale ? 50_000 : 3_000, softLimitMs: 1_500, boxRatio: 3.5)
    }

    func testWorstCaseUniformSquareMediumTiming() throws {   // 中档 1:1 上界 80×80
        try worstCase(cols: fullScale ? 80 : 20, rows: fullScale ? 80 : 20, library: fullScale ? 50_000 : 3_000, softLimitMs: 1_500, boxRatio: 4.5)
    }

    /// 新路径：带亮度方差打分 + 取消令牌 + 进度回调的完整分配，与旧 API 耗时对比；另测取消延迟。
    func testEndToEndWithVarianceAndCancellation() throws {
        let cols = fullScale ? 120 : 40
        let rows = fullScale ? 90 : 30
        let library = fullScale ? 50_000 : 5_000
        let grid = try MosaicGrid(columns: cols, rows: rows)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: library, seed: 3))
        let cells = FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: 4))
        var rng = Xoshiro256StarStar(seed: 6)
        let variance = (0..<library).map { _ in rng.nextUnitFloat() * 0.002 }
        let token = CancellationToken()
        let start = DispatchTime.now().uptimeNanoseconds
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib, mask: nil,
                                            lightnessVariance: variance, cancellation: token) { _ in }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print("[bench] assign+variance+token+progress \(cols)x\(rows) × \(library): \(String(format: "%.1f", ms)) ms; levels=\(a.statistics.levelCounts)")

        // 取消延迟：在匹配阶段中途取消。
        let t2 = CancellationToken()
        let cancelledAt = Box<UInt64>(0)
        var thrown: Error?
        do {
            _ = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib, mask: nil,
                                            lightnessVariance: variance, cancellation: t2) { p in
                // >=：进度回调可能跳过恰好 total/3 的值（ProgressCounter 非最终上报用 tryLock）。
                // 只触发一次，避免重复 cancel。
                if p.phase == .matching, p.completed >= max(1, p.total / 3) {
                    var shouldCancel = false
                    cancelledAt.mutate { current in
                        if current == 0 {
                            current = DispatchTime.now().uptimeNanoseconds
                            shouldCancel = true
                        }
                    }
                    if shouldCancel { t2.cancel() }
                }
            }
        } catch { thrown = error }
        let cancelledNs = cancelledAt.value
        if cancelledNs == 0 {
            XCTFail("没有取消")
            return
        }
        let lat = Double(DispatchTime.now().uptimeNanoseconds - cancelledNs) / 1e6
        XCTAssertTrue(thrown is CancellationError)
        print("[bench] cancel latency mid-matching \(cols)x\(rows) × \(library): \(String(format: "%.2f", lat)) ms")
    }
}
