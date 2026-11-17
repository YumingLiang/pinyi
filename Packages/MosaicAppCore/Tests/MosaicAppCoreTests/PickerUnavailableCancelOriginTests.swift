import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// `picker.unavailable` 弹窗「取消」= 回到发起「再拼一张」的那一页（copy v1.6：回到发起页，当前结果保留）。
/// 三个发起页：预览页、作品查看页、「再调一调」设置页。原结果、作品、「已存」状态都不变。
@MainActor
final class PickerUnavailableCancelOriginTests: XCTestCase {
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
        func sync() {
            works.resultDidChange(revision: c.state.resultRevision)
            works.resultContextDidChange()
        }
        func save() async throws -> WorkID {
            await works.saveCurrentResultTapped()
            guard case .saved(let id) = works.state.saveStatus else { throw XCTSkip("没存上") }
            return id
        }
        /// 选到一张用不了的照片，点「取消」。
        func unavailableThenCancel() {
            XCTAssertEqual(c.state.flow.step, .target, "在选图页")
            c.pickedTargetUnavailable()
            XCTAssertTrue(c.state.showsPickerUnavailable)
            c.pickerUnavailableCancelTapped(); sync()
            XCTAssertFalse(c.state.showsPickerUnavailable)
            XCTAssertFalse(c.state.flow.isQuickAgain)
            XCTAssertFalse(c.state.flow.isFreshQuickStart)
            XCTAssertNil(c.pendingTarget)
            XCTAssertNil(c.quickStartOrigin)
        }
        func stop() { works.stop(); c.stop() }
    }

    // MARK: 预览页

    func testFromPreviewSavedReturnsToPreview() async throws {
        let f = Fixture()
        try await f.generate()
        let id = try await f.save()
        let rev = f.c.state.resultRevision
        f.c.startNewMosaicTapped()
        XCTAssertEqual(f.c.quickStartOrigin, .preview)
        f.unavailableThenCancel()
        XCTAssertEqual(f.c.state.flow.step, .result, "回原预览页")
        XCTAssertTrue(f.c.state.hasResult)
        XCTAssertEqual(f.c.state.resultRevision, rev)
        XCTAssertEqual(f.works.state.saveStatus, .saved(id), "已存状态不变")
        XCTAssertNil(f.c.state.reopenWorkRequest, "不去作品查看页")
        f.stop()
    }

    func testFromPreviewUnsavedDiscardStillKeepsResult() async throws {
        let f = Fixture()
        try await f.generate()
        let rev = f.c.state.resultRevision
        f.c.startNewMosaicTapped()
        f.c.unsavedPromptDiscard()
        f.unavailableThenCancel()
        XCTAssertEqual(f.c.state.flow.step, .result)
        XCTAssertTrue(f.c.state.hasResult, "没开始生成，原结果还在")
        XCTAssertEqual(f.c.state.resultRevision, rev)
        XCTAssertEqual(f.works.state.count, 0, "没存的还是没存")
        XCTAssertNotEqual(f.c.currentUnsavedPrompt, .none)
        f.stop()
    }

    // MARK: 作品查看页

    /// 主流程停在结果页时从作品查看页发起：主流程回到原预览页，平台层重新打开那张作品的查看页。
    func testFromWorkViewerWhileOnResultReturnsToWorkViewer() async throws {
        let f = Fixture()
        try await f.generate()
        let id = try await f.save()
        let rev = f.c.state.resultRevision
        f.c.startNewFromWorkTapped(workID: id)
        XCTAssertNil(f.c.state.unsavedPrompt)
        XCTAssertTrue(f.c.state.flow.isQuickAgain)
        XCTAssertEqual(f.c.quickStartOrigin, .work(id: id))
        f.unavailableThenCancel()
        XCTAssertEqual(f.c.state.reopenWorkRequest, WorkReopenRequest(workID: id, token: 1), "回作品查看页")
        XCTAssertEqual(f.c.state.flow.step, .result, "查看页下面的主流程仍是原预览页")
        XCTAssertTrue(f.c.state.hasResult)
        XCTAssertEqual(f.c.state.resultRevision, rev)
        XCTAssertEqual(f.works.state.saveStatus, .saved(id))
        XCTAssertEqual(f.works.state.count, 1)

        // 第二次：token 递增，平台层能再触发
        f.c.startNewFromWorkTapped(workID: id)
        f.unavailableThenCancel()
        XCTAssertEqual(f.c.state.reopenWorkRequest, WorkReopenRequest(workID: id, token: 2))
        f.stop()
    }

    /// 主流程没有结果（比如停在来源页）时从作品查看页发起：主流程回到进来前那一页，目标图不动，重新打开查看页。
    func testFromWorkViewerWithoutResultRestoresMainFlowAndReopensViewer() async throws {
        let f = Fixture()
        let c = f.c
        c.resultSaver = f.works
        c.start(); await c.settle()
        c.setTarget(try CoordinatorHarness.target())
        c.flowSend(.next)
        XCTAssertEqual(c.state.flow.step, .source)
        let targetBefore = c.target.map { [$0.width, $0.height, $0.bytes.count] }
        let w1 = WorkID()
        c.startNewFromWorkTapped(workID: w1)
        XCTAssertTrue(c.state.flow.isFreshQuickStart)
        XCTAssertEqual(c.quickStartOrigin, .work(id: w1))
        f.unavailableThenCancel()
        XCTAssertEqual(c.state.reopenWorkRequest?.workID, w1)
        XCTAssertEqual(c.state.flow.step, .source, "主流程回到进来前那一页")
        XCTAssertTrue(c.state.flow.hasTarget, "原来选的目标图还在")
        XCTAssertNotNil(c.target)
        XCTAssertTrue(c.target.map { [$0.width, $0.height, $0.bytes.count] } == targetBefore)
        f.stop()
    }

    // MARK: 「再调一调」设置页（验收 7a）

    func testFromAdjustUnsavedReturnsToAdjustPageKeepingResult() async throws {
        let f = Fixture()
        try await f.generate()
        let rev = f.c.state.resultRevision
        f.c.send(.backToSettings); f.sync()
        XCTAssertTrue(f.c.isAdjustingResult)
        f.c.startNewFromWorkTapped(workID: WorkID())
        XCTAssertEqual(f.c.state.unsavedPrompt, .startNewFromAdjust)
        f.c.unsavedPromptDiscard()
        XCTAssertTrue(f.c.state.flow.isFreshQuickStart)
        XCTAssertEqual(f.c.quickStartOrigin, .adjust)
        f.unavailableThenCancel()
        XCTAssertEqual(f.c.state.flow.step, .settings, "回到「再调一调」设置页")
        XCTAssertTrue(f.c.isAdjustingResult, "结果还留着")
        XCTAssertEqual(f.c.settingsPrimaryAction, .done, "还能「完成」回原结果")
        XCTAssertTrue(f.c.state.flow.hasTarget)
        XCTAssertEqual(f.c.state.resultRevision, rev)
        XCTAssertEqual(f.works.state.count, 0)
        XCTAssertNil(f.c.state.reopenWorkRequest, "发起页是设置页，不去作品查看页")
        await f.c.adjustDoneTapped(); await f.c.settle()
        XCTAssertEqual(f.c.state.flow.step, .result, "「完成」照常回到原结果")
        f.stop()
    }

    func testFromAdjustSavedKeepsSavedStatus() async throws {
        let f = Fixture()
        try await f.generate()
        let id = try await f.save()
        f.c.send(.backToSettings); f.sync()
        f.c.startNewFromWorkTapped(workID: id)
        XCTAssertNil(f.c.state.unsavedPrompt, "已存且没改：不弹")
        XCTAssertEqual(f.c.quickStartOrigin, .adjust)
        f.unavailableThenCancel()
        XCTAssertEqual(f.c.state.flow.step, .settings)
        XCTAssertTrue(f.c.isAdjustingResult)
        XCTAssertEqual(f.works.state.saveStatus, .saved(id))
        XCTAssertEqual(f.c.currentUnsavedPrompt, .none)
        f.stop()
    }

    /// 系统收起弹窗（没点按钮）按「取消」处理，同样回发起页。
    func testDismissAlsoReturnsToOrigin() async throws {
        let f = Fixture()
        try await f.generate()
        let id = try await f.save()
        f.c.startNewFromWorkTapped(workID: id)
        f.c.pickedTargetUnavailable()
        await f.c.pickerUnavailableDismissed()?.value
        XCTAssertFalse(f.c.state.showsPickerUnavailable)
        XCTAssertEqual(f.c.state.flow.step, .result)
        XCTAssertEqual(f.c.state.reopenWorkRequest?.workID, id)
        f.stop()
    }

    /// 选到能用的照片、开始生成之后，发起页记录清掉（之后的普通流程「取消」不会跳回去）。
    func testOriginClearedOnceNewMosaicStarts() async throws {
        let f = Fixture()
        try await f.generate()
        _ = try await f.save()
        f.c.startNewFromWorkTapped(workID: WorkID())
        f.c.setTarget(try CoordinatorHarness.target())
        await f.c.generateTapped(); await f.c.settle()
        XCTAssertNil(f.c.quickStartOrigin)
        f.stop()
    }
}
