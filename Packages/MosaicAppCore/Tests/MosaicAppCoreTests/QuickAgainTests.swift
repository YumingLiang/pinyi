import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 「存到我的作品」的替身：可设「已存」/「存过但强度改了」、可让保存失败、记录调用次数。
@MainActor
final class FakeResultSaver: CurrentResultSaving {
    var savedRevision: Int?
    /// 存过的作品只改了叠加强度还没存（B10-11）。
    var alphaChangedWork: WorkID?
    var saveSucceeds = true
    var saveCalls = 0
    weak var coordinator: AppCoordinator?
    var unsavedPrompt: UnsavedPrompt {
        guard let rev = coordinator?.state.resultRevision, savedRevision == rev else { return .unsaved }
        return alphaChangedWork.map { .alphaChanged($0) } ?? .none
    }
    func saveCurrentResult() async -> Bool {
        saveCalls += 1
        guard saveSucceeds else { return false }
        savedRevision = coordinator?.state.resultRevision
        alphaChangedWork = nil
        return true
    }
}

/// 预览页「再拼一张」（需求 v0.4 §2b / §2e，验收 2e 第 6–9 条）。
@MainActor
final class QuickAgainTests: XCTestCase {
    private func generated(_ h: CoordinatorHarness) async throws {
        h.coordinator.setTarget(try CoordinatorHarness.target())
        h.coordinator.start()
        await h.coordinator.settle()
        await h.coordinator.generateTapped()
        await h.coordinator.settle()
        guard case .result = h.coordinator.state.flow.generation.phase else { return XCTFail("没有结果") }
    }

    private func saver(_ c: AppCoordinator) -> FakeResultSaver {
        let s = FakeResultSaver()
        s.coordinator = c
        c.resultSaver = s
        return s
    }

    /// 另一张目标图（与 `CoordinatorHarness.target()` 尺寸不同，便于区分）。
    private func otherTarget() throws -> PixelBuffer {
        try PixelBuffer(width: 40, height: 40, bytes: [UInt8](repeating: 128, count: 40 * 40 * 4))
    }

    // MARK: 已保存 → 直接去选图；返回能恢复

    func testSavedResultGoesStraightToTargetAndBackRestoresResult() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let s = saver(c)
        try await generated(h)
        let product = c.product
        let rev = c.state.resultRevision
        s.savedRevision = rev                       // 点过「存到我的作品」
        XCTAssertTrue(c.state.canStartNewMosaic)

        c.startNewMosaicTapped()
        XCTAssertNil(c.state.unsavedPrompt, "已存的结果不弹提示（验收 7）")
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertTrue(c.state.flow.isQuickAgain)
        XCTAssertFalse(c.state.flow.hasTarget, "要重新选目标图")
        // 结果还在（还没开始生成新图）
        XCTAssertNotNil(c.product)
        XCTAssertTrue(c.state.hasResult)
        guard case .result = c.state.flow.generation.phase else { return XCTFail() }

        // 选图页返回 → 原预览页，结果和「已存」都不变（验收 8）
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertFalse(c.state.flow.isQuickAgain)
        XCTAssertTrue(c.state.flow.hasTarget)
        XCTAssertEqual(c.state.resultRevision, rev)
        XCTAssertTrue(c.isCurrentResultKept)
        XCTAssertEqual(c.product?.outcome, product?.outcome)
        c.stop()
    }

    /// 导出过不算存过（AndyL 22:20、hd-export B10-4）：导出成功后点「再拼一张」照样弹 `quick.unsaved.title`。
    func testExportedButUnsavedResultStillPrompts() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        _ = saver(c)
        try await generated(h)
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(c.state.export, .saved)
        c.dismissExportResult()
        c.startNewMosaicTapped()
        XCTAssertEqual(c.state.unsavedPrompt, .startNew, "导出过不算存过，照样弹")
        XCTAssertFalse(c.state.unsavedPromptIsUpdate)
        XCTAssertEqual(c.state.unsavedPromptTitle, .quickUnsavedTitle)
        XCTAssertEqual(c.state.flow.step, .result)
        c.stop()
    }

    /// 选好新目标图直接进确认页（素材沿用），确认页返回 → 选图页 → 预览页；旧目标图一直没被换掉。
    func testPickingTargetGoesToConfirmAndBackTwiceReturnsToPreview() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let s = saver(c)
        try await generated(h)
        s.savedRevision = c.state.resultRevision
        let oldTargetWidth = c.target?.width
        c.startNewMosaicTapped()
        c.setTarget(try otherTarget())
        XCTAssertEqual(c.state.flow.step, .settings, "选一张后直接进确认页（2b，≤ 3 次点击）")
        XCTAssertEqual(c.target?.width, oldTargetWidth, "旧结果的目标图不动（存作品 / 预览叠加还要用）")
        XCTAssertEqual(c.pendingTarget?.width, 40)
        // 确认页「换素材」→ 来源页，「下一步」/返回都回确认页
        c.flowSend(.changeSource)
        XCTAssertEqual(c.state.flow.step, .source)
        c.flowSend(.next)
        XCTAssertEqual(c.state.flow.step, .settings)
        c.flowSend(.changeSource)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .settings)
        // 确认页返回 → 选图页 → 预览页
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .target)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertTrue(c.state.hasResult)
        XCTAssertEqual(c.target?.width, oldTargetWidth)
        c.stop()
    }

    // MARK: 未保存提示三个分支

    func testUnsavedPromptCancelKeepsEverything() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let s = saver(c)
        try await generated(h)
        let before = c.state
        c.startNewMosaicTapped()
        XCTAssertEqual(c.state.unsavedPrompt, .startNew)
        XCTAssertFalse(c.state.canStartNewMosaic, "提示弹着时不能再点")
        c.unsavedPromptCancel()
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(c.state, before, "取消：留在预览页，什么都不变")
        XCTAssertEqual(s.saveCalls, 0)
        c.stop()
    }

    func testUnsavedPromptDiscardGoesToTargetButKeepsResultUntilGeneration() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let s = saver(c)
        try await generated(h)
        c.startNewMosaicTapped()
        c.unsavedPromptDiscard()
        XCTAssertEqual(s.saveCalls, 0)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertTrue(c.state.hasResult, "「不保存」也要等真正开始生成新图才丢")
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result, "返回仍能回到原预览页")
        c.stop()
    }

    func testUnsavedPromptSaveSuccessContinuesToTarget() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let s = saver(c)
        try await generated(h)
        c.startNewMosaicTapped()
        await c.unsavedPromptSave()
        XCTAssertEqual(s.saveCalls, 1)
        XCTAssertFalse(c.state.isSavingBeforeLeaving)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertTrue(c.isCurrentResultKept)
        c.stop()
    }

    func testUnsavedPromptSaveFailureStaysOnPreview() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let s = saver(c)
        s.saveSucceeds = false
        try await generated(h)
        let rev = c.state.resultRevision
        c.startNewMosaicTapped()
        await c.unsavedPromptSave()
        XCTAssertEqual(s.saveCalls, 1)
        XCTAssertEqual(c.state.flow.step, .result, "存失败留在预览页")
        XCTAssertFalse(c.state.flow.isQuickAgain)
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(c.state.resultRevision, rev)
        XCTAssertTrue(c.state.hasResult)
        XCTAssertTrue(c.state.canStartNewMosaic, "可以再点一次")
        c.stop()
    }

    /// 返回首页等会丢结果的离开方式同样弹提示；「再调一调」「换一种拼法」不弹（验收 9）。
    func testLeaveResultPromptsButAdjustAndReshuffleDoNot() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        _ = saver(c)
        try await generated(h)
        c.leaveResultTapped()
        XCTAssertEqual(c.state.unsavedPrompt, .leaveResult)
        c.unsavedPromptCancel()
        XCTAssertEqual(c.state.flow.step, .result)

        c.send(.reshuffleTapped)
        XCTAssertNil(c.state.unsavedPrompt)
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail() }
        c.send(.backToSettings)
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(c.state.flow.step, .settings)
        c.flowSend(.next)   // 设置页没有「下一步」，状态不变
        c.stop()
    }

    func testLeaveResultDiscardReturnsToStartAndReleasesResult() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        _ = saver(c)
        try await generated(h)
        let rev = c.state.resultRevision
        c.leaveResultTapped()
        c.unsavedPromptDiscard()
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertEqual(c.state.flow.generation.phase, .idle)
        XCTAssertNil(c.product)
        XCTAssertFalse(c.state.hasResult, "预览位图由平台层据此释放")
        XCTAssertGreaterThan(c.state.resultRevision, rev)
        c.stop()
    }

    // MARK: 开始生成新图时才清空

    func testStartingNewGenerationDiscardsOldResultThenProducesNew() async throws {
        let ggate = GatePoint()
        let gen = GatedGenerator()
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        let s = saver(c)
        try await generated(h)
        s.savedRevision = c.state.resultRevision
        let rev = c.state.resultRevision
        c.startNewMosaicTapped()
        c.setTarget(try otherTarget())
        XCTAssertTrue(c.state.hasResult, "到确认页结果还在")

        gen.gate.set(ggate)
        let started = Task { await c.generateTapped() }
        await ggate.reached.wait()
        // 生成中：旧结果已丢、新目标图已换上、按钮不可点
        XCTAssertNil(c.product)
        XCTAssertFalse(c.state.hasResult)
        XCTAssertFalse(c.state.flow.isQuickAgain)
        XCTAssertEqual(c.target?.width, 40)
        XCTAssertNil(c.pendingTarget)
        XCTAssertGreaterThan(c.state.resultRevision, rev)
        XCTAssertFalse(c.isCurrentResultKept, "新结果出来前「已存」状态作废")
        XCTAssertFalse(c.state.canStartNewMosaic, "生成中不能点")
        c.startNewMosaicTapped()
        XCTAssertNil(c.state.unsavedPrompt, "生成中调用被忽略")
        gen.gate.set(nil)
        await ggate.release.open()
        await started.value
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertNotNil(c.product)
        XCTAssertEqual(c.product?.generation.layout.columns ?? 0 > 0, true)
        XCTAssertEqual(gen.calls.get(), 2)
        c.stop()
    }

    /// 照片少于 200 张：确认页弹「照片比较少」，点「返回」不丢旧结果（还没开始生成）。
    func testShortageBackFromQuickAgainKeepsOldResult() async throws {
        let h = CoordinatorHarness(assets: 150)
        let c = h.coordinator
        let s = saver(c)
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        await c.generateTapped()
        XCTAssertTrue(c.state.flow.generation.shortagePrompt)
        c.send(.shortageContinue)
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail() }
        s.savedRevision = c.state.resultRevision
        c.startNewMosaicTapped()
        c.setTarget(try otherTarget())
        await c.generateTapped()
        XCTAssertTrue(c.state.flow.generation.shortagePrompt)
        XCTAssertTrue(c.state.hasResult, "提示还没确认，旧结果还在")
        c.send(.shortageBack)
        guard case .result = c.state.flow.generation.phase else { return XCTFail("\(c.state.flow.generation.phase)") }
        XCTAssertEqual(c.state.flow.step, .settings, "回到确认页")
        XCTAssertTrue(c.state.hasResult)
        c.flowSend(.back); c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        c.stop()
    }

    // MARK: 生成中 / 导出中调用安全

    func testIgnoredWhileExporting() async throws {
        let egate = GatePoint()
        let h = CoordinatorHarness(assets: 300, exporter: FakeExporter(gate: egate))
        let c = h.coordinator
        _ = saver(c)
        try await generated(h)
        await c.saveTapped()
        await egate.reached.wait()
        XCTAssertFalse(c.state.canStartNewMosaic, "导出中按钮禁用")
        c.startNewMosaicTapped()
        c.leaveResultTapped()
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(c.state.flow.step, .result)
        await egate.release.open()
        await c.settle()
        c.stop()
    }

    func testIgnoredOutsideResultPage() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        _ = saver(c)
        c.startNewMosaicTapped()
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertFalse(c.state.flow.isQuickAgain)
        // 没结果时直接发事件也不进入「再拼一张」
        var f = MainFlow(initialSeed: 1)
        f.send(.quickAgainStarted)
        XCTAssertFalse(f.isQuickAgain)
        XCTAssertEqual(f.step, .target)
    }

    /// 素材选择在「再拼一张」后保留（确认页沿用上次）。
    func testSourceSelectionKeptAcrossQuickAgain() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let s = saver(c)
        try await generated(h)
        s.savedRevision = c.state.resultRevision
        let source = c.state.flow.source
        let settings = c.state.flow.settings
        c.startNewMosaicTapped()
        c.setTarget(try otherTarget())
        XCTAssertEqual(c.state.flow.source, source)
        XCTAssertEqual(c.state.flow.settings, settings)
        c.stop()
    }

    /// 真的 `WorksController` 当 `resultSaver`：未保存 → 弹提示 →「保存」真的存进作品库 → 进选图页；返回后「已存」状态还在。
    func testWithRealWorksController() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        try await generated(h)
        let images = FakeWorkImages()
        let works = WorksController(store: FileWorksStore(directory: makeTempDir(), images: images), existence: FakeExistence(),
                                    images: images)
        works.attach(resultContext: { [weak c] in c!.workResultContext }, relay: ExportSuccessRelay())
        await works.start()
        works.resultDidChange(revision: c.state.resultRevision)
        c.resultSaver = works
        XCTAssertFalse(c.isCurrentResultKept)
        c.startNewMosaicTapped()
        XCTAssertEqual(c.state.unsavedPrompt, .startNew)
        await c.unsavedPromptSave()
        XCTAssertEqual(works.state.count, 1)
        XCTAssertEqual(c.state.flow.step, .target)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        guard case .saved = works.state.saveStatus else { return XCTFail("\(works.state.saveStatus)") }
        c.startNewMosaicTapped()
        XCTAssertNil(c.state.unsavedPrompt, "存过之后不再弹")
        works.stop()
        c.stop()
    }

    func testQuickKeysExistInStringsFile() throws {
        let keys = try L10nKeyTests.stringsKeys()
        XCTAssertEqual(L10nKey.allQuick.map(\.rawValue).filter { !keys.contains($0) }, [])
    }
}
