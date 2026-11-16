import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

/// 假探测器：按集合判定；记录每次调用、同时在飞的最大数；可让所有探测挂住直到被取消。
final class FakeResolutionProbe: LocalResolutionProbing, Sendable {
    struct State: Sendable {
        var unusable: Set<String> = []
        var calls: [String] = []
        var inFlight = 0
        var maxInFlight = 0
        var hang = false
    }
    let state: Locked<State>
    init(unusable: Set<String> = [], hang: Bool = false) { state = Locked(State(unusable: unusable, hang: hang)) }

    func probe(assetID: String, minPixelSize: Int) async -> LocalResolutionVerdict {
        let hang = state.update { s -> Bool in
            s.calls.append(assetID)
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
            return s.hang
        }
        if hang {
            // 挂住直到 Task 被取消（真实 PhotoKit 请求被 cancelImageRequest 后会回调失败）。
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            state.update { $0.inFlight -= 1 }
            return .unusable(.failed)
        }
        await Task.yield()
        let bad = state.update { s -> Bool in
            s.inFlight -= 1
            return s.unusable.contains(assetID)
        }
        return bad ? .unusable(.tooSmall) : .usable
    }
    var calls: [String] { state.get().calls }
}

final class SharpnessFilterTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func target(w: Int = 160, h: Int = 120) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            bytes[o] = UInt8(x * 255 / (w - 1)); bytes[o + 1] = UInt8(y * 255 / (h - 1)); bytes[o + 2] = 128
        } }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }

    func snapshot(assets: Int) async throws -> IndexSnapshot {
        let idx = PhotoIndex(directory: dir, library: FakePhotoLibrary(assetCount: assets), thumbnails: FakeThumbnails(),
                             backupExclusion: RecordingBackupExclusion(), configuration: smallConfig(batch: 100, concurrency: 16, minRows: 1000))
        await idx.load()
        _ = try await idx.synchronize()
        return try await idx.snapshot(for: .allPhotos)
    }

    func runner(_ probe: FakeResolutionProbe, cache: LocalResolutionCache = LocalResolutionCache(), rounds: Int = 3,
                perf: PerfRecorder? = nil) -> GenerationRunner {
        GenerationRunner(perf: perf, sharpness: LocalResolutionChecker(probe: probe, cache: cache, maxRematchRounds: rounds))
    }

    /// 每 3 张有 1 张不够清楚。
    func everyThird(_ n: Int) -> Set<String> { Set(stride(from: 0, to: n, by: 3).map { "a\($0)" }) }

    // MARK: 判定规则

    func testPolicyClassify() {
        typealias P = LocalResolutionPolicy
        XCTAssertEqual(P.classify(hasImage: true, pixelWidth: 256, pixelHeight: 340, isDegraded: false, isInCloud: false, hasError: false), .usable)
        XCTAssertEqual(P.classify(hasImage: true, pixelWidth: 255, pixelHeight: 4000, isDegraded: false, isInCloud: false, hasError: false), .unusable(.tooSmall))
        XCTAssertEqual(P.classify(hasImage: true, pixelWidth: 512, pixelHeight: 512, isDegraded: true, isInCloud: false, hasError: false), .unusable(.degraded))
        XCTAssertEqual(P.classify(hasImage: true, pixelWidth: 512, pixelHeight: 512, isDegraded: false, isInCloud: true, hasError: false), .unusable(.inCloud))
        XCTAssertEqual(P.classify(hasImage: false, pixelWidth: 0, pixelHeight: 0, isDegraded: false, isInCloud: true, hasError: false), .unusable(.inCloud))
        XCTAssertEqual(P.classify(hasImage: false, pixelWidth: 0, pixelHeight: 0, isDegraded: false, isInCloud: false, hasError: false), .unusable(.missing))
        XCTAssertEqual(P.classify(hasImage: true, pixelWidth: 512, pixelHeight: 512, isDegraded: false, isInCloud: false, hasError: true), .unusable(.failed))
        XCTAssertEqual(P.minPixelSize, 256)
    }

    // MARK: 剔除 + 重配

    func testExcludedAssetsNeverAppearAndAllCellsFilled() async throws {
        let snap = try await snapshot(assets: 300)
        let bad = everyThird(300)
        let probe = FakeResolutionProbe(unusable: bad)
        let perf = PerfRecorder()
        let stages = Locked<[GenerationStage]>([])
        let fractions = Locked<[Double]>([])
        let p = try await runner(probe, perf: perf).run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse),
                                                        seed: 7, progress: { f in fractions.update { $0.append(f) } },
                                                        stage: { s in stages.update { $0.append(s) } })
        let ids = p.cellAssetIDs
        XCTAssertEqual(ids.count, p.generation.layout.cellCount)
        XCTAssertTrue(ids.allSatisfy { $0 != nil }, "重配后每格都有照片")
        XCTAssertTrue(Set(ids.compactMap { $0 }).isDisjoint(with: bad), "不够清楚的照片不会出现在最终结果里")
        XCTAssertEqual(p.lowRes.unresolvedCellCount, 0)
        XCTAssertGreaterThanOrEqual(p.lowRes.rematchRounds, 1)
        XCTAssertTrue(p.lowRes.excludedAssetIDs.isSubset(of: bad))
        XCTAssertFalse(p.lowRes.excludedAssetIDs.isEmpty)
        // 快照里也去掉了：「换一种拼法」不会把它们换回来
        XCTAssertEqual(p.snapshot.availableCount, 300 - p.lowRes.excludedCount)
        // 进度单调、到 1；阶段里出现过「检查清晰度」
        let f = fractions.get()
        XCTAssertEqual(f.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(f, f.sorted(), "进度单调")
        XCTAssertTrue(stages.get().contains(.checkingSharpness))
        // 性能页：探测张数与耗时
        let row = perf.report().row(.sharpnessProbe)
        XCTAssertEqual(row?.count, 1)
        XCTAssertEqual(row?.totalItems, p.lowRes.probedCount)
        XCTAssertTrue(perf.allSamples().contains { $0.phase == .sharpnessProbe && ($0.note ?? "").contains("排除 \(p.lowRes.excludedCount)") })
    }

    func testExcludedCountIsDedupedAndEachAssetProbedOnce() async throws {
        let snap = try await snapshot(assets: 300)
        let bad = everyThird(300)
        let probe = FakeResolutionProbe(unusable: bad)
        let p = try await runner(probe).run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 11)
        let calls = probe.calls
        XCTAssertEqual(Set(calls).count, calls.count, "同一张照片一次生成里只探测一次（多格共用、多轮重配都不重复）")
        XCTAssertEqual(p.lowRes.probedCount, calls.count)
        let probedBad = Set(calls).intersection(bad)
        XCTAssertEqual(p.lowRes.excludedAssetIDs, probedBad, "N = 探测为不合格的不同照片数")
        XCTAssertEqual(p.lowRes.excludedCount, probedBad.count)
    }

    func testCacheAvoidsReprobeAcrossRunsAndReshuffle() async throws {
        let snap = try await snapshot(assets: 300)
        let bad = everyThird(300)
        let probe = FakeResolutionProbe(unusable: bad)
        let cache = LocalResolutionCache()
        let r = runner(probe, cache: cache)
        let settings = GenerationSettings(density: .coarse)
        let p1 = try await r.run(target: try target(), snapshot: snap, settings: settings, seed: 5)
        let n1 = probe.calls.count
        XCTAssertGreaterThan(n1, 0)
        XCTAssertEqual(cache.count, n1)

        // 同参数再来一次：已知不合格的先剔掉，结果全部命中缓存
        let p2 = try await r.run(target: try target(), snapshot: snap, settings: settings, seed: 5)
        XCTAssertEqual(probe.calls.count, n1, "第二次不再探测")
        XCTAssertEqual(p2.lowRes.probedCount, 0)
        XCTAssertGreaterThan(p2.lowRes.cacheHits, 0)
        XCTAssertEqual(p2.lowRes.rematchRounds, 0, "已知不合格的生成前就剔掉了")
        XCTAssertEqual(p2.lowRes.excludedAssetIDs, p1.lowRes.excludedAssetIDs)
        XCTAssertEqual(p1.generation.assignment.tiles, p2.generation.assignment.tiles)

        // 换一种拼法：沿用剔除后的快照；只探测新出现的照片，不重复探测
        let p3 = try await r.reshuffle(p1, target: try target(), settings: settings, seed: MosaicSeed.next(after: 5))
        let calls = probe.calls
        XCTAssertEqual(Set(calls).count, calls.count, "跨次生成也不重复探测")
        XCTAssertTrue(Set(p3.cellAssetIDs.compactMap { $0 }).isDisjoint(with: bad))
        XCTAssertTrue(p3.lowRes.excludedAssetIDs.isSuperset(of: p1.lowRes.excludedAssetIDs), "换拼法后 N 只增不减")

        // 相册变化：只清不合格条目
        let usableBefore = cache.count - cache.knownUnusable().count
        r.invalidateLocalResolution()
        XCTAssertTrue(cache.knownUnusable().isEmpty)
        XCTAssertEqual(cache.count, usableBefore, "合格的保留")
    }

    func testCancellationMidProbeThrowsAndProducesNoResult() async throws {
        let snap = try await snapshot(assets: 300)
        let probe = FakeResolutionProbe(hang: true)
        let cache = LocalResolutionCache()
        let r = runner(probe, cache: cache)
        let t = try target()
        let task = Task { try await r.run(target: t, snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 3) }
        // 等探测开始（每次只等一小会儿，让出执行权；看门狗 30 s）
        let deadline = Date().addingTimeInterval(30)
        while probe.calls.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(probe.calls.isEmpty, "探测应已开始")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后不应有结果")
        } catch {
            XCTAssertTrue(error is CancellationError, "实际 \(error)")
            XCTAssertNil(GenerationFailure.classify(error), "取消不是失败")
        }
        XCTAssertEqual(cache.count, 0, "取消后到达的探测结果不入缓存")
        XCTAssertLessThanOrEqual(probe.state.get().maxInFlight, LocalResolutionPolicy.maxConcurrentProbes)
    }

    func testBoundedConcurrency() async throws {
        let probe = FakeResolutionProbe()
        let checker = LocalResolutionChecker(probe: probe, maxConcurrent: 8)
        let ids = (0..<200).map { "a\($0)" } + (0..<50).map { "a\($0)" }   // 含重复
        let pass = try await checker.check(ids)
        XCTAssertEqual(pass.probed, 200, "去重")
        XCTAssertEqual(pass.verdicts.count, 200)
        XCTAssertEqual(probe.calls.count, 200)
        XCTAssertLessThanOrEqual(probe.state.get().maxInFlight, 8)
    }

    // MARK: 边界

    func testAllUnusableSurfacesNoMaterialPath() async throws {
        let snap = try await snapshot(assets: 300)
        let all = Set((0..<300).map { "a\($0)" })
        let probe = FakeResolutionProbe(unusable: all)
        do {
            _ = try await runner(probe).run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 1)
            XCTFail("一张可用的都没有，不应出结果")
        } catch let e as NoSharpPhotosError {
            XCTAssertGreaterThan(e.excludedCount, 0)
            XCTAssertEqual(GenerationFailure.classify(e), .noMaterial, "走现有「没有可用照片」路径")
        }
    }

    func testFewUsableShowsShortageNotice() async throws {
        let snap = try await snapshot(assets: 300)
        let bad = Set((10..<300).map { "a\($0)" })   // 只剩 10 张清楚的
        let probe = FakeResolutionProbe(unusable: bad)
        let p = try await runner(probe).run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 1)
        XCTAssertTrue(Set(p.cellAssetIDs.compactMap { $0 }).isDisjoint(with: bad))
        XCTAssertTrue(p.generation.supply.needsWarning, "剔除后按剩余张数判断供给")
        XCTAssertEqual(p.generation.assignment.statistics.availableCandidates, 10, "候选只剩 10 张清楚的")
        XCTAssertTrue(p.generation.assignment.statistics.isBelowMaterialThreshold, "结果页「照片少」提示按剔除后的张数判断（是否显示另看是否放宽了约束）")
        XCTAssertEqual(p.lowRes.excludedCount, 290)
    }

    func testMaxRoundsReachedReportsUnresolvedCells() async throws {
        let snap = try await snapshot(assets: 300)
        let probe = FakeResolutionProbe(unusable: everyThird(300))
        let p = try await runner(probe, rounds: 0).run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 2)
        XCTAssertEqual(p.lowRes.rematchRounds, 0)
        XCTAssertGreaterThan(p.lowRes.unresolvedCellCount, 0, "到达最多轮数仍不合格的格子要报告")
        XCTAssertTrue(p.lowRes.excludedAssetIDs.isEmpty, "没被剔除的（仍在图上）不算进 N")
    }

    func testWithoutCheckerBehavesAsBefore() async throws {
        let snap = try await snapshot(assets: 300)
        let p = try await GenerationRunner().run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 9)
        XCTAssertFalse(p.lowRes.enabled)
        XCTAssertEqual(p.lowRes.excludedCount, 0)
        XCTAssertEqual(p.snapshot.availableCount, 300)
    }

    func testSnapshotExcludingOnlyTouchesMask() async throws {
        let snap = try await snapshot(assets: 50)
        let (s2, removed) = try snap.excluding(assetIDs: ["a1", "a2", "not-in-library"])
        XCTAssertEqual(removed, ["a1", "a2"])
        XCTAssertEqual(s2.availableCount, 48)
        XCTAssertEqual(s2.library.table.count, snap.library.table.count)
        XCTAssertEqual(s2.assetIDsByRow, snap.assetIDsByRow)
    }

    // MARK: 来源页

    @MainActor
    func testCoordinatorShowsExcludedCountOnSourcePageForCurrentSource() async throws {
        let probe = FakeResolutionProbe(unusable: everyThird(300))
        let gen = GatedGenerator(runner: GenerationRunner(sharpness: LocalResolutionChecker(probe: probe)))
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        XCTAssertNil(c.state.sourceLowResLine)
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        let n = c.product?.lowRes.excludedCount ?? 0
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(c.state.sourceLowResLine, LocalizedLine(.sourceExcludedLowRes, [CountFormat.grouped(n)]))
        XCTAssertEqual(c.state.generationProgressBodyKey, .generateProgressChecking, "最后一个阶段是检查清晰度")
        // 换了来源就不显示（数字只对那个来源成立）
        c.selectSource(.album(id: "x"))
        XCTAssertNil(c.state.sourceLowResLine)
        c.selectSource(.allPhotos)
        XCTAssertNotNil(c.state.sourceLowResLine)
        // 相册变化转发到探测缓存
        c.libraryDidChange()
        c.stop()
    }
}
