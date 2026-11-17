import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 「再拼一张」未保存提示，用真的 `WorksController`（quick-start v1.0 §2e + hd-export B10-4/11）：
/// 已存且没改 → 不弹；没存（导出过也算没存）→ `quick.unsaved.title`；存过但只改了叠加强度 → `quick.unsaved.update_title`，
/// 「保存」= 更新原作品。每种情况都覆盖「保存后继续 / 不保存 / 取消」。另有作品查看页入口（§2a）。
@MainActor
final class QuickAgainUnsavedRulesTests: XCTestCase {
    @MainActor private final class Fixture {
        let h = CoordinatorHarness(assets: 300)
        let works: WorksController
        var c: AppCoordinator { h.coordinator }
        init() {
            let images = FakeWorkImages()
            works = WorksController(store: FileWorksStore(directory: makeTempDir().appendingPathComponent("Works"), images: images),
                                    existence: FakeExistence(), images: images)
        }
        func generate() async throws {
            let c = self.c
            works.attach(resultContext: { [weak c] in c!.workResultContext }, relay: ExportSuccessRelay())
            c.resultSaver = works
            c.setTarget(try CoordinatorHarness.target()); c.start(); await c.settle()
            await c.generateTapped(); await c.settle()
            await waitFor(c, "结果") { if case .result = $0.flow.generation.phase { return true }; return false }
            await works.start()
            sync()
        }
        /// 平台层（AppModel）在状态变化时做的事。
        func sync() {
            works.resultDidChange(revision: c.state.resultRevision)
            works.resultContextDidChange()
        }
        /// 存了之后「再调一调」只改强度 →「完成」回来。
        func adjustAlpha(by d: Double) async {
            c.send(.backToSettings); sync()
            c.setOverlayAlpha(min(OverlayBlendLimits.maxAlpha, c.state.flow.settings.overlayAlpha + d))
            await c.adjustDoneTapped(); await c.settle(); sync()
        }
        func stop() { works.stop(); c.stop() }
    }

    // MARK: 已存且没改

    func testSavedUnchangedDoesNotPrompt() async throws {
        let f = Fixture()
        try await f.generate()
        await f.works.saveCurrentResultTapped()
        f.c.startNewMosaicTapped()
        XCTAssertNil(f.c.state.unsavedPrompt)
        XCTAssertEqual(f.c.state.flow.step, .target)
        XCTAssertTrue(f.c.state.flow.autoOpensTargetPicker)
        f.stop()
    }

    // MARK: 没存

    func testUnsavedSaveThenContinue() async throws {
        let f = Fixture()
        try await f.generate()
        f.c.startNewMosaicTapped()
        XCTAssertEqual(f.c.state.unsavedPrompt, .startNew)
        XCTAssertEqual(f.c.state.unsavedPromptTitle, .quickUnsavedTitle)
        await f.c.unsavedPromptSave()
        XCTAssertEqual(f.works.state.count, 1, "保存 = 新存一份")
        XCTAssertEqual(f.c.state.flow.step, .target, "存成功后继续去选图")
        XCTAssertNil(f.c.state.unsavedPrompt)
        f.c.flowSend(.back); f.sync()
        XCTAssertEqual(f.c.state.flow.step, .result)
        guard case .saved = f.works.state.saveStatus else { return XCTFail("\(f.works.state.saveStatus)") }
        f.stop()
    }

    func testUnsavedDiscardContinuesWithoutSaving() async throws {
        let f = Fixture()
        try await f.generate()
        f.c.startNewMosaicTapped()
        f.c.unsavedPromptDiscard()
        XCTAssertEqual(f.works.state.count, 0)
        XCTAssertEqual(f.c.state.flow.step, .target)
        XCTAssertTrue(f.c.state.hasResult, "开始生成新图前结果还在")
        f.stop()
    }

    func testUnsavedCancelStays() async throws {
        let f = Fixture()
        try await f.generate()
        f.c.startNewMosaicTapped()
        f.c.unsavedPromptCancel()
        XCTAssertNil(f.c.state.unsavedPrompt)
        XCTAssertEqual(f.c.state.flow.step, .result)
        XCTAssertEqual(f.works.state.count, 0)
        XCTAssertTrue(f.c.state.canStartNewMosaic)
        f.stop()
    }

    func testExportedButUnsavedStillPrompts() async throws {
        let f = Fixture()
        try await f.generate()
        await f.c.saveTapped(); await f.c.settle()
        XCTAssertEqual(f.c.state.export, .saved)
        f.c.dismissExportResult(); f.sync()
        XCTAssertEqual(f.works.state.count, 0, "导出不自动存")
        f.c.startNewMosaicTapped()
        XCTAssertEqual(f.c.state.unsavedPrompt, .startNew, "导出过不算存过")
        f.stop()
    }

    // MARK: 存过但只改了叠加强度（needsUpdate）

    func testNeedsUpdateSaveUpdatesOriginalThenContinues() async throws {
        let f = Fixture()
        try await f.generate()
        await f.works.saveCurrentResultTapped()
        guard case .saved(let id) = f.works.state.saveStatus else { return XCTFail() }
        await f.adjustAlpha(by: 0.1)
        XCTAssertEqual(f.works.state.saveStatus, .needsUpdate(id))
        let alpha = f.c.state.flow.settings.overlayAlpha

        f.c.startNewMosaicTapped()
        XCTAssertEqual(f.c.state.unsavedPrompt, .startNew)
        XCTAssertTrue(f.c.state.unsavedPromptIsUpdate)
        XCTAssertEqual(f.c.state.unsavedPromptTitle, .quickUnsavedUpdateTitle)
        await f.c.unsavedPromptSave()
        XCTAssertEqual(f.works.state.summaries.map(\.id), [id], "保存 = 更新原作品，不另存")
        XCTAssertEqual(f.works.state.summaries.first?.meta.overlayAlpha ?? -1, alpha, accuracy: 1e-9)
        XCTAssertEqual(f.works.state.toast, .worksUpdated)
        XCTAssertEqual(f.c.state.flow.step, .target)
        XCTAssertFalse(f.c.state.unsavedPromptIsUpdate)
        f.c.flowSend(.back); f.sync()
        XCTAssertEqual(f.works.state.saveStatus, .saved(id))
        f.stop()
    }

    func testNeedsUpdateDiscardLeavesOriginal() async throws {
        let f = Fixture()
        try await f.generate()
        await f.works.saveCurrentResultTapped()
        let original = try XCTUnwrap(f.works.state.summaries.first)
        await f.adjustAlpha(by: 0.1)
        f.c.startNewMosaicTapped()
        XCTAssertTrue(f.c.state.unsavedPromptIsUpdate)
        f.c.unsavedPromptDiscard()
        XCTAssertEqual(f.c.state.flow.step, .target)
        XCTAssertEqual(f.works.state.summaries.map(\.id), [original.id])
        XCTAssertEqual(f.works.state.summaries.first?.meta.overlayAlpha, original.meta.overlayAlpha, "不保存：原作品不动")
        f.stop()
    }

    func testNeedsUpdateCancelStaysNeedsUpdate() async throws {
        let f = Fixture()
        try await f.generate()
        await f.works.saveCurrentResultTapped()
        guard case .saved(let id) = f.works.state.saveStatus else { return XCTFail() }
        await f.adjustAlpha(by: 0.1)
        f.c.startNewMosaicTapped()
        f.c.unsavedPromptCancel()
        XCTAssertEqual(f.c.state.flow.step, .result)
        XCTAssertFalse(f.c.state.unsavedPromptIsUpdate)
        XCTAssertEqual(f.works.state.saveStatus, .needsUpdate(id))
        f.stop()
    }

    /// 改了强度又改回去 → 和存的一样，不弹。
    func testAlphaChangedBackDoesNotPrompt() async throws {
        let f = Fixture()
        try await f.generate()
        let a0 = f.c.state.flow.settings.overlayAlpha
        await f.works.saveCurrentResultTapped()
        await f.adjustAlpha(by: 0.1)
        f.c.send(.backToSettings); f.c.setOverlayAlpha(a0); await f.c.adjustDoneTapped(); await f.c.settle(); f.sync()
        f.c.startNewMosaicTapped()
        XCTAssertNil(f.c.state.unsavedPrompt)
        f.stop()
    }

    /// 新图开始生成后旧结果丢掉、作品 id 清掉：新结果按钮回到「存到我的作品」。
    func testNewMosaicResultStartsUnsaved() async throws {
        let f = Fixture()
        try await f.generate()
        await f.works.saveCurrentResultTapped()
        f.c.startNewMosaicTapped()
        f.c.setTarget(try PixelBuffer(width: 40, height: 40, bytes: [UInt8](repeating: 90, count: 40 * 40 * 4)))
        XCTAssertEqual(f.c.settingsPrimaryAction, .generate, "「再拼一张」确认页是「开始拼图」，不是「完成」")
        await f.c.generateTapped(); await f.c.settle()
        await waitFor(f.c, "新结果") { if case .result = $0.flow.generation.phase { return true }; return false }
        f.sync()
        XCTAssertEqual(f.c.state.flow.step, .result)
        XCTAssertNil(f.works.currentWorkID)
        XCTAssertEqual(f.works.state.saveStatus, .idle)
        f.c.startNewMosaicTapped()
        XCTAssertEqual(f.c.state.unsavedPrompt, .startNew)
        f.stop()
    }

    // MARK: 作品查看页「再拼一张」（§2a）

    func testFromWorkWhileOnResultUsesSamePrompt() async throws {
        let f = Fixture()
        try await f.generate()
        f.c.startNewFromWorkTapped()
        XCTAssertEqual(f.c.state.unsavedPrompt, .startNew, "主流程停在没存的结果上：同样弹")
        f.c.unsavedPromptDiscard()
        XCTAssertTrue(f.c.state.flow.isQuickAgain)
        XCTAssertEqual(f.c.state.flow.step, .target)
        f.c.startNewFromWorkTapped()                                // 已在选图页：不动
        XCTAssertEqual(f.c.state.flow.step, .target)
        f.stop()
    }

    func testFromWorkWithoutResultGoesToTargetThenConfirm() async throws {
        let f = Fixture()
        let c = f.c
        c.resultSaver = f.works
        c.start(); await c.settle()
        c.selectSource(.allPhotos)
        c.startNewFromWorkTapped()
        XCTAssertNil(c.state.unsavedPrompt, "没有结果：不弹")
        XCTAssertTrue(c.state.flow.isFreshQuickStart)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertTrue(c.state.flow.autoOpensTargetPicker)
        c.setTarget(try CoordinatorHarness.target())
        XCTAssertEqual(c.state.flow.step, .settings, "选好直接进确认页，素材沿用")
        XCTAssertFalse(c.state.flow.autoOpensTargetPicker)
        c.flowSend(.changeSource)
        XCTAssertEqual(c.state.flow.step, .source)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .settings)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .target)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .target, "选图页是起点，没有可返回的预览页")
        c.flowSend(.next)
        XCTAssertEqual(c.state.flow.step, .settings)
        await c.generateTapped(); await c.settle()
        await waitFor(c, "结果") { if case .result = $0.flow.generation.phase { return true }; return false }
        XCTAssertFalse(c.state.flow.isFreshQuickStart, "开始生成后回到普通流程")
        XCTAssertEqual(c.state.flow.step, .result)
        f.stop()
    }

    func testFromWorkIgnoredWhileGenerating() async throws {
        let gate = GatePoint()
        let gen = GatedGenerator(gate: gate)
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.setTarget(try CoordinatorHarness.target()); c.start(); await c.settle()
        let t = Task { await c.generateTapped() }
        await gate.reached.wait()
        c.startNewFromWorkTapped()
        XCTAssertFalse(c.state.flow.isFreshQuickStart)
        XCTAssertNil(c.state.unsavedPrompt)
        await gate.release.open(); await t.value; await c.settle()
        c.stop()
    }
}
