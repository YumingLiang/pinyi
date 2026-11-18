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

    // MARK: 「再调一调」途中进作品页点「再拼一张」（产品 03:16 / 02:35 口径：回作品查看页，「再调一调」进度留在下面）

    func testFromAdjustUnsavedReturnsToWorkViewerKeepingAdjustPage() async throws {
        let f = Fixture()
        try await f.generate()
        let rev = f.c.state.resultRevision
        f.c.send(.backToSettings); f.sync()
        XCTAssertTrue(f.c.isAdjustingResult)
        let wid = WorkID()
        f.c.startNewFromWorkTapped(workID: wid)
        XCTAssertEqual(f.c.state.unsavedPrompt, .startNewFromAdjust)
        f.c.unsavedPromptDiscard()
        XCTAssertTrue(f.c.state.flow.isFreshQuickStart)
        XCTAssertEqual(f.c.quickStartOrigin, .work(id: wid), "点「再拼一张」的是作品查看页")
        f.unavailableThenCancel()
        XCTAssertEqual(f.c.state.reopenWorkRequest?.workID, wid, "回作品查看页")
        XCTAssertEqual(f.c.state.flow.step, .settings, "查看页下面的主流程是「再调一调」设置页")
        XCTAssertTrue(f.c.isAdjustingResult, "结果还留着")
        XCTAssertEqual(f.c.settingsPrimaryAction, .done, "还能「完成」回原结果")
        XCTAssertTrue(f.c.state.flow.hasTarget)
        XCTAssertEqual(f.c.state.resultRevision, rev)
        XCTAssertEqual(f.works.state.count, 0)
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
        XCTAssertEqual(f.c.quickStartOrigin, .work(id: id))
        f.unavailableThenCancel()
        XCTAssertEqual(f.c.state.reopenWorkRequest?.workID, id)
        XCTAssertEqual(f.c.state.flow.step, .settings)
        XCTAssertTrue(f.c.isAdjustingResult)
        XCTAssertEqual(f.works.state.saveStatus, .saved(id))
        XCTAssertEqual(f.c.currentUnsavedPrompt, .none)
        f.stop()
    }

    /// 没有作品 ID 的旧调用、「再调一调」途中：发起页按设置页算，回设置页、不重开查看页。
    func testAdjustWithoutWorkIDReturnsToAdjustPage() async throws {
        let f = Fixture()
        try await f.generate()
        f.c.send(.backToSettings); f.sync()
        f.c.startNewFromWorkTapped()
        f.c.unsavedPromptDiscard()
        XCTAssertEqual(f.c.quickStartOrigin, .adjust)
        f.unavailableThenCancel()
        XCTAssertNil(f.c.state.reopenWorkRequest)
        XCTAssertEqual(f.c.state.flow.step, .settings)
        XCTAssertEqual(f.c.settingsPrimaryAction, .done)
        f.stop()
    }

    // MARK: P1-2 中途选过能用的照片再取消：原目标图、代次原样恢复

    func testPickedValidThenUnavailableCancelRestoresOriginalTarget() async throws {
        let f = Fixture()
        try await f.generate()
        let id = try await f.save()
        let original = f.c.target.map { $0.bytes }
        let generation = f.c.targetGeneration
        f.c.send(.backToSettings); f.sync()
        XCTAssertEqual(f.c.settingsPrimaryAction, .done)
        f.c.startNewFromWorkTapped(workID: id)
        // 选一张能用的（和原图不同）→ 确认页 → 返回选图页
        var other = try CoordinatorHarness.target()
        other = try PixelBuffer(width: other.width, height: other.height, bytes: other.bytes.map { 255 &- $0 })
        f.c.setTarget(other)
        XCTAssertNotEqual(f.c.target.map { $0.bytes }, original, "普通流程选图直接写 target")
        f.c.flowSend(.back)
        // 再选一张用不了的 →「取消」
        f.unavailableThenCancel()
        XCTAssertEqual(f.c.state.reopenWorkRequest?.workID, id)
        XCTAssertEqual(f.c.state.flow.step, .settings)
        XCTAssertEqual(f.c.target.map { $0.bytes }, original, "原目标图放回去")
        XCTAssertEqual(f.c.targetGeneration, generation, "代次也放回去")
        XCTAssertEqual(f.c.settingsPrimaryAction, .done, "主按钮仍是「完成」")
        XCTAssertNil(f.c.targetBeforeFreshQuickStart)
        f.stop()
    }

    /// 开始生成新图后不再恢复：保存的旧目标图清掉。
    func testSnapshotDroppedOnceGenerationStarts() async throws {
        let f = Fixture()
        try await f.generate()
        f.c.send(.backToSettings); f.sync()
        f.c.startNewFromWorkTapped(workID: WorkID())
        f.c.unsavedPromptDiscard()
        XCTAssertNotNil(f.c.targetBeforeFreshQuickStart)
        f.c.setTarget(try CoordinatorHarness.target())
        await f.c.generateTapped(); await f.c.settle()
        XCTAssertNil(f.c.targetBeforeFreshQuickStart)
        XCTAssertNil(f.c.quickStartOrigin)
        f.stop()
    }

    // MARK: P3 作品在取消前被删了：不重开查看页

    func testDeletedWorkIsNotReopened() async throws {
        let f = Fixture()
        try await f.generate()
        let id = try await f.save()
        f.c.startNewFromWorkTapped(workID: id)
        await f.works.deleteConfirmed(id)
        XCTAssertFalse(f.works.hasWork(id))
        f.unavailableThenCancel()
        XCTAssertNil(f.c.state.reopenWorkRequest, "作品已删，不推一个不存在的查看页")
        XCTAssertEqual(f.c.state.flow.step, .result, "停在恢复好的主流程（原预览页）")
        XCTAssertTrue(f.c.state.hasResult)
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

/// 产品 03:25 第 3 条：重新打开的查看页按「作品列表 → 查看页」压在主流程上；返回先到列表，再返回才回主流程（发起前那一页）。
final class WorkReopenRoutesTests: XCTestCase {
    func testRoutesAreListThenDetail() {
        let id = WorkID()
        XCTAssertEqual(WorkReopenRequest(workID: id, token: 1).routes, [.list, .detail(id)])
    }

    /// 平台层：主流程推的是作品列表（带上要重开的作品），列表再推查看页，只推一次。
    func testPlatformPushesListThenDetail() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("App/Views/MainFlowView.swift"), encoding: .utf8)
        let works = try String(contentsOf: root.appendingPathComponent("App/Works/WorksViews.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("WorksListView(reopenWorkID: id)"), "主流程推作品列表")
        XCTAssertFalse(main.contains("{ WorkDetailView(id: id) }"), "主流程不直接推查看页")
        XCTAssertTrue(main.contains("req.routes"))
        XCTAssertTrue(works.contains("var reopenWorkID: WorkID?"))
        XCTAssertTrue(works.contains("navigationDestination(isPresented: $reopenedDetailShown)"))
        XCTAssertTrue(works.contains("guard reopenWorkID != nil, !didReopen"), "列表只自动推一次（从查看页返回后留在列表）")
    }
}
