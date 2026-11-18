// QA：生成全链路耗时指标（运维 PerfGateTests 格式，perf/README.md；判定在 scripts/perf-gate.py，测试里不断言耗时）。
// 覆盖 MosaicCore 门禁没有的部分：GenerationRunner（生产接法，GenPerfWiring）+ fake PhotoKit 慢路径 + 预览取图计划。
// 已有指标（不重复）：gen_fine/medium_2048x1536_50k（MosaicPipeline.generate 直测）、sample_fine_2048x1536、worst_uniform_…、overlay_blend_…、calib_cpu_scalar。
// 规模：目标图 1536×1152、固定素材集 v1 2000 张（GenPerfFixture.swift）。metric 名定了不改；素材集版本变了要换新名（后缀 _v2）。
// 依赖：GenPerfFixture.swift + GenPerfWiring.swift（入库版 = GenerationRunner.production）。
import Foundation
import XCTest
import MosaicCore
import MosaicAppCore

final class GenerationRunnerE2EPerfGateTests: XCTestCase {
    private func gate() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MOSAIC_PERF_GATE"] == "1")
    }

    /// 生成（冷会话：每个样本新建 runner，= 冷启动后第一次生成）。
    private func gen(_ d: DensityChoice, _ metric: String) async throws {
        try gate()
        let sh = GPShared.shared
        let snap = try await sh.snapshot()
        let target = sh.target
        let set = sh.set
        try await PerfGate.measureAsyncThrowing(metric, setup: {
            GenPerfWiring.makeRunner(probe: GPProbeLog(set), perf: PerfRecorder())
        }) { runner in
            let p = try await runner.run(target: target, snapshot: snap, settings: GenerationSettings(density: d),
                                         seed: GPScenario.runSeed, progress: nil)
            PerfGate.sink(UInt64(p.generation.layout.cellCount))
        }
    }

    /// 「换一种拼法」：同一 runner（会话缓存是热的，与 App 一致），只计 reshuffle。
    private func reshuffle(_ d: DensityChoice, _ metric: String) async throws {
        try gate()
        let sh = GPShared.shared
        let snap = try await sh.snapshot()
        let target = sh.target
        let set = sh.set
        let settings = GenerationSettings(density: d)
        try await PerfGate.measureAsyncThrowing(metric, setup: { () async throws -> (GenerationRunner, GenerationProduct) in
            let runner = GenPerfWiring.makeRunner(probe: GPProbeLog(set), perf: PerfRecorder())
            let first = try await runner.run(target: target, snapshot: snap, settings: settings, seed: GPScenario.runSeed, progress: nil)
            return (runner, first)
        }) { pair in
            let p = try await pair.0.reshuffle(pair.1, target: target, settings: settings, seed: GPScenario.reshuffleSeed, progress: nil)
            PerfGate.sink(UInt64(p.generation.layout.cellCount))
        }
    }

    func testRunnerGenCoarse() async throws { try await gen(.coarse, "runner_gen_coarse_1536x1152_2k") }
    func testRunnerGenMedium() async throws { try await gen(.medium, "runner_gen_medium_1536x1152_2k") }
    func testRunnerGenFine() async throws { try await gen(.fine, "runner_gen_fine_1536x1152_2k") }
    func testRunnerReshuffleCoarse() async throws { try await reshuffle(.coarse, "runner_reshuffle_coarse_1536x1152_2k") }
    func testRunnerReshuffleMedium() async throws { try await reshuffle(.medium, "runner_reshuffle_medium_1536x1152_2k") }
    func testRunnerReshuffleFine() async throws { try await reshuffle(.fine, "runner_reshuffle_fine_1536x1152_2k") }

    /// 预览取图计划（ThumbnailPreviewPlan，`.scanDisplay`，有界并发 12）+ fake 缩略图合成；中档 4800 格。只计取图 + 回调，不含 CG 绘制。
    func testPreviewFetchMedium() async throws {
        try gate()
        let sh = GPShared.shared
        let snap = try await sh.snapshot()
        let set = sh.set
        let product = try await GenerationRunner().run(target: sh.target, snapshot: snap, settings: GenerationSettings(density: .medium),
                                                       seed: GPScenario.runSeed, progress: nil)
        try await PerfGate.measureAsyncThrowing("runner_preview_fetch_medium_1536x1152_2k", setup: { GPThumbnails(set) }) { thumbs in
            _ = try await GPScenario.preview(product, thumbnails: thumbs)
        }
    }

    /// PhotoKit 慢路径：生成 + 换一种拼法（同一 runner），fake 探测每次 5 ms、iCloud-only 60 ms、报错的 5 ms。
    /// 生产接法不在生成路径上碰 PhotoKit 时，本指标 ≈ runner_gen_medium + runner_reshuffle_medium；接回逐张探测会多出秒级。
    func testSlowPathICloudMedium() async throws {
        try gate()
        let sh = GPShared.shared
        let snap = try await sh.snapshot()
        let target = sh.target
        let set = sh.set
        let settings = GenerationSettings(density: .medium)
        let delays: [GPAssetKind: UInt64] = [.local: 5_000_000, .lowRes: 5_000_000, .failing: 5_000_000, .iCloudOnly: 60_000_000]
        try await PerfGate.measureAsyncThrowing("runner_slowpath_icloud_medium_1536x1152_2k", setup: {
            GenPerfWiring.makeRunner(probe: GPProbeLog(set, delayNanos: delays), perf: PerfRecorder())
        }) { runner in
            let first = try await runner.run(target: target, snapshot: snap, settings: settings, seed: GPScenario.runSeed, progress: nil)
            let p = try await runner.reshuffle(first, target: target, settings: settings, seed: GPScenario.reshuffleSeed, progress: nil)
            PerfGate.sink(UInt64(p.generation.layout.cellCount))
        }
    }
}

// MARK: - PerfGate（照抄 ci/perf-regression 2af277d 的 MosaicCoreTests/GenerationPerfGateTests.swift 末尾；另加 async 版本）

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

    /// async 版：每个样本先跑 `setup`（不计时，例如新建 runner / 先生成一次），再计时 `body`。预热 1 次不计。
    static func measureAsyncThrowing<T>(_ metric: String, warmup: Int = 1, setup: () async throws -> T,
                                        _ body: (T) async throws -> Void) async throws {
        for _ in 0..<warmup { try await body(try await setup()) }
        var samples: [Double] = []
        for _ in 0..<repeatCount {
            let s = try await setup()
            let t0 = DispatchTime.now().uptimeNanoseconds
            try await body(s)
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
