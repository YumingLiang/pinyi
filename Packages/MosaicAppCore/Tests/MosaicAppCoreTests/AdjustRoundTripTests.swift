import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

/// B10.3 / B10.13 / B10.14（产品 22:50）+ 协调人方案①（QA A10）：
/// 「再调一调」进设置页后只动了叠加强度 → 主按钮「完成」（`common.done`），回到原结果：不重新生成，格子 / 种子 / 结果版本号都不变，
/// 只按新强度重画；存过的结果回来后按钮是 `works.update`。动了密度 / 目标图 → 「开始拼图」，重新生成，算新的一张，作品 id 清掉。
@MainActor
final class AdjustRoundTripTests: XCTestCase {

    // MARK: 状态机

    func testMachineRestoreLastResultFromIdle() {
        var m = GenerationMachine(initialSeed: 42)
        XCTAssertEqual(m.send(.restoreLastResult), [], "没有上一次结果：忽略")
        XCTAssertEqual(m.phase, .idle)
        _ = m.send(.startTapped(available: 1000))
        let o = GenerationOutcome(seed: 42, shouldShowShortageNotice: false, cellCount: 12)
        _ = m.send(.succeeded(runID: 1, o))
        _ = m.send(.backToSettings)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.send(.restoreLastResult), [], "不跑生成、不改生成中标记")
        XCTAssertEqual(m.phase, .result(o), "回到同一个结果（同一种子）")
        XCTAssertNil(m.currentRunID)
        // 回来之后再开始生成，种子仍按原来的顺延（restore 不消耗种子）
        _ = m.send(.backToSettings)
        XCTAssertEqual(m.send(.startTapped(available: 1000)), [.setGenerationActive(true), .run(runID: 2, seed: MosaicSeed.next(after: 42))])
    }

    func testMachineRestoreIgnoredOutsideIdle() {
        var m = GenerationMachine(initialSeed: 42)
        let o = GenerationOutcome(seed: 42, shouldShowShortageNotice: false, cellCount: 12)
        _ = m.send(.startTapped(available: 1000))
        _ = m.send(.succeeded(runID: 1, o))
        _ = m.send(.backToSettings)
        _ = m.send(.startTapped(available: 1000))                 // 改了密度重新生成中
        XCTAssertEqual(m.send(.restoreLastResult), [], "生成中不能跳回旧结果")
        XCTAssertEqual(m.currentRunID, 2)
        _ = m.send(.cancelTapped)
        XCTAssertEqual(m.send(.restoreLastResult), [], "确认取消框上也不行")
        _ = m.send(.cancelConfirmed)
        XCTAssertEqual(m.phase, .idle)
        _ = m.send(.restoreLastResult)                            // 取消后旧结果仍在
        XCTAssertEqual(m.phase, .result(o))
    }

    // MARK: 协调器

    private func generated() async throws -> (CoordinatorHarness, AppCoordinator) {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start(); await c.settle()
        XCTAssertEqual(c.settingsPrimaryAction, .start, "第一次进设置页：开始拼图")
        await c.generateTapped(); await c.settle()
        await waitFor(c, "生成完") { if case .result = $0.flow.generation.phase { return true }; return false }
        return (h, c)
    }

    func testAlphaOnlyRoundTripKeepsCellsSeedAndRevision() async throws {
        let (h, c) = try await generated()
        let before = try XCTUnwrap(c.workResultContext.layout)
        let rev = c.state.resultRevision
        let calls = h.generator.calls.get()

        c.send(.backToSettings); await c.settle()
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertEqual(c.settingsPrimaryAction, .done, "什么都没改也是「完成」")
        XCTAssertEqual(c.settingsPrimaryAction.titleKey, .commonDone)
        XCTAssertNotNil(c.product, "调整期间保留结果（和改动前一样只留一份 product，不额外占内存）")
        c.setOverlayAlpha(0.22)
        XCTAssertEqual(c.settingsPrimaryAction, .done)
        c.settingsDoneTapped(); await c.settle()

        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertEqual(h.generator.calls.get(), calls, "不重新生成")
        XCTAssertEqual(c.state.resultRevision, rev, "结果版本号不变（作品 id 不丢）")
        XCTAssertFalse(c.state.isGenerating)
        let after = try XCTUnwrap(c.workResultContext.layout)
        XCTAssertEqual(after.cellAssignments, before.cellAssignments, "格子完全一样")
        XCTAssertEqual(after.params.seed, before.params.seed)
        XCTAssertEqual(after.params.overlayAlpha, 0.22, accuracy: 1e-9, "只换叠加强度")
        XCTAssertEqual(WorkFingerprint.of(after), WorkFingerprint.of(before))
        c.stop()
    }

    /// 「开始拼图」接口本身总是重新生成（UI 在 `.done` 时显示的是「完成」，不会走到这里）；已有的「回设置页再生成一次」用例不受影响。
    func testGenerateTappedAlwaysRegenerates() async throws {
        let (h, c) = try await generated()
        let rev = c.state.resultRevision
        let calls = h.generator.calls.get()
        c.send(.backToSettings); c.setOverlayAlpha(0.1)
        await c.generateTapped(); await c.settle()
        await waitFor(c, "生成完") { if case .result = $0.flow.generation.phase { return true }; return false }
        XCTAssertEqual(h.generator.calls.get(), calls + 1)
        XCTAssertGreaterThan(c.state.resultRevision, rev)
        c.stop()
    }

    func testDensityChangeRegeneratesAsNewResult() async throws {
        let (h, c) = try await generated()
        let before = try XCTUnwrap(c.workResultContext.layout)
        let rev = c.state.resultRevision
        c.send(.backToSettings)
        c.setDensity(c.state.flow.settings.density == .fine ? .coarse : .fine)
        XCTAssertEqual(c.settingsPrimaryAction, .start, "改了密度：开始拼图")
        XCTAssertEqual(c.settingsPrimaryAction.titleKey, .generateCTA)
        c.settingsDoneTapped(); await c.settle()
        XCTAssertEqual(c.state.flow.step, .settings, "不是「完成」时点 done 无效")
        let calls = h.generator.calls.get()
        await c.generateTapped(); await c.settle()
        await waitFor(c, "重新生成完") { if case .result = $0.flow.generation.phase { return true }; return false }
        XCTAssertEqual(h.generator.calls.get(), calls + 1)
        XCTAssertGreaterThan(c.state.resultRevision, rev)
        XCTAssertNotEqual(c.workResultContext.layout?.params.seed, before.params.seed)
        // 再「再调一调」：比较对象换成新结果
        c.send(.backToSettings)
        XCTAssertEqual(c.settingsPrimaryAction, .done)
        c.stop()
    }

    func testDensityChangedBackIsDoneAgain() async throws {
        let (_, c) = try await generated()
        let d = c.state.flow.settings.density
        c.send(.backToSettings)
        c.setDensity(d == .fine ? .coarse : .fine)
        XCTAssertEqual(c.settingsPrimaryAction, .start)
        c.setDensity(d)
        XCTAssertEqual(c.settingsPrimaryAction, .done)
        c.stop()
    }

    func testNewTargetRegenerates() async throws {
        let (_, c) = try await generated()
        c.send(.backToSettings)
        c.setTarget(try CoordinatorHarness.target())               // 换图 / 重新裁剪 = 新目标图
        XCTAssertEqual(c.settingsPrimaryAction, .start)
        c.stop()
    }

    /// 改了密度开始生成又取消：回到设置页，旧结果仍在；把密度改回来又能「完成」回到旧结果。
    func testCancelledRegenerationKeepsOldResult() async throws {
        let gate = GatePoint()
        let gen = GatedGenerator()
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target())
        c.start(); await c.settle()
        await c.generateTapped(); await c.settle()
        await waitFor(c, "生成完") { if case .result = $0.flow.generation.phase { return true }; return false }
        let before = try XCTUnwrap(c.workResultContext.layout)
        let d = c.state.flow.settings.density
        c.send(.backToSettings)
        c.setDensity(d == .fine ? .coarse : .fine)
        gen.gate.set(gate)
        Task { await c.generateTapped() }
        await gate.reached.wait()
        XCTAssertEqual(c.settingsPrimaryAction, .start, "生成中不是「完成」")
        c.settingsDoneTapped()
        XCTAssertTrue(c.state.isGenerating, "生成中点 done 无效")
        c.send(.cancelTapped); c.send(.cancelConfirmed)
        await gate.release.open(); await c.settle()
        XCTAssertEqual(c.state.flow.generation.phase, .idle)
        XCTAssertEqual(c.settingsPrimaryAction, .start, "密度还是改过的")
        c.setDensity(d)
        XCTAssertEqual(c.settingsPrimaryAction, .done)
        c.settingsDoneTapped(); await c.settle()
        XCTAssertEqual(c.workResultContext.layout?.cellAssignments, before.cellAssignments)
        c.stop()
    }

    // MARK: 作品 id 跟着结果走

    private func works(_ c: AppCoordinator) async -> WorksController {
        let images = FakeWorkImages()
        let w = WorksController(store: FileWorksStore(directory: makeTempDir().appendingPathComponent("Works"), images: images),
                                existence: FakeExistence(), images: images)
        w.attach(resultContext: { [weak c] in c!.workResultContext }, relay: ExportSuccessRelay())
        await w.start()
        w.resultDidChange(revision: c.state.resultRevision)
        return w
    }

    func testSavedThenAlphaRoundTripNeedsUpdateThenUpdatesSameWork() async throws {
        let (_, c) = try await generated()
        let w = await works(c)
        await w.saveCurrentResultTapped()
        guard case .saved(let id) = w.state.saveStatus else { return XCTFail("应已存") }
        XCTAssertEqual(w.currentWorkID, id)

        c.send(.backToSettings); w.resultContextDidChange()
        c.setOverlayAlpha(min(OverlayBlendLimits.maxAlpha, c.state.flow.settings.overlayAlpha + 0.1))
        c.settingsDoneTapped(); await c.settle()
        w.resultDidChange(revision: c.state.resultRevision); w.resultContextDidChange()
        XCTAssertEqual(w.state.saveStatus, .needsUpdate(id), "回来后按钮是「更新这张作品」")
        XCTAssertEqual(w.currentWorkID, id, "经过「再调一调」来回，作品 id 不丢")
        await w.saveCurrentResultTapped()
        XCTAssertEqual(w.state.saveStatus, .saved(id))
        XCTAssertEqual(w.state.toast, .worksUpdated)
        XCTAssertEqual(w.state.summaries.map(\.id), [id])

        // 往返但没改强度：仍是已存
        c.send(.backToSettings); c.settingsDoneTapped(); await c.settle()
        w.resultContextDidChange()
        XCTAssertEqual(w.state.saveStatus, .saved(id))

        // 换一种拼法：新结果，id 清掉，按钮回到「存到我的作品」
        c.send(.reshuffleTapped); await c.settle()
        await waitFor(c, "换拼法完") { if case .result = $0.flow.generation.phase { return true }; return false }
        w.resultDidChange(revision: c.state.resultRevision)
        XCTAssertNil(w.currentWorkID)
        XCTAssertEqual(w.state.saveStatus, .idle)
        w.stop(); c.stop()
    }

    func testUnsavedAlphaRoundTripStaysUnsaved() async throws {
        let (_, c) = try await generated()
        let w = await works(c)
        c.send(.backToSettings); c.setOverlayAlpha(0.2)
        XCTAssertEqual(c.settingsPrimaryAction, .done, "没存过的结果也一样：只改强度 → 完成")
        c.settingsDoneTapped(); await c.settle()
        w.resultContextDidChange()
        XCTAssertEqual(w.state.saveStatus, .idle)
        await w.saveCurrentResultTapped()
        XCTAssertEqual(w.state.count, 1)
        w.stop(); c.stop()
    }

    func testDensityChangeAfterSaveIsNewWork() async throws {
        let (_, c) = try await generated()
        let w = await works(c)
        await w.saveCurrentResultTapped()
        let d = c.state.flow.settings.density
        c.send(.backToSettings)
        c.setDensity(d == .fine ? .coarse : .fine)
        await c.generateTapped(); await c.settle()
        await waitFor(c, "重新生成完") { if case .result = $0.flow.generation.phase { return true }; return false }
        w.resultDidChange(revision: c.state.resultRevision)
        XCTAssertNil(w.currentWorkID)
        XCTAssertEqual(w.state.saveStatus, .idle)
        await w.saveCurrentResultTapped()
        XCTAssertEqual(w.state.count, 2, "改了密度：另存一张")
        w.stop(); c.stop()
    }

    // MARK: 命中哪一份（B10.12）

    func testSaveTargetPrefersRememberedThenMaxUpdatedAtOrCreatedAt() {
        func s(_ created: TimeInterval, _ updated: TimeInterval?, fp: String = "x") -> WorkSummary {
            var m = WorkMeta(id: WorkID(), createdAt: Date(timeIntervalSince1970: created), columns: 1, rows: 1, tier: nil,
                             photoCount: 1, missingCount: 0, overlayAlpha: 0, seed: nil, fingerprint: fp, origin: .savedManually,
                             previewFile: "preview.jpg", previewPixelWidth: 1, previewPixelHeight: 1, targetFile: nil)
            m.updatedAt = updated.map { Date(timeIntervalSince1970: $0) }
            return WorkSummary(meta: m, previewURL: URL(fileURLWithPath: "/tmp/p.jpg"))
        }
        let older = s(100, 500), newer = s(200, nil), other = s(900, nil, fp: "y")
        let list = [other, newer, older]   // 列表按 createdAt 倒序
        XCTAssertEqual(WorkSummary.saveTarget(in: list, fingerprint: "x")?.id, older.id, "updatedAt 500 > createdAt 200")
        XCTAssertEqual(WorkSummary.saveTarget(in: [other, newer, s(50, nil)], fingerprint: "x")?.id, newer.id, "都没 updatedAt → createdAt 最新")
        XCTAssertEqual(WorkSummary.saveTarget(in: list, fingerprint: "x", preferred: newer.id)?.id, newer.id, "结果页记住的优先")
        XCTAssertEqual(WorkSummary.saveTarget(in: list, fingerprint: "x", preferred: other.id)?.id, older.id, "记住的指纹不同 → 不用它")
        XCTAssertNil(WorkSummary.saveTarget(in: list, fingerprint: "z"))
    }
}
