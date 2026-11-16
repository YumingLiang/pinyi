import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 架构师 G-3 的 AppCoordinator 用例（假实现 + 闸门 + 假时钟，不写 sleep）。测试名带 QA 编号。
@MainActor
final class AppCoordinatorTests: XCTestCase {

    // MARK: 启动

    /// 评审 §3：启动先出路由（不等索引加载）；B-27：启动时清导出临时目录。
    func testStartResolvesRouteBeforeIndexLoadAndCleansExports_B27() async throws {
        let h = CoordinatorHarness(assets: 30)
        let c = h.coordinator
        c.start()
        XCTAssertEqual(c.state.route, .main(.full), "路由同步给出")
        XCTAssertFalse(c.state.indexLoaded, "此时索引还没加载完")
        XCTAssertEqual(h.exporter.state.get().staleRemovals, 1)
        await c.settle()
        XCTAssertTrue(c.state.indexLoaded)
        XCTAssertEqual(c.state.scan.phase, .completed)
        XCTAssertEqual(c.state.indexStatus.available, 30)
        XCTAssertEqual(h.lifecycle.begun.get(), [.scan])
        XCTAssertEqual(h.lifecycle.ended.get(), [.scan])
        XCTAssertEqual(h.store.prepares, 1)
        c.stop()
    }

    // MARK: 扫描

    /// G-3「扫描中途取消」= QA B-33 / B-26 / B-07：确认停止后已完成批次保留、标记续扫；再开始只扫剩下的。
    func testCancelMidScanKeepsProgressAndResumes_B33() async throws {
        let gate = GatePoint()
        let h = CoordinatorHarness(assets: 500, thumbnails: GatedThumbnails(gates: [250: gate]))
        let c = h.coordinator
        c.start()
        await gate.reached.wait()
        await waitFor(c, "进度已到 200") { $0.scan.progress.processed >= 200 }
        c.scanCancelTapped()
        XCTAssertEqual(c.state.scan.phase, .confirmingCancel)
        c.scanCancelConfirmed()
        XCTAssertEqual(c.state.scan.phase, .stopped)
        await gate.release.open()
        await c.settle()
        XCTAssertEqual(c.state.scan.phase, .stopped, "取消是静默的，不变成 failed")
        XCTAssertTrue(c.state.indexStatus.wasInterrupted, "下次显示 scan.resume")
        let kept = c.state.indexStatus.available
        XCTAssertGreaterThanOrEqual(kept, 200)
        XCTAssertLessThan(kept, 500)
        XCTAssertTrue(c.state.scan.canUsePartialAfterStop)

        let before = h.thumbnails.counter.get()
        c.startScan()
        XCTAssertTrue(c.state.scan.progress.isResuming)
        await c.settle()
        XCTAssertEqual(c.state.scan.phase, .completed)
        XCTAssertEqual(c.state.indexStatus.available, 500)
        XCTAssertFalse(c.state.indexStatus.wasInterrupted)
        XCTAssertEqual(h.thumbnails.counter.get() - before, 500 - kept, "只扫剩下的")
        c.stop()
    }

    /// G-3「扫到 2000 张时进入渐进可用」= QA B-07：≥ 2,000 张时显示「已就绪 N 张」并可以直接开始生成（扫描继续）。
    func testProgressiveReadyAt2000AndGenerateWhileScanning_B07() async throws {
        let gate = GatePoint()
        let h = CoordinatorHarness(assets: 2600, thumbnails: GatedThumbnails(gates: [2150: gate]))
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await gate.reached.wait()
        await waitFor(c, "渐进可用") { $0.scan.canStartGenerationEarly }
        XCTAssertNotNil(c.state.scan.progressiveReadyLine)
        XCTAssertEqual(c.state.scan.phase, .scanning)
        XCTAssertGreaterThanOrEqual(c.state.scan.progress.availableCount, ScanFlow.progressiveThreshold)
        XCTAssertLessThan(c.state.scan.progress.availableCount, 2600)

        await c.generateTapped()
        XCTAssertFalse(c.state.showScanSheet, "≥ 2,000 张不再等扫描")
        XCTAssertTrue(c.state.isGenerating)
        await gate.release.open()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertGreaterThanOrEqual(c.product?.snapshot.availableCount ?? 0, 2000)
        XCTAssertLessThan(c.product?.snapshot.availableCount ?? 0, 2600, "快照取的是生成那一刻")
        XCTAssertEqual(c.state.scan.phase, .completed)
        XCTAssertEqual(c.state.indexStatus.available, 2600)
        c.stop()
    }

    /// 不足 2,000 且扫描未完成：点开始 → 先去扫描页等。
    func testGenerateBeforeProgressiveThresholdWaitsForScan_B07() async throws {
        let gate = GatePoint()
        let h = CoordinatorHarness(assets: 3000, thumbnails: GatedThumbnails(gates: [450: gate]))
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await gate.reached.wait()
        await c.generateTapped()
        XCTAssertTrue(c.state.showScanSheet)
        XCTAssertEqual(c.state.flow.generation.phase, .idle)
        XCTAssertEqual(h.generator.calls.get(), 0)
        await gate.release.open()
        await c.settle()
        c.stop()
    }

    // MARK: 生成

    /// G-3「生成中取消后重新生成」= QA B-20 / B-29：确认取消回设置页、旧结果被忽略；再生成拿到新结果。
    func testCancelGenerationThenRegenerate_B20() async throws {
        let gate = GatePoint()
        let gen = GatedGenerator(gate: gate)
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        await c.generateTapped()
        await gate.reached.wait()
        XCTAssertTrue(c.state.isGenerating)
        XCTAssertEqual(h.lifecycle.begun.get().filter { $0 == .generate }.count, 1)
        c.send(.cancelTapped)
        XCTAssertTrue(c.state.flow.generation.showsCancelConfirm)
        c.send(.cancelConfirmed)
        XCTAssertEqual(c.state.flow.generation.phase, .idle)
        XCTAssertFalse(c.state.isGenerating)
        XCTAssertEqual(h.lifecycle.ended.get().filter { $0 == .generate }.count, 1)
        await gate.release.open()      // 旧任务继续跑完——结果必须被丢弃
        await c.settle()
        XCTAssertNil(c.product, "被取消那次的结果不能出现")
        XCTAssertEqual(c.state.flow.generation.phase, .idle)

        gen.gate.set(nil)
        await c.generateTapped()
        await c.settle()
        guard case .result(let o) = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        XCTAssertEqual(h.generator.calls.get(), 2)
        XCTAssertEqual(c.product?.outcome, o)
        XCTAssertEqual(c.state.resultRevision, 1)

        // B-29：换一种拼法只换种子
        c.send(.reshuffleTapped)
        await c.settle()
        guard case .result(let o2) = c.state.flow.generation.phase else { return XCTFail() }
        XCTAssertNotEqual(o2.seed, o.seed)
        XCTAssertEqual(c.state.resultRevision, 2)
        c.stop()
    }

    /// 生成的后台宽限到期 = QA B-18：挂起，回前台同种子自动重跑。
    func testGenerationBackgroundExpiryRerunsSameSeedOnActive_B18() async throws {
        let gate = GatePoint()
        let gen = GatedGenerator(gate: gate)
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        await c.generateTapped()
        await gate.reached.wait()
        guard case .running(_, let seed, _) = c.state.flow.generation.phase else { return XCTFail() }
        h.lifecycle.send(.backgroundTimeExpired(.generate))   // 走事件流
        await waitFor(c, "挂起") { if case .suspended = $0.flow.generation.phase { return true }; return false }
        gen.gate.set(nil)
        await gate.release.open()
        await c.handle(.becameActive)
        await c.settle()
        guard case .result(let o) = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        XCTAssertEqual(o.seed, seed)
        c.stop()
    }

    // MARK: 前后台

    /// G-3「进入后台时落盘」= QA B-18 / B-26：扫描中进后台 → 当前批次结束立即提交（不等提交策略），并释放预取。
    func testEnterBackgroundFlushesScanProgressToDisk_B18() async throws {
        let g1 = GatePoint(), g2 = GatePoint()
        var cfg = smallConfig(batch: 100, concurrency: 4, minRows: 1_000_000)
        cfg.minRowsForTimedCommit = 1_000_000
        let h = CoordinatorHarness(assets: 600, thumbnails: GatedThumbnails(gates: [150: g1, 250: g2]), config: cfg)
        let c = h.coordinator
        c.start()
        await g1.reached.wait()
        XCTAssertEqual(storedRows(h.store), 0, "提交策略下还没落过新行")
        await c.handle(.enteredBackground)
        XCTAssertEqual(h.thumbnails.stopAllCount.get(), 1, "决定 5：进后台释放预取")
        await g1.release.open()
        await g2.reached.wait()
        XCTAssertEqual(storedRows(h.store), 200, "进后台后第 2 批一结束就落盘")
        await g2.release.open()
        await c.settle()
        XCTAssertEqual(storedRows(h.store), 600)
        c.stop()
    }

    /// 扫描的后台宽限到期 = QA B-18：暂停（不提示），回前台自动续扫。走事件流。
    func testScanBackgroundExpiryPausesAndResumesOnActive_B18() async throws {
        let gate = GatePoint()
        let h = CoordinatorHarness(assets: 400, thumbnails: GatedThumbnails(gates: [150: gate]))
        let c = h.coordinator
        c.start()
        await gate.reached.wait()
        h.lifecycle.send(.backgroundTimeExpired(.scan))
        await waitFor(c, "暂停") { $0.scan.phase == .pausedInBackground }
        await gate.release.open()
        await c.settle()
        XCTAssertLessThan(c.state.indexStatus.available, 400)
        h.lifecycle.send(.becameActive)
        await waitFor(c, "续扫完成") { $0.scan.phase == .completed && $0.indexStatus.available == 400 }
        XCTAssertFalse(c.state.scan.progress.isResuming, "回前台继续不提示")
        await c.settle()
        c.stop()
    }

    /// G-3「授权变为受限或拒绝」= QA B-31 / B-02：回前台发现被拒 → 停扫描、进权限页；改为受限 → 受限页或受限主页并重扫。
    func testAuthorizationBecomesDeniedThenLimited_B31() async throws {
        let gate = GatePoint()
        let h = CoordinatorHarness(assets: 400, thumbnails: GatedThumbnails(gates: [150: gate]))
        let c = h.coordinator
        c.start()
        await gate.reached.wait()
        h.library.setAuth(.denied)
        await c.handle(.becameActive)
        XCTAssertEqual(c.state.route, .permission(.denied))
        XCTAssertEqual(c.state.scan.phase, .idle)
        await gate.release.open()
        await c.settle()
        XCTAssertLessThan(c.state.indexStatus.available, 400, "扫描已停")
        c.startScan()
        await c.settle()
        XCTAssertLessThan(c.state.indexStatus.available, 400, "没有读取权限时不扫描")

        // 改为受限、还没确认过 → 受限说明页
        h.library.setAuth(.limited)
        await c.handle(.becameActive)
        XCTAssertEqual(c.state.route, .permission(.limited))
        await c.permissionAction(.secondary, on: .limited)   // 「用已选的照片继续」
        XCTAssertEqual(c.state.route, .main(.limited))
        XCTAssertTrue(h.preferences.bool(.limitedAcknowledged))
        h.library.delete(Set((0..<100).map { "a\($0)" }))      // 受限集合只剩 300 张
        await c.settle()
        XCTAssertEqual(c.state.indexStatus.available, 300)
        XCTAssertEqual(c.state.allPhotosRow.titleKey, .sourceListAllowed)

        // 生成中被拒：生成也停
        c.setTarget(try CoordinatorHarness.target())
        let g2 = GatePoint()
        h.generator.gate.set(g2)
        await c.generateTapped()
        await g2.reached.wait()
        h.library.setAuth(.denied)
        await c.handle(.becameActive)
        XCTAssertFalse(c.state.isGenerating)
        XCTAssertEqual(c.state.route, .permission(.denied))
        await g2.release.open()
        await c.settle()
        XCTAssertNil(c.product)
        c.stop()
    }

    // MARK: 导出 / 保存

    private func generated(_ h: CoordinatorHarness) async throws {
        h.coordinator.setTarget(try CoordinatorHarness.target())
        h.coordinator.start()
        await h.coordinator.settle()
        await h.coordinator.generateTapped()
        await h.coordinator.settle()
        guard case .result = h.coordinator.state.flow.generation.phase else { return XCTFail("没有结果") }
    }

    /// G-3「保存失败」= QA B-16 / B-17 / B-30：权限 > 空间 > 其他；临时文件总被删除。
    func testSaveFailuresFollowPriority_B16_B17_B30() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        try await generated(h)

        // B-16 权限被拒：不渲染
        h.library.state.update { $0.addOnlyAuth = .denied }
        await c.saveTapped()
        XCTAssertEqual(c.state.export, .failed(.addDenied))
        XCTAssertEqual(c.state.export, .failed(.addDenied))
        XCTAssertEqual(h.exporter.state.get().exports, 0)
        XCTAssertEqual(SaveFailure.addDenied.secondaryKey, .saveAddDeniedShare)
        c.dismissExportResult()

        // 未决定 → 请求一次 → 允许
        h.library.state.update { $0.addOnlyAuth = .notDetermined; $0.addOnlyAfterRequest = .authorized }
        // B-17 空间预检不足（权限之后）
        h.exporter.state.update { $0.available = 10; $0.estimate = 1000 }
        await c.saveTapped()
        XCTAssertEqual(h.library.state.get().addOnlyRequests, 1)
        XCTAssertEqual(c.state.export, .failed(.diskFull))
        XCTAssertEqual(h.exporter.state.get().exports, 0)
        c.dismissExportResult()

        // B-17 写入中磁盘满
        h.exporter.state.update { $0.available = nil; $0.error = .insufficientStorage }
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(c.state.export, .failed(.diskFull))
        c.dismissExportResult()

        // B-30 编码失败
        h.exporter.state.update { $0.error = .encodingFailed }
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(c.state.export, .failed(.other))
        XCTAssertEqual(SaveFailure.other.titleKey, .saveFailed)
        c.dismissExportResult()

        // 写相册失败（其他）→ 临时文件仍被删
        h.exporter.state.update { $0.error = nil }
        h.library.state.update { $0.saveError = .generic }
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(c.state.export, .failed(.other))
        XCTAssertEqual(h.exporter.state.get().discarded.count, 1)
        c.dismissExportResult()

        // 写相册时磁盘满 → 空间
        h.library.state.update { $0.saveError = .outOfSpace }
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(c.state.export, .failed(.diskFull))
        c.dismissExportResult()

        // 成功
        h.library.state.update { $0.saveError = nil }
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(c.state.export, .saved)
        XCTAssertEqual(h.library.state.get().savedFiles.count, 1)
        XCTAssertEqual(h.exporter.state.get().discarded.count, 3)
        XCTAssertEqual(h.lifecycle.begun.get().filter { $0 == .export }.count, h.lifecycle.ended.get().filter { $0 == .export }.count)
        c.stop()
    }

    /// 导出被后台宽限打断 = QA B-18（导出）：显示 export.interrupted；用户取消则静默回到空闲。
    func testExportInterruptedByBackgroundExpiry_B18() async throws {
        let gate = GatePoint()
        let h = CoordinatorHarness(assets: 300, exporter: FakeExporter(gate: gate))
        let c = h.coordinator
        try await generated(h)
        await c.saveTapped()
        await gate.reached.wait()
        await c.handle(.backgroundTimeExpired(.export))
        await gate.release.open()
        await c.settle()
        XCTAssertEqual(c.state.export, .interrupted)

        h.exporter.gate.set(nil)
        c.dismissExportResult()
        c.shareTapped()
        await c.settle()
        guard case .sharing(let url) = c.state.export else { return XCTFail("\(c.state.export)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        c.shareFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "分享结束删临时文件")
        XCTAssertEqual(c.state.export, .idle)
        c.stop()
    }

    // MARK: 互斥

    /// G-3「两个操作并发触发时互斥」：并发点两次开始只跑一次；并发点两次保存只导出一次；
    /// 导出中不能开始 / 换拼法 / 返回设置；生成中不能导出；扫描中再开始扫描被忽略。
    func testConcurrentActionsAreMutuallyExclusive() async throws {
        let ggate = GatePoint()
        let gen = GatedGenerator(gate: ggate)
        let egate = GatePoint()
        let h = CoordinatorHarness(assets: 300, generator: gen, exporter: FakeExporter(gate: egate))
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        c.startScan()   // 扫描中再开始：忽略
        await c.settle()
        XCTAssertEqual(h.thumbnails.counter.get(), 300, "只扫一遍")

        async let a: Void = c.generateTapped()
        async let b: Void = c.generateTapped()
        _ = await (a, b)
        await ggate.reached.wait()
        XCTAssertEqual(gen.calls.get(), 1, "并发两次开始只跑一次")
        await c.saveTapped()
        XCTAssertEqual(c.state.export, .idle, "生成中不能导出")
        gen.gate.set(nil)
        await ggate.release.open()
        await c.settle()
        XCTAssertEqual(gen.calls.get(), 1)
        guard case .result(let o) = c.state.flow.generation.phase else { return XCTFail() }

        async let s1: Void = c.saveTapped()
        async let s2: Void = c.saveTapped()
        _ = await (s1, s2)
        await egate.reached.wait()
        XCTAssertEqual(h.exporter.state.get().exports, 1, "并发两次保存只导出一次")
        c.shareTapped()
        c.send(.reshuffleTapped)
        c.send(.backToSettings)
        await c.generateTapped()
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.generation.phase, .result(o), "导出中结果不动")
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertEqual(gen.calls.get(), 1)
        await egate.release.open()
        await c.settle()
        XCTAssertEqual(c.state.export, .saved)
        XCTAssertEqual(h.exporter.state.get().exports, 1)
        c.stop()
    }

    // MARK: 内存采样（MF-7）

    /// 阶段进行中按假时钟 0.5 s 采样；阶段结束停止采样（没有空转的定时器）。
    func testMemorySamplingDuringScanUsesInjectedClock_MF7() async throws {
        let gate = GatePoint()
        let h = CoordinatorHarness(assets: 300, thumbnails: GatedThumbnails(gates: [150: gate]))
        let c = h.coordinator
        c.start()
        await gate.reached.wait()
        XCTAssertTrue(c.memory.isSampling)
        h.memory.set(300 * 1024 * 1024)
        // 等采样循环挂到假时钟上，再推进
        while h.clock.sleeperCount == 0 { await Task.yield() }
        h.clock.advance(0.5)
        await gate.release.open()
        await c.settle()
        XCTAssertFalse(c.memory.isSampling)
        let scan = try XCTUnwrap(c.memory.peakByPhase()[.scan])
        XCTAssertEqual(scan.peakBytes, 300 * 1024 * 1024)
        XCTAssertEqual(scan.deltaBytes, 200 * 1024 * 1024)
        XCTAssertNotNil(c.memory.peakByPhase()[.indexLoad])
        let checks = SQLiteTriggerCheck.evaluate(samples: h.coordinator.dependencies.perf.allSamples(), memory: c.memory.samples())
        XCTAssertEqual(checks.first { $0.metric == .indexMemoryDelta }?.verdict, .triggered, "200 MB > 150 MB")
        c.stop()
    }

    /// 相册变化去抖（决定 11 / 方案 §2.5）：2 s 内多次变化合并为一次全量 diff；时间用假时钟推进。
    func testLibraryChangesAreDebouncedWithInjectedClock_B11() async throws {
        let h = CoordinatorHarness(assets: 100)
        let c = h.coordinator
        c.start()
        await c.settle()
        h.library.add(["n1", "n2"])
        c.libraryDidChange()
        while h.clock.sleeperCount == 0 { await Task.yield() }
        h.clock.advance(1)
        c.libraryDidChange()          // 1 s 后又变：重新计时
        h.library.add(["n3"])
        while h.clock.sleeperCount == 0 { await Task.yield() }
        h.clock.advance(1.5)          // 距第一次 2.5 s、距最近一次 1.5 s：还不触发
        await Task.yield()
        XCTAssertEqual(c.state.indexStatus.available, 100)
        while h.clock.sleeperCount == 0 { await Task.yield() }
        h.clock.advance(0.5)          // 距最近一次 2 s：触发一次
        await waitFor(c, "增量扫描完成") { $0.indexStatus.available == 103 }
        await c.settle()
        XCTAssertEqual(h.thumbnails.counter.get(), 103, "只扫新增的 3 张，合并成一轮")
        c.stop()
    }

    private func storedRows(_ store: InMemoryIndexStore) -> Int {
        if case .loaded(let s) = store.load(spec: FeatureExtractor().spec) { return s.table.count }
        return 0
    }
}
