import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 「我的作品」编排（需求 B / F1-3；QA：自动保存、不在换拼法时保存、缺失计数、删除确认、再导出）。
@MainActor
final class WorksControllerTests: XCTestCase {
    private struct Harness {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let existence = FakeExistence()
        let clock = FakeWallClock()
        let store: FileWorksStore
        let controller: WorksController
        let exporter = RecordingWorkExporter()
        let relay = ExportSuccessRelay()
        let result: Locked<ResultBox>

        struct ResultBox: Sendable { var layout: MosaicLayout?; var target: PixelBuffer?; var revision = 0 }

        @MainActor init() {
            store = FileWorksStore(directory: dir, images: images, now: clock.provider)
            controller = WorksController(store: store, existence: existence, images: images)
            result = Locked(ResultBox())
            let r = result
            controller.attach(resultContext: {
                let b = r.get()
                return WorkResultContext(layout: b.layout, target: b.target, overlayAlpha: b.layout?.params.overlayAlpha ?? 0,
                                         tier: "uhd", resultRevision: b.revision)
            }, relay: relay)
            controller.exportHandler = exporter
        }

        /// 出一个新结果（首次生成或「换一种拼法」）。
        @MainActor func newResult(_ ids: [String]) throws {
            let target = try smallTarget()
            result.update { $0.layout = sampleLayout(ids); $0.target = target; $0.revision += 1 }
            controller.resultDidChange(revision: result.get().revision)
        }
    }

    func testManualSaveIsIdempotentAndResetsOnNewResult() async throws {
        let h = Harness()
        await h.controller.start()
        XCTAssertTrue(h.controller.state.isEmpty)
        try h.newResult(["a", "b", "c"])
        XCTAssertEqual(h.controller.state.saveStatus, .idle)

        await h.controller.saveCurrentResultTapped()
        guard case .saved(let id) = h.controller.state.saveStatus else { return XCTFail("应已保存") }
        await h.controller.saveCurrentResultTapped()   // 重复点
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [id], "重复点只存一份（B9-2）")
        XCTAssertEqual(h.controller.state.summaries.first?.meta.origin, .savedManually)
        XCTAssertEqual(h.images.state.get().targets, 1, "存了目标图副本")

        // 「换一种拼法」：出新结果，不自动存，按钮回到可点
        try h.newResult(["c", "b", "a"])
        XCTAssertEqual(h.controller.state.saveStatus, .idle)
        let count = await h.store.list().count
        XCTAssertEqual(count, 1, "换一种拼法不自动存")
        h.controller.stop()
    }

    /// B10-1（AndyL 11-16 22:20，推翻 F1-3）：导出成功**不**自动存；只有点「存到我的作品」才进库。
    /// 手动存过再导出同一张也不会多出一份，也不重画预览。
    func testExportSucceededDoesNotSave() async throws {
        let h = Harness()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        let layout = try XCTUnwrap(h.result.get().layout)

        await h.relay.handler(layout, URL(fileURLWithPath: "/tmp/export/x.jpg"))
        await h.controller.exportSucceeded(layout: layout)   // 等中继里的那次也处理完（主线程串行）
        var count = await h.store.list().count
        XCTAssertEqual(count, 0, "导出不自动存")
        XCTAssertEqual(h.controller.state.saveStatus, .idle, "导出过不算存过，按钮仍可点")
        XCTAssertEqual(h.images.state.get().previews, 0)

        await h.controller.saveCurrentResultTapped()
        XCTAssertEqual(h.controller.state.summaries.first?.meta.origin, .savedManually)
        await h.relay.handler(layout, URL(fileURLWithPath: "/tmp/export/y.jpg"))
        await h.controller.exportSucceeded(layout: layout)
        count = await h.store.list().count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(h.images.state.get().previews, 1)
        if case .saved = h.controller.state.saveStatus {} else { XCTFail("存过后导出，按钮仍是已存") }
        h.controller.stop()
    }

    /// 换一种拼法 / 导出都不进库；只有手动保存才新增，新的那张在最前（B10-1/2）。
    func testRegenerateAndExportDoNotSaveOnlyManualSaveAdds() async throws {
        let h = Harness()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        await h.controller.saveCurrentResultTapped()
        try h.newResult(["b", "c", "a"])
        try h.newResult(["c", "a", "b"])
        var count = await h.store.list().count
        XCTAssertEqual(count, 1)
        await h.controller.exportSucceeded(layout: try XCTUnwrap(h.result.get().layout))
        count = await h.store.list().count
        XCTAssertEqual(count, 1, "导出不自动存")
        await h.controller.saveCurrentResultTapped()
        count = await h.store.list().count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(h.controller.state.summaries.first?.meta.fingerprint, WorkFingerprint.of(sampleLayout(["c", "a", "b"])),
                       "新的在最前")
        h.controller.stop()
    }

    func testSaveFailureShowsFailedAndLeavesNothing() async throws {
        let h = Harness()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        h.images.state.update { $0.failAt = .target }
        await h.controller.saveCurrentResultTapped()
        XCTAssertEqual(h.controller.state.saveStatus, .failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.dir.path), [])
        h.images.state.update { $0.failAt = nil }
        await h.controller.saveCurrentResultTapped()
        if case .saved = h.controller.state.saveStatus {} else { XCTFail("重试应成功") }
        h.controller.stop()
    }

    /// B7 / B9-3：打开时批量查一次原照片，只计数提示（不用预览图放大补）；计数写回 meta。
    func testMissingPhotosCountedOnOpenAndBeforeExport() async throws {
        let h = Harness()
        await h.controller.start()
        try h.newResult(["a", "b", "c", "a", "b", "d"])
        await h.controller.saveCurrentResultTapped()
        let id = try XCTUnwrap(h.controller.state.summaries.first?.id)

        h.existence.deleted.set(["a", "d", "zzz"])
        await h.controller.open(id)
        XCTAssertEqual(h.controller.state.opened?.missingCount, 2, "去重后按张数算：a、d")
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["2"]))
        XCTAssertEqual(h.controller.state.summaries.first?.meta.missingCount, 2)
        let persisted = await FileWorksStore(directory: h.dir, images: h.images).list().first?.meta.missingCount
        XCTAssertEqual(persisted, 2)

        // 导出前再查一次（期间又删了一张）；按保存的布局导出，带目标图副本
        h.existence.deleted.set(["a", "b", "d"])
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.controller.state.opened?.missingCount, 3)
        XCTAssertEqual(h.exporter.calls.count, 1)
        XCTAssertEqual(h.exporter.calls.first?.0, sampleLayout(["a", "b", "c", "a", "b", "d"]), "导出用保存的显式布局")
        XCTAssertEqual(h.exporter.calls.first?.1, true, "目标图副本读回来做叠加")
        XCTAssertEqual(h.exporter.calls.first?.2, .save)

        // 原照片都在：不提示
        h.existence.deleted.set([])
        await h.controller.open(id)
        XCTAssertEqual(h.controller.state.opened?.missingCount, 0)
        XCTAssertNil(h.controller.state.missingLine)
        h.controller.stop()
    }

    /// 从作品再导出成功 → 不存（导出不自动存），不会多出一份，也不改结果页按钮。
    func testExportFromWorkDoesNotDuplicate() async throws {
        let h = Harness()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        await h.controller.saveCurrentResultTapped()
        let id = try XCTUnwrap(h.controller.state.summaries.first?.id)
        try h.newResult(["x", "y", "z"])   // 结果页已经是别的图
        await h.controller.open(id)
        await h.controller.exportOpenedTapped(purpose: .share)
        let layout = try XCTUnwrap(h.exporter.calls.first?.0)
        await h.controller.exportSucceeded(layout: layout)
        let count = await h.store.list().count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(h.controller.state.saveStatus, .idle, "作品页导出不改结果页按钮")
        h.controller.stop()
    }

    /// B5：删除要二次确认；取消不删；确认后列表和磁盘都清掉、查看页关闭。
    func testDeleteRequiresConfirmation() async throws {
        let h = Harness()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        await h.controller.saveCurrentResultTapped()
        let id = try XCTUnwrap(h.controller.state.summaries.first?.id)
        await h.controller.open(id)

        h.controller.deleteTapped(id)
        XCTAssertEqual(h.controller.state.pendingDelete, id)
        h.controller.deleteCancelled()
        XCTAssertNil(h.controller.state.pendingDelete)
        XCTAssertEqual(h.controller.state.count, 1)

        await h.controller.deleteConfirmed()   // 没有待确认的：什么都不做
        XCTAssertEqual(h.controller.state.count, 1)

        h.controller.deleteTapped(id)
        await h.controller.deleteConfirmed()
        XCTAssertEqual(h.controller.state.count, 0)
        XCTAssertNil(h.controller.state.opened)
        XCTAssertNil(h.controller.openedWork)
        XCTAssertEqual(h.controller.state.saveStatus, .idle, "删掉后结果页可再存")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.dir.appendingPathComponent(id.directoryName).path))
        h.controller.stop()
    }

    /// 存 → 「杀进程」→ 重开：作品在、能打开（B9-1）；上次残留的临时目录被清掉。
    func testReopenAfterRelaunch() async throws {
        let h = Harness()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        await h.controller.saveCurrentResultTapped()
        let id = try XCTUnwrap(h.controller.state.summaries.first?.id)
        let tmp = h.dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        h.controller.stop()

        let store2 = FileWorksStore(directory: h.dir, images: h.images)
        let c2 = WorksController(store: store2, existence: h.existence, images: h.images)
        await c2.start()
        XCTAssertEqual(c2.state.summaries.map(\.id), [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        await c2.open(id)
        XCTAssertEqual(c2.openedWork?.layout, sampleLayout(["a", "b", "c"]))
        XCTAssertEqual(c2.state.opened?.missingCount, 0)
    }

    func testOpenMissingWorkShowsNotice() async throws {
        let h = Harness()
        await h.controller.start()
        await h.controller.open(WorkID())
        XCTAssertEqual(h.controller.state.notice, .worksOpenFailed)
        XCTAssertNil(h.controller.state.opened)
        h.controller.dismissNotice()
        XCTAssertNil(h.controller.state.notice)
        h.controller.stop()
    }
}
