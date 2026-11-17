import Foundation
import XCTest
@testable import MosaicCore

/// 生成性能回归门禁（CI job「Generation perf regression」，AndyL 11-16：「性能要加入到回归中」）。
///
/// - 只在 `MOSAIC_PERF_GATE=1` 时运行（平时 `swift test` 直接跳过，不拖慢单测）；须 `-c release`。
/// - 每个指标先预热 1 次，再测 `MOSAIC_PERF_REPEAT` 次（默认 5），**本测试不判定快慢**，
///   只把每次耗时按约定格式输出，由 `scripts/perf-gate.py` 取中位数、对照 `perf/baseline-linux.json` 判定。
/// - 输出格式（QA 的端到端用例照此输出即可被门禁收录，见 `perf/README.md`）：
///   `[perf] {"metric":"<名字>","unit":"ms","samples":[...]}`，同时追加到 `MOSAIC_PERF_OUT` 指向的 JSONL 文件。
/// ⚠️ Linux 耗时只防回归，不能作为 iPhone 11 性能退出线的证据。
final class GenerationPerfGateTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(PerfGate.enabled, "设 MOSAIC_PERF_GATE=1（且 -c release）运行")
    }

    /// 固定 CPU 标定负载（单线程整数/浮点混合，不调用被测代码）：用来观察 runner 机器快慢，
    /// 门禁报告里给出「标定归一化」后的比值作参考。
    func testCalibrationCPU() throws {
        PerfGate.measure("calib_cpu_scalar") {
            var x: UInt64 = 0x9E37_79B9_7F4A_7C15
            var f: Double = 0
            for i in 0..<30_000_000 {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                f += Double(x & 0xFFFF) * 1e-9 + Double(i & 7)
            }
            PerfGate.sink(x &+ UInt64(f))
        }
    }

    /// 端到端生成（App 入口：目标图取样 → top-K 匹配 → 约束分配），细档 120×90，5 万合成素材。
    func testGenerateFine50k() throws { try generate(.fine, "gen_fine_2048x1536_50k") }

    /// 同上，中档 80×60。
    func testGenerateMedium50k() throws { try generate(.medium, "gen_medium_2048x1536_50k") }

    /// 端到端里的「目标图取样」阶段单独计时（细档 2048×1536），用于定位上面 gen_* 变慢时是取样还是匹配/分配。
    func testSampleFine2048() throws {
        let target = try noisyImage(width: 2048, height: 1536, seed: 7)
        let layout = try Layout.grid(width: target.width, height: target.height, density: .fine)
        let sampler = TargetSampler()
        try PerfGate.measureThrowing("sample_fine_2048x1536") {
            let cells = try sampler.cellFeatures(of: target, layout: layout)
            PerfGate.sink(UInt64(cells.count))
        }
    }

    /// 最坏情况（A-21 同口径）：整张同色、cap = 1、中档 80×60 × 5 万。
    func testWorstCaseUniformMedium() throws {
        let grid = try MosaicGrid(columns: 80, rows: 60)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 50_000, seed: 5))
        let cells = FeatureMatrix(vectors: Array(repeating: FeatureVector(uniform: SIMD3(0.6, 0.02, 0.05)), count: grid.cellCount))
        var config = AssignmentConfiguration()
        config.cap = .limited(1)
        let assigner = GreedyAssigner(configuration: config)
        try PerfGate.measureThrowing("worst_uniform_medium_80x60_cap1_50k") {
            let a = try assigner.assign(grid: grid, cellFeatures: cells, library: lib)
            PerfGate.sink(UInt64(a.tiles.count))
        }
    }

    /// 导出混合（A-19 原图叠加，CPU 路径）：2048×1536 整幅 α=0.2。iOS 上实际用 CG，这里只作像素级管线的回归代理。
    func testOverlayBlend2048() throws {
        let tile = try gradientImage(width: 2048, height: 1536)
        let target = try noisyImage(width: 2048, height: 1536, seed: 11)
        try PerfGate.measureThrowing("overlay_blend_2048x1536") {
            let out = try OverlayBlend.blend(tile: tile, target: target, alpha: 0.2)
            PerfGate.sink(UInt64(out.width))
        }
    }

    private func generate(_ density: Density, _ metric: String) throws {
        let target = try noisyImage(width: 2048, height: 1536, seed: 7)
        var rng = SplitMix64(seed: 9)
        let records = syntheticVectors(count: 50_000, seed: 3).map {
            FeatureRecord(vector: $0, lightnessVariance: rng.nextUnitFloat() * 0.002)
        }
        let snapshot = try LibrarySnapshot(table: FeatureTable(records: records))
        let pipeline = MosaicPipeline()
        try PerfGate.measureThrowing(metric) {
            let g = try pipeline.generate(target: target, density: density, snapshot: snapshot, seed: 42)
            PerfGate.sink(UInt64(g.assignment.tiles.count))
        }
    }

    /// 渐变 + 伪随机噪声的目标图（避免纯渐变让匹配过于规整）。
    private func noisyImage(width: Int, height: Int, seed: UInt64) throws -> PixelBuffer {
        var rng = SplitMix64(seed: seed)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let n = Int(rng.nextUnitFloat() * 64) - 32
                bytes[o] = UInt8(clamping: x * 255 / (width - 1) + n)
                bytes[o + 1] = UInt8(clamping: y * 255 / (height - 1) - n)
                bytes[o + 2] = UInt8(clamping: (x + y) * 127 / (width + height - 2) + n / 2)
            }
        }
        return try PixelBuffer(width: width, height: height, bytes: bytes)
    }
}

/// 门禁计时与输出的小工具（QA 的用例在 MosaicCoreTests 内可直接复用；其他包照 `perf/README.md` 的格式输出即可）。
enum PerfGate {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MOSAIC_PERF_GATE"] == "1" }
    static var repeatCount: Int { max(1, Int(ProcessInfo.processInfo.environment["MOSAIC_PERF_REPEAT"] ?? "") ?? 5) }
    private static let sinkLock = NSLock()
    nonisolated(unsafe) private static var sinkValue: UInt64 = 0

    /// 防止编译器把被测计算优化掉。
    static func sink(_ v: UInt64) { sinkLock.lock(); sinkValue &+= v; sinkLock.unlock() }

    static func measure(_ metric: String, _ body: () -> Void) {
        try? measureThrowing(metric) { body() }
    }

    static func measureThrowing(_ metric: String, warmup: Int = 1, _ body: () throws -> Void) throws {
        for _ in 0..<warmup { try body() }
        var samples: [Double] = []
        for _ in 0..<repeatCount {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        emit(metric: metric, samples: samples)
    }

    static func emit(metric: String, samples: [Double]) {
        let list = samples.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let line = "{\"metric\":\"\(metric)\",\"unit\":\"ms\",\"samples\":[\(list)]}"
        print("[perf] \(line)")
        if let path = ProcessInfo.processInfo.environment["MOSAIC_PERF_OUT"], !path.isEmpty {
            if !FileManager.default.fileExists(atPath: path) { _ = FileManager.default.createFile(atPath: path, contents: nil) }
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close()
            }
        }
    }
}
