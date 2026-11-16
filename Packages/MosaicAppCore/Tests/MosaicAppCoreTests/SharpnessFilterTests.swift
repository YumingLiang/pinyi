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

    /// 最终结果的每一格都必须是「探测过且通过」的照片。
    func assertEveryCellProbePassed(_ p: GenerationProduct, _ probe: FakeResolutionProbe, cache: LocalResolutionCache,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let ids = p.cellAssetIDs
        XCTAssertEqual(ids.count, p.generation.layout.cellCount, file: file, line: line)
        let probed = Set(probe.calls)
        let bad = probe.state.get().unusable
        for (cell, id) in ids.enumerated() {
            guard let id else { return XCTFail("格子 \(cell) 没有照片", file: file, line: line) }
            XCTAssertTrue(probed.contains(id), "格子 \(cell) 用了未探测的 \(id)", file: file, line: line)
            XCTAssertFalse(bad.contains(id), "格子 \(cell) 用了不合格的 \(id)", file: file, line: line)
            XCTAssertEqual(cache.verdict(for: id), .usable, file: file, line: line)
        }
        XCTAssertEqual(p.lowRes.unresolvedCellCount, 0, file: file, line: line)
    }

    /// 最后兜底：只在到达最多轮数后发生；只换坏格子、忽略单张上限；每格都是探测通过的照片。
    func testFinalFallbackFillsOnlyFromProbePassedPhotos() async throws {
        let snap = try await snapshot(assets: 300)
        for (rounds, failRatio) in [(0, 3), (1, 10), (3, 10)] {
            // failRatio = 10：90% 不合格（只有 a0、a10、a20… 合格）；3：三分之二不合格
            let good = Set(stride(from: 0, to: 300, by: failRatio).map { "a\($0)" })
            let bad = Set((0..<300).map { "a\($0)" }).subtracting(good)
            let probe = FakeResolutionProbe(unusable: bad)
            let cache = LocalResolutionCache()
            let p = try await runner(probe, cache: cache, rounds: rounds)
                .run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 4)
            assertEveryCellProbePassed(p, probe, cache: cache)
            XCTAssertLessThanOrEqual(p.lowRes.rematchRounds, rounds)
            if p.lowRes.finalFallbackCellCount > 0 {
                XCTAssertEqual(p.lowRes.rematchRounds, rounds, "兜底只在用完重配轮数后发生")
                XCTAssertGreaterThanOrEqual(p.generation.assignment.statistics.capIgnoredCount, p.lowRes.finalFallbackCellCount,
                                            "补上的格子记为忽略上限")
            }
        }
        // rounds = 0 且三分之二不合格：首轮必有坏格 → 一定走兜底
        let probe = FakeResolutionProbe(unusable: everyThird(300).symmetricDifference(Set((0..<300).map { "a\($0)" })))
        let cache = LocalResolutionCache()
        let p = try await runner(probe, cache: cache, rounds: 0)
            .run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 2)
        XCTAssertGreaterThan(p.lowRes.finalFallbackCellCount, 0)
        assertEveryCellProbePassed(p, probe, cache: cache)
    }

    /// 能在轮数内解决时不放宽上限：结果与「直接用剔除后的快照生成」完全一致（没有额外的忽略上限）。
    func testNoCapRelaxationWhenResolvedWithinRounds() async throws {
        let snap = try await snapshot(assets: 300)
        let probe = FakeResolutionProbe(unusable: everyThird(300))
        let cache = LocalResolutionCache()
        let settings = GenerationSettings(density: .coarse)
        let p = try await runner(probe, cache: cache).run(target: try target(), snapshot: snap, settings: settings, seed: 7)
        XCTAssertEqual(p.lowRes.finalFallbackCellCount, 0)
        assertEveryCellProbePassed(p, probe, cache: cache)
        let plain = try await GenerationRunner().run(target: try target(), snapshot: p.snapshot, settings: settings, seed: 7)
        XCTAssertEqual(p.generation.assignment.tiles, plain.generation.assignment.tiles)
        XCTAssertEqual(p.generation.assignment.statistics.capIgnoredCount, plain.generation.assignment.statistics.capIgnoredCount)
    }

    /// 只剩 1 张合格：所有格子都用它（重复也比糊强），不走 noMaterial。
    func testSinglePassedPhotoFillsEverything() async throws {
        let snap = try await snapshot(assets: 300)
        let bad = Set((1..<300).map { "a\($0)" })
        let probe = FakeResolutionProbe(unusable: bad)
        let cache = LocalResolutionCache()
        let p = try await runner(probe, cache: cache, rounds: 1)
            .run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 3)
        XCTAssertTrue(probe.calls.contains("a0"))
        assertEveryCellProbePassed(p, probe, cache: cache)
        XCTAssertEqual(Set(p.cellAssetIDs.compactMap { $0 }), ["a0"])
        XCTAssertGreaterThan(p.lowRes.finalFallbackCellCount, 0)
    }

    /// 每轮只探测本轮新出现的照片（缓存保证），按轮核对探测数。
    func testEachRoundProbesOnlyNewlyIntroducedPhotos() async throws {
        let snap = try await snapshot(assets: 300)
        let probe = FakeResolutionProbe(unusable: everyThird(300))
        let cache = LocalResolutionCache()
        let marks = Locked<[Int]>([])   // 每轮开始探测时 probe.calls 的长度
        let p = try await runner(probe, cache: cache)
            .run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 7, progress: nil,
                 stage: { s in if s == .checkingSharpness { marks.update { $0.append(probe.calls.count) } } })
        let rounds = p.lowRes.rounds
        XCTAssertEqual(rounds.count, p.lowRes.rematchRounds + 1)
        XCTAssertGreaterThanOrEqual(rounds.count, 2, "这个场景至少重配一轮")
        let m = marks.get() + [probe.calls.count]
        XCTAssertEqual(m.count, rounds.count + 1)
        var earlier = Set<String>()
        for (r, stat) in rounds.enumerated() {
            let callsThisRound = Array(probe.calls[m[r]..<m[r + 1]])
            XCTAssertEqual(callsThisRound.count, stat.probed, "第 \(r) 轮")
            XCTAssertEqual(stat.probed, stat.newlyIntroduced, "第 \(r) 轮只探测新出现的照片")
            XCTAssertTrue(Set(callsThisRound).isDisjoint(with: earlier), "第 \(r) 轮没有重复探测前几轮的照片")
            earlier.formUnion(callsThisRound)
        }
        XCTAssertEqual(rounds[0].probed, rounds[0].assignedDistinct, "首轮（空缓存）探测本轮全部照片")
        XCTAssertEqual(rounds.map(\.probed).reduce(0, +), probe.calls.count)
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

    // MARK: 「可用照片」= 筛选后（产品 PR #5 跟进）

    func testSourceRowCountExcludesLowRes() {
        let complete = IndexStatus(assetTotal: 300, available: 300, pending: 0, unavailableLocal: 0, failed: 0,
                                   isScanning: false, wasInterrupted: false, hasCompletedInitialScan: true)
        let row = SourceListLogic.allPhotosRow(access: .full, status: complete)
        let r = SourceListLogic.excludingLowRes(row, count: 120, scanComplete: true)
        XCTAssertEqual(r.count, 180)
        XCTAssertEqual(r.countLine, LocalizedLine(.sourceListCount, ["180"]))
        XCTAssertEqual(SourceListLogic.excludingLowRes(row, count: 120, scanComplete: false), row, "扫描未完成显示「约 N 张」总数，不减")
        XCTAssertEqual(SourceListLogic.excludingLowRes(row, count: 0, scanComplete: true), row)
        XCTAssertEqual(SourceListLogic.excludingLowRes(row, count: 999, scanComplete: true).count, 0)
    }

    func testOutcomeAndShortageUsePostFilterCount() async throws {
        let snap = try await snapshot(assets: 300)
        let bad = Set((10..<300).map { "a\($0)" })
        // 轮数内解决 与 走最后兜底 两条路径都按筛选后的张数判断
        for rounds in [3, 0] {
            let probe = FakeResolutionProbe(unusable: bad)
            let p = try await runner(probe, rounds: rounds)
                .run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 1)
            let after = 300 - p.lowRes.excludedCount
            XCTAssertEqual(p.snapshot.availableCount, after)
            XCTAssertEqual(p.outcome.availableAfterFilter, after)
            XCTAssertEqual(p.generation.assignment.statistics.availableCandidates, after, "rounds=\(rounds)：结果页「重复用了几次」按筛选后张数")
            XCTAssertEqual(p.generation.supply, MaterialSupply.evaluate(availableCount: after))
            XCTAssertEqual(p.outcome.isBelowThresholdAfterFilter, MaterialSupply.evaluate(availableCount: after).needsWarning)
        }
        let plain = try await GenerationRunner().run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 1)
        XCTAssertNil(plain.outcome.availableAfterFilter, "未启用筛选")
    }

    @MainActor
    func testPostFilterShortageSurfacesOnResultThenGatesNextRun() async throws {
        // 210 张：生成前 ≥ 200 不提示；只有 a0…a9 清楚 → 筛选后不足 200 → 结果页补「照片比较少」
        let bad = Set((10..<210).map { "a\($0)" })
        let probe = FakeResolutionProbe(unusable: bad)
        let gen = GatedGenerator(runner: GenerationRunner(sharpness: LocalResolutionChecker(probe: probe)))
        let h = CoordinatorHarness(assets: 210, generator: gen)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        XCTAssertEqual(c.state.allPhotosRow.count, 210)
        await c.generateTapped()
        XCTAssertFalse(c.state.flow.generation.shortagePrompt, "生成前按已知数 210，不提示")
        await c.settle()
        guard case .result(let o) = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        let n = c.product!.lowRes.excludedCount
        XCTAssertGreaterThan(n, 10)
        XCTAssertEqual(o.availableAfterFilter, 210 - n)
        XCTAssertTrue(c.state.postFilterShortageNotice, "筛选后才不足 200：结果页补提示")
        XCTAssertEqual(c.state.allPhotosRow.count, 210 - n, "来源页「可用照片」= 筛选后")
        XCTAssertEqual(c.state.allPhotosRow.countLine, LocalizedLine(.sourceListCount, [CountFormat.grouped(210 - n)]))

        // 下一次：生成前就按筛选后的已知数判断 → 生成前提示，结果页不再重复
        c.send(.backToSettings)
        await c.generateTapped()
        XCTAssertTrue(c.state.flow.generation.shortagePrompt, "已知筛选后不足 200：生成前提示")
        c.send(.shortageContinue)
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        XCTAssertFalse(c.state.postFilterShortageNotice, "生成前已提示过，结果页不重复")
        c.stop()
    }

    @MainActor
    func testNoPostFilterShortageWhenEnoughSharpPhotos() async throws {
        let probe = FakeResolutionProbe(unusable: Set(["a1", "a2", "a3"]))
        let gen = GatedGenerator(runner: GenerationRunner(sharpness: LocalResolutionChecker(probe: probe)))
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail() }
        XCTAssertFalse(c.state.postFilterShortageNotice)
        c.stop()
    }

    // MARK: 失败后「再试一次」与相册变化后排除数

    func testLowResExclusionDropsIdsNoLongerInSource() {
        let e = LowResExclusion(selection: .allPhotos, assetIDs: ["a1", "a2", "a3", "gone"])
        let kept = e.pruned(to: ["a1", "a3", "a9"])
        XCTAssertEqual(kept.assetIDs, ["a1", "a3"])
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.selection, .allPhotos)
        XCTAssertEqual(e.pruned(to: ["x"]).count, 0)
        XCTAssertEqual(e.pruned(to: e.assetIDs), e, "来源没变时排除集不变")
        let album = LowResExclusion(selection: .album(id: "trip"), assetIDs: ["a1", "a2"])
        XCTAssertEqual(album.pruned(to: ["a2"]).selection, .album(id: "trip"))
        XCTAssertEqual(album.pruned(to: ["a2"]).assetIDs, ["a2"])
    }

    @MainActor
    func testRetryTappedUsesPostFilterCountForShortageGate() async throws {
        // 210 张：生成前 ≥ 200；筛选后不足 200。第一次成功后记下排除数，第二次故意失败，
        // 「再试一次」必须按筛选后张数走 200 张门槛（否则会直接开跑、不出现「照片比较少」）。
        let bad = Set((10..<210).map { "a\($0)" })
        let probe = FakeResolutionProbe(unusable: bad)
        let gen = GatedGenerator(runner: GenerationRunner(sharpness: LocalResolutionChecker(probe: probe)))
        let h = CoordinatorHarness(assets: 210, generator: gen)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        let excluded = c.state.lowResExclusion?.count ?? 0
        XCTAssertGreaterThan(excluded, 10)
        XCTAssertLessThan(210 - excluded, MaterialSupply.insufficientThreshold)
        XCTAssertGreaterThanOrEqual(c.state.indexStatus.available, MaterialSupply.insufficientThreshold)

        c.send(.backToSettings)
        gen.failFromCall.set(2)
        await c.generateTapped()
        XCTAssertTrue(c.state.flow.generation.shortagePrompt)
        c.send(.shortageContinue)
        await c.settle()
        guard case .failed = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        XCTAssertEqual(c.state.lowResExclusion?.count, excluded, "普通失败不改排除数")

        await c.retryTapped()
        XCTAssertTrue(c.state.flow.generation.shortagePrompt, "再试一次按筛选后张数，应再提示「照片比较少」")
        c.send(.shortageBack)
        XCTAssertEqual(c.state.indexStatus.available, 210, "索引张数仍是筛选前的")
        c.stop()
    }

    @MainActor
    func testExcludedCountUpdatesWhenLibraryDropsExcludedPhotos() async throws {
        let probe = FakeResolutionProbe(unusable: everyThird(300))
        let gen = GatedGenerator(runner: GenerationRunner(sharpness: LocalResolutionChecker(probe: probe)))
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        let ids = c.state.lowResExclusion?.assetIDs ?? []
        XCTAssertFalse(ids.isEmpty)
        let before = ids.count
        XCTAssertEqual(c.state.allPhotosRow.count, 300 - before)
        // 删掉一部分被排除的，再删一张从未排除的；排除数只应去掉已不在来源里的。
        let dropped = Set(ids.sorted().prefix(max(1, ids.count / 2)))
        let sharpGone = "a1"
        XCTAssertFalse(ids.contains(sharpGone), "a1 不在每 3 张一剔的集合里")
        h.library.delete(dropped.union([sharpGone]))
        c.libraryDidChange()
        while h.clock.sleeperCount == 0 { await Task.yield() }
        h.clock.advance(2)
        await waitFor(c, "删除后索引更新") { $0.indexStatus.available == 300 - dropped.count - 1 }
        await c.settle()
        let after = c.state.lowResExclusion?.assetIDs ?? []
        XCTAssertEqual(after, ids.subtracting(dropped))
        XCTAssertEqual(c.state.lowResExclusion?.count, before - dropped.count)
        XCTAssertEqual(c.state.allPhotosRow.count, (300 - dropped.count - 1) - (before - dropped.count))
        XCTAssertEqual(c.state.sourceLowResLine, LocalizedLine(.sourceExcludedLowRes, [CountFormat.grouped(before - dropped.count)]))
        c.stop()
    }
}
