// QA 生成性能回归（AndyL 11-16：「性能要加入到回归中，这个太差了」）。方案：qa/perf/gen-perf-regression-plan.md
//
// 1) GenPerfCountGateTests —— 确定性调用次数门（阻塞）：匹配/分配次数、整图重配轮数、PhotoKit 探测与取图次数 ≤ 66dc745 基线。
// 2) GenPerfSlowPathTests —— iCloud-only / PhotoKit 慢路径（阻塞）：不挂、慢路径下调用次数仍 ≤ 基线、不重复请求、不联网。
// 耗时不在这里断言：CI 门禁指标见 GenerationRunnerE2EPerfGateTests.swift（运维 PerfGateTests 格式，scripts/perf-gate.py 判定）。
// 本文件的用例全部是确定性断言（次数 / 不挂 / 不联网），不加 MOSAIC_PERF_GATE 开关，平时 swift test 就拦。
import Foundation
import XCTest
import MosaicCore
import MosaicAppCore

/// 每个进程只建一次索引（2000 张合成图），各测试共用。
actor GPShared {
    static let shared = GPShared()
    let set = GPMaterialSet()
    let target = GPMaterialSet.target()
    private var snap: IndexSnapshot?
    func snapshot() async throws -> IndexSnapshot {
        if let snap { return snap }
        let s = try await GPScenario.buildSnapshot(set: set, thumbnails: GPThumbnails(set))
        snap = s
        return s
    }
}

struct GPBaselineMissing: Error, CustomStringConvertible {
    var description: String { "没有找到基线文件（PINYI_PERF_BASELINE / perf/gen-perf-counts.json / qa/perf/baseline.json）" }
}

struct GPBaseline: Codable {
    struct Scenario: Codable {
        var counts: GPCounts
        var runMedianMs: Double?
        var reshuffleMedianMs: Double?
        var previewMedianMs: Double?
    }
    var schema: Int
    var materialSetVersion: Int
    var scenarios: [String: Scenario]
}

func gpLoadBaseline() throws -> GPBaseline {
    guard let url = gpBaselineURL() else {
        // 找不到基线必须红（否则 CI 上计数门会被悄悄跳过）
        throw GPBaselineMissing()
    }
    let data = try Data(contentsOf: url)
    let dec = JSONDecoder()
    return try dec.decode(GPBaseline.self, from: data)
}

final class GenPerfCountGateTests: XCTestCase {
    /// 计数门：严格不超过 66dc745 基线（确定性，不受 runner 噪声影响）。
    func check(_ density: DensityChoice) async throws {
        let base = try gpLoadBaseline()
        XCTAssertEqual(base.materialSetVersion, GPMaterialSet.version, "素材集版本变了，要在 66dc745 上重跑基线")
        let b = try XCTUnwrap(base.scenarios[density.rawValue]?.counts, "基线缺 \(density.rawValue)")
        let sh = GPShared.shared
        let set = sh.set
        let r = try await GPScenario.run(density: density, snapshot: try await sh.snapshot(), target: sh.target, set: set,
                                         thumbnails: GPThumbnails(set), probe: GPProbeLog(set))
        let c = r.counts
        print("[gen-perf][counts] \(density.rawValue) wiring=\(GenPerfWiring.label) \(c)")
        let tag = "[\(density.rawValue)] "
        XCTAssertEqual(c.cells, b.cells, tag + "格子数与基线不同：素材集或密度定义变了，需重跑基线")
        XCTAssertLessThanOrEqual(c.generatePassesRun, b.generatePassesRun, tag + "生成整图匹配+分配跑了 \(c.generatePassesRun) 遍（基线 \(b.generatePassesRun)）——疑似重配循环")
        XCTAssertLessThanOrEqual(c.generatePassesReshuffle, b.generatePassesReshuffle, tag + "换一种拼法跑了 \(c.generatePassesReshuffle) 遍（基线 \(b.generatePassesReshuffle)）")
        XCTAssertLessThanOrEqual(c.matchPhasesTotal, b.matchPhasesTotal, tag + "top-k 匹配次数 \(c.matchPhasesTotal) > 基线 \(b.matchPhasesTotal)")
        XCTAssertLessThanOrEqual(c.assignPhasesTotal, b.assignPhasesTotal, tag + "分配次数 \(c.assignPhasesTotal) > 基线 \(b.assignPhasesTotal)")
        XCTAssertLessThanOrEqual(c.rematchRoundsRun + c.rematchRoundsReshuffle, b.rematchRoundsRun + b.rematchRoundsReshuffle,
                                 tag + "整图重配 \(c.rematchRoundsRun)+\(c.rematchRoundsReshuffle) 轮（基线 0）")
        XCTAssertLessThanOrEqual(c.refillCalls, b.refillCalls, tag + "兜底补格 \(c.refillCalls) 次（基线 \(b.refillCalls)）")
        XCTAssertLessThanOrEqual(c.probeRequestsRun, b.probeRequestsRun, tag + "生成时 PhotoKit 探测 \(c.probeRequestsRun) 次（基线 \(b.probeRequestsRun)）")
        XCTAssertLessThanOrEqual(c.probeRequestsReshuffle, b.probeRequestsReshuffle, tag + "换拼法时 PhotoKit 探测 \(c.probeRequestsReshuffle) 次（基线 \(b.probeRequestsReshuffle)）")
        XCTAssertLessThanOrEqual(c.probeMaxPerAsset, 1, tag + "同一张照片被探测 \(c.probeMaxPerAsset) 次")
        XCTAssertLessThanOrEqual(c.thumbnailRequestsDuringGenerate, b.thumbnailRequestsDuringGenerate, tag + "生成阶段多了缩略图请求")
        XCTAssertLessThanOrEqual(c.previewMaxRequestsPerAssetPerRender, 1, tag + "一次预览里同一张照片请求了多次")
        XCTAssertLessThanOrEqual(c.previewThumbnailRequests, c.previewDistinctAssets, tag + "预览请求数 > 用到的不同照片数")
    }

    func testCountsCoarse() async throws { try await check(.coarse) }
    func testCountsMedium() async throws { try await check(.medium) }
    func testCountsFine() async throws { try await check(.fine) }
}

/// 带超时地跑一个异步任务；超时就取消并返回 nil。
func gpWithTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
    await withTaskGroup(of: Result<T, Error>?.self) { group in
        group.addTask {
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        // 等被取消的那一个收尾（挂住且不理取消的实现会卡在这里 → 外层 CI timeout 兜底）
        while await group.next() != nil {}
        return first
    }
}

final class GenPerfSlowPathTests: XCTestCase {
    /// PhotoKit 慢路径：每次探测 5 ms（冷缓存解码），iCloud-only 探测 60 ms / 取图 40 ms 后返回在云端 / 取不到，failing 报错；中密度。
    /// 断言（确定性）：不挂（60 s 内完成，只作挂死检测）、慢路径下生成遍数与 PhotoKit 探测次数仍 ≤ 66dc745 基线（= 生成路径上不碰慢的 PhotoKit）、
    /// 每张最多请求 1 次（会话内）、预览不重试、不联网。慢路径耗时由 PerfGate 指标 runner_slowpath_icloud_medium_1536x1152_2k 记录。
    func testICloudOnlySlowPathNoExtraRequests() async throws {
        let base = try gpLoadBaseline()
        let b = try XCTUnwrap(base.scenarios["medium"]?.counts)
        let sh = GPShared.shared
        let set = sh.set
        let snap = try await sh.snapshot()
        let target = sh.target
        let thumbs = GPThumbnails(set, delayNanos: [.iCloudOnly: 40_000_000], unavailable: [.iCloudOnly], failing: [.failing])
        let probe = GPProbeLog(set, delayNanos: [.local: 5_000_000, .lowRes: 5_000_000, .failing: 5_000_000, .iCloudOnly: 60_000_000])
        let res = await gpWithTimeout(seconds: 60) {
            try await GPScenario.run(density: .medium, snapshot: snap, target: target, set: set, thumbnails: thumbs, probe: probe)
        }
        guard let res else { return XCTFail("iCloud-only 慢路径 60 s 内没完成（挂住）") }
        let r = try res.get()
        print("[gen-perf][slow-path] run=\(r.runSeconds)s reshuffle=\(r.reshuffleSeconds)s preview=\(r.previewSeconds)s counts=\(r.counts)")
        XCTAssertLessThanOrEqual(r.counts.generatePassesRun + r.counts.generatePassesReshuffle, b.generatePassesRun + b.generatePassesReshuffle,
                                 "慢路径下整图匹配遍数超基线（重配循环）")
        XCTAssertLessThanOrEqual(r.counts.probeRequestsRun + r.counts.probeRequestsReshuffle, b.probeRequestsRun + b.probeRequestsReshuffle,
                                 "生成路径上发了 \(r.counts.probeRequestsRun + r.counts.probeRequestsReshuffle) 次 PhotoKit 探测（基线 0）——慢 PhotoKit 会直接拖慢生成")
        XCTAssertLessThanOrEqual(r.counts.probeMaxPerAsset, 1, "同一张照片被重复探测")
        XCTAssertLessThanOrEqual(r.counts.previewMaxRequestsPerAssetPerRender, 1, "预览对取不到的照片重复请求")
        XCTAssertFalse(thumbs.state.get().networkAllowedSeen, "请求带了 isNetworkAccessAllowed = true")
    }

    /// 探测请求永远不回调（直到被取消）：生成必须结束（30 s 挂死检测，不是耗时断言）。
    func testHangingProbeDoesNotHangGeneration() async throws {
        let sh = GPShared.shared
        let set = sh.set
        let snap = try await sh.snapshot()
        let target = sh.target
        let probe = GPProbeLog(set, hang: [.iCloudOnly])
        let res = await gpWithTimeout(seconds: 30) {
            try await GPScenario.run(density: .coarse, snapshot: snap, target: target, set: set, thumbnails: GPThumbnails(set), probe: probe)
        }
        XCTAssertNotNil(res, "有一张 iCloud-only 照片的请求不回调，生成就挂住（30 s 未结束）——探测在生成关键路径上")
        if case .failure(let e)? = res { XCTFail("生成失败：\(e)") }
    }
}

