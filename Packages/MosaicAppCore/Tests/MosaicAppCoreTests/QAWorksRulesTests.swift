import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

// AndyL 11-16 晚定的「我的作品」规则（product/hd-export-req-v0.2.md B5 / B7 / B9 / B10 第 1–13 条；产品答复 22:40、22:45）
// —— 只用 #16（a9c17b9）已有接口能写的部分。
// 命名：testRuleN_* = 规则要求的行为（实现前可能红）；testGuardN_* = 规则要求保留的现有行为（现在应绿）。
// 依赖 MosaicAppCoreTests 现有 WorksFakes / Fakes / CoordinatorFakes。
// 用法：拷进 Packages/MosaicAppCore/Tests/MosaicAppCoreTests/ 后 `swift test --filter QAWorksRules`。
// 全栈接入（fix/works-delete）时的改动都标了「全栈改 / 全栈加」：setAlpha 通知 controller、旧无参删除入口改调实现、
// 旧数据重复改用 makeLegacyDuplicate 构造。seed 用例（testGuard4_SeedStillDistinguishes）已按 QA 原意恢复：
// 指纹含 seed（AndyL 规则「换拼法后再存就新存一份」，开发协调人按 QA PR #17 复核定口径）。

@MainActor
final class QAWorksRulesTests: XCTestCase {
    // MARK: 工具

    private struct H {
        let dir: URL
        let images = FakeWorkImages()
        let store: FileWorksStore
        let controller: WorksController
        let relay = ExportSuccessRelay()
        let result = Locked(Box())
        struct Box: Sendable { var layout: MosaicLayout?; var target: PixelBuffer?; var alpha = 0.15; var revision = 0 }

        @MainActor init(dir: URL = makeTempDir().appendingPathComponent("Works")) {
            self.dir = dir
            store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
            controller = WorksController(store: store, existence: FakeExistence(), images: images)
            let r = result
            controller.attach(resultContext: {
                let b = r.get()
                var l = b.layout
                l?.params.overlayAlpha = b.alpha
                return WorkResultContext(layout: l, target: b.target, overlayAlpha: b.alpha, tier: "uhd", resultRevision: b.revision)
            }, relay: relay)
        }
        @MainActor func newResult(_ ids: [String], seed: UInt64 = 7) throws {
            let t = try smallTarget()
            result.update { $0.layout = sampleLayout(ids, seed: seed); $0.target = t; $0.revision += 1 }
            controller.resultDidChange(revision: result.get().revision)
        }
        /// 只改叠加强度（不出新结果、revision 不变；与「调整」页拖滑杆一致）。
        /// 全栈改：拖滑杆后由平台层通知 controller（App 里是 AppModel → `resultContextDidChange()`；这里用 QA 假设的 A6 接口名
        /// `overlayAlphaDidChange(_:)`），按钮状态才会重算。原来只改 box、不通知。
        @MainActor func setAlpha(_ a: Double) {
            result.update { $0.alpha = a }
            controller.overlayAlphaDidChange(a)
        }
        @MainActor func saveNow() async -> WorkID? {
            await controller.saveCurrentResultTapped()
            if case .saved(let id) = controller.state.saveStatus { return id }
            return nil
        }
        @MainActor func mustSave() async throws -> WorkID {
            let id = await saveNow()
            return try XCTUnwrap(id, "保存失败")
        }
        func exists(_ id: WorkID) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(id.directoryName).path) }
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func stringsValue(_ key: String) throws -> String? {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("App/Resources/zh-Hans.lproj/Localizable.strings"), encoding: .utf8)
        for line in text.split(separator: "\n") where line.hasPrefix("\"\(key)\"") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            if parts.count >= 4 { return String(parts[3]) }
        }
        return nil
    }

    // MARK: 规则 1 列表页长按删除

    /// 列表上长按→「删除」→同一确认弹窗→确认。作品没打开过（不经过 open）。弹窗收起先 set(false)→deleteCancelled。
    func testRule1_ListLongPressDeleteWithDismissOrder() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"]); let a = try await h.mustSave()
        try h.newResult(["d", "e", "f"]); let b = try await h.mustSave()
        XCTAssertNil(h.controller.state.opened)
        h.controller.deleteTapped(a)                                             // contextMenu「删除」
        XCTAssertEqual(h.controller.state.pendingDelete, a, "列表页也走 pendingDelete 弹出同一确认弹窗")
        let action = Task { @MainActor in await h.controller.deleteConfirmed(a) }   // 弹窗按钮带 id
        h.controller.deleteCancelled()                                           // 弹窗收起 set(false)
        await action.value
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [b], "立即从列表消失")
        XCTAssertFalse(h.exists(a), "目录删净")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).filter { $0.hasPrefix(".") }, [])
        h.controller.stop()
        let relaunched = H(dir: h.dir)
        await relaunched.controller.start()
        XCTAssertEqual(relaunched.controller.state.summaries.map(\.id), [b], "重启不回来")
        relaunched.controller.stop()
    }

    func testRule1_ListLongPressCancelDoesNotDelete() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"]); let a = try await h.mustSave()
        h.controller.deleteTapped(a)
        h.controller.deleteCancelled()
        await h.controller.confirmPendingDelete()   // 全栈改：旧无参入口已 deprecated（-warnings-as-errors），改调其实现；无待确认 → 不删
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [a])
        XCTAssertTrue(h.exists(a))
        h.controller.stop()
    }

    /// 列表删的恰好是查看页打开着的那张（例如 iPad 分栏 / 返回手势途中）：查看页关闭。
    func testRule1_ListDeleteOfOpenedWorkClosesDetail() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"]); let a = try await h.mustSave()
        await h.controller.open(a)
        h.controller.deleteTapped(a)
        await h.controller.deleteConfirmed(a)
        XCTAssertNil(h.controller.state.opened)
        XCTAssertEqual(h.controller.state.count, 0)
        h.controller.stop()
    }

    /// B5：长按菜单复用 works.delete（="删除"），确认框沿用 works.delete.confirm / .ok，不新增 key。
    func testRule1_LongPressReusesWorksDeleteKey() throws {
        XCTAssertEqual(L10nKey.worksDelete.rawValue, "works.delete")
        XCTAssertEqual(try Self.stringsValue("works.delete"), "删除")
        XCTAssertEqual(try Self.stringsValue("works.delete.confirm.ok"), "删除")
        XCTAssertEqual(try Self.stringsValue("works.delete.confirm"), "删除这张作品？相册里的照片不会受影响。")
        for k in ["works.delete", "works.delete.confirm", "works.delete.confirm.ok"] {
            let v = try Self.stringsValue(k) ?? ""
            XCTAssertFalse(v.contains("删掉") || v.contains("隐藏"), k)
        }
    }

    /// B7（22:45 已改）+ copy v1.3：works.missing 精确等于「有 {count} 格原来的照片现在用不了，这几格会稍模糊」（strings 里 {count} 为 %1$@）。
    /// 全栈同步前保持红。
    func testCopy_WorksMissingMatchesCopyV13() throws {
        let v = try XCTUnwrap(try Self.stringsValue("works.missing"))
        XCTAssertEqual(v, "有 %1$@ 格原来的照片现在用不了，这几格会稍模糊")
        XCTAssertFalse(v.contains("删掉") || v.contains("隐藏"))
    }

    /// 源码守卫：WorksListView 有长按 contextMenu，按钮用 L10nKey.worksDelete、调 deleteTapped，且列表页挂了确认弹窗、确认按钮带 id。
    func testRule1_ListViewSourceHasLongPressWiredToSamePath() throws {
        let src = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Works/WorksViews.swift"), encoding: .utf8)
        guard let start = src.range(of: "struct WorksListView"), let end = src.range(of: "struct WorkCell") else {
            return XCTFail("找不到 WorksListView")
        }
        let list = String(src[start.upperBound..<end.lowerBound])
        XCTAssertTrue(list.contains(".contextMenu"), "列表格子要有长按 contextMenu")
        XCTAssertTrue(list.contains("L10nKey.worksDelete"), "长按菜单文案复用 works.delete")
        XCTAssertTrue(list.contains("deleteTapped("), "长按走 controller.deleteTapped（与详情页同一路径）")
        XCTAssertTrue(list.contains(".confirmationDialog"), "列表页要挂同一确认弹窗")
        XCTAssertTrue(list.range(of: #"deleteConfirmed\(\s*[A-Za-z_][A-Za-z0-9_.]*\s*\)"#, options: .regularExpression) != nil,
                      "确认按钮直接带 id（避免 set(false) 吞删除）")
        XCTAssertFalse(list.contains("删掉"))
        if let r = list.range(of: ".contextMenu") {
            let menu = String(list[r.upperBound...].prefix(400))
            XCTAssertFalse(menu.contains("worksExport") || menu.contains("ShareLink"), "B5：菜单只有「删除」一项")
        }
    }

    // MARK: 规则 2 「换一种拼法」后再存 = 新增一份

    func testGuard2_ReshuffleThenSaveAddsNewAndKeepsOriginal() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"]); let a = try await h.mustSave()
        let before = try await h.store.load(a)
        try h.newResult(["c", "a", "b"], seed: 8)                     // 换一种拼法
        XCTAssertEqual(h.controller.state.saveStatus, .idle, "按钮回到可存")
        let b = try await h.mustSave()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [b, a], "新的在前")
        let after = try await h.store.load(a)
        XCTAssertEqual(after.layout, before.layout, "原作品不变")
        XCTAssertEqual(after.meta, before.meta)
        h.controller.stop()
    }

    func testGuard2_ReshuffleNTimesSaveEachGivesN() async throws {
        let h = H()
        await h.controller.start()
        let n = 5
        var ids: [WorkID] = []
        for i in 0..<n {
            try h.newResult(["p\(i)", "q", "r"], seed: UInt64(10 + i))
            ids.append(try await h.mustSave())
            await h.controller.saveCurrentResultTapped()                 // 同一次结果再点：不加
        }
        XCTAssertEqual(Set(ids).count, n)
        XCTAssertEqual(h.controller.state.count, n)
        h.controller.stop()
    }

    func testGuard2_SameResultDoubleTapStillOne() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        async let x: Void = h.controller.saveCurrentResultTapped()
        async let y: Void = h.controller.saveCurrentResultTapped()
        _ = await (x, y)
        XCTAssertEqual(h.controller.state.count, 1)
        h.controller.stop()
    }

    /// 端到端：真协调器生成 → 存 → 换一种拼法 → 存 = 2 份，第一份布局不变。
    func testGuard2_CoordinatorReshuffleThenSave() async throws {
        let ch = CoordinatorHarness(assets: 300)
        let c = ch.coordinator
        c.setTarget(try CoordinatorHarness.target()); c.start(); await c.settle()
        await c.generateTapped(); await c.settle()
        let images = FakeWorkImages()
        let works = WorksController(store: FileWorksStore(directory: makeTempDir(), images: images), existence: FakeExistence(), images: images)
        works.attach(resultContext: { [weak c] in c!.workResultContext }, relay: ExportSuccessRelay())
        await works.start()
        works.resultDidChange(revision: c.state.resultRevision)
        await works.saveCurrentResultTapped()
        let first = try XCTUnwrap(works.state.summaries.first?.id)
        let firstLayout = try await works.store.load(first).layout
        let rev = c.state.resultRevision
        c.send(.reshuffleTapped); await c.settle()
        await waitFor(c, "换拼法") { $0.resultRevision > rev }
        works.resultDidChange(revision: c.state.resultRevision)
        await works.saveCurrentResultTapped()
        XCTAssertEqual(works.state.count, 2)
        let again = try await works.store.load(first).layout
        XCTAssertEqual(again, firstLayout)
        works.stop(); c.stop()
    }

    // MARK: 规则 3 导出到相册不再自动存

    @MainActor private final class Wired {
        let ch: CoordinatorHarness
        let works: WorksController
        let relay: ExportSuccessRelay
        init() throws {
            let relay = ExportSuccessRelay()
            self.relay = relay
            ch = CoordinatorHarness(assets: 300, onExportSucceeded: relay.handler)   // 与 AppModel.swift:50 同样接线
            let images = FakeWorkImages()
            works = WorksController(store: FileWorksStore(directory: makeTempDir(), images: images), existence: FakeExistence(), images: images)
            let c = ch.coordinator
            works.attach(resultContext: { [weak c] in c!.workResultContext }, relay: relay)
        }
        func generate() async throws {
            let c = ch.coordinator
            c.setTarget(try CoordinatorHarness.target()); c.start(); await c.settle()
            await c.generateTapped(); await c.settle()
            await works.start()
            works.resultDidChange(revision: c.state.resultRevision)
        }
        func exportToAlbum() async {
            let c = ch.coordinator
            await c.saveTapped()
            await waitFor(c, "导出结束") {
                switch $0.export { case .saved, .failed, .idle, .interrupted: return true; default: return false }
            }
            // 中继是异步消费：给 WorksController 足够时间处理（这里是在证明“没发生”，只能留时间窗）
            for _ in 0..<50 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 300_000_000)
            for _ in 0..<50 { await Task.yield() }
        }
        func diskCount() async -> Int { await works.store.list().count }
        func stop() { works.stop(); ch.coordinator.stop() }
    }

    func testRule3_ExportSuccessDoesNotAutoSave() async throws {
        let w = try Wired()
        try await w.generate()
        await w.exportToAlbum()
        guard case .saved = w.ch.coordinator.state.export else { return XCTFail("导出应成功") }
        XCTAssertEqual(w.works.state.count, 0, "导出成功后作品数不变")
        let n = await w.diskCount()
        XCTAssertEqual(n, 0)
        XCTAssertEqual(w.works.state.saveStatus, .idle, "结果页「存到我的作品」仍可点")
        w.stop()
    }

    func testGuard3_ManualSaveThenExportStillOne() async throws {
        let w = try Wired()
        try await w.generate()
        await w.works.saveCurrentResultTapped()
        await w.exportToAlbum()
        XCTAssertEqual(w.works.state.count, 1)
        let n = await w.diskCount()
        XCTAssertEqual(n, 1)
        w.stop()
    }

    func testGuard3_ExportEncodingFailureAddsNothing() async throws {
        let w = try Wired()
        try await w.generate()
        w.ch.exporter.state.update { $0.error = .encodingFailed }
        await w.exportToAlbum()
        let n = await w.diskCount()
        XCTAssertEqual(n, 0)
        w.stop()
    }

    /// 编码成功、写相册失败（AppCoordinator.swift:584 在写相册之前就调 onExportSucceeded）：也不应新增。
    func testRule3_AlbumWriteFailureAddsNothing() async throws {
        let w = try Wired()
        try await w.generate()
        w.ch.library.state.update { $0.saveError = .generic }
        await w.exportToAlbum()
        guard case .failed = w.ch.coordinator.state.export else { return XCTFail("写相册应失败") }
        let n = await w.diskCount()
        XCTAssertEqual(n, 0, "导出失败不新增作品")
        w.stop()
    }

    // MARK: 规则 4 只改叠加强度 = 同一张（B10 第 3、5–10 条）

    /// 预览内容随叠加强度变化的假编码器（用来证明“覆盖”：预览文件被替换成新强度的内容）。
    final class AlphaImages: WorkImageEncoding, Sendable {
        let previews = Locked(0)
        func writePreview(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, maxLongEdge: Int,
                          into directory: URL) async throws -> WorkImageFile {
            previews.update { $0 += 1 }
            try Data("PREVIEW:alpha=\(overlayAlpha):\(layout.cellAssignments.map(\.localIdentifier).joined(separator: ","))".utf8)
                .write(to: directory.appendingPathComponent("preview.jpg"))
            return WorkImageFile(fileName: "preview.jpg", pixelWidth: 2732, pixelHeight: 2732)
        }
        func writeTarget(_ target: PixelBuffer, maxLongEdge: Int, into directory: URL) async throws -> WorkImageFile {
            try Data("TARGET".utf8).write(to: directory.appendingPathComponent("target.jpg"))
            return WorkImageFile(fileName: "target.jpg", pixelWidth: target.width, pixelHeight: target.height)
        }
        func readTarget(at url: URL) async throws -> PixelBuffer {
            try PixelBuffer(width: 2, height: 2, bytes: [UInt8](repeating: 128, count: 16))
        }
    }

    private func draft(_ alpha: Double, ids: [String] = ["a", "b", "c"], seed: UInt64 = 7, tier: String? = "uhd",
                       target: PixelBuffer? = nil) -> WorkDraft {
        var l = sampleLayout(ids, seed: seed); l.params.overlayAlpha = alpha
        return WorkDraft(layout: l, target: target, overlayAlpha: alpha, tier: tier, seed: seed, origin: .savedManually)
    }
    private func alphaStore(_ dir: URL) -> (FileWorksStore, AlphaImages) {
        let img = AlphaImages()
        return (FileWorksStore(directory: dir, images: img, now: FakeWallClock().provider), img)
    }

    /// B10.3 / B9-8：controller 层，只拖强度再存 → 同一个 id、数量不变、存的是新强度、预览重画。
    func testRule4_AlphaOnlyChangeUpdatesSameWork() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"]); let a = try await h.mustSave()
        let previewsBefore = h.images.state.get().previews
        h.setAlpha(0.25)
        XCTAssertNotEqual(h.controller.state.saveStatus, .saved(a), "B10.5：改了强度后按钮恢复可点（显示「更新这张作品」）")
        await h.controller.saveCurrentResultTapped()
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [a], "id 不变、不新增")
        XCTAssertEqual(h.controller.state.saveStatus, .saved(a), "B10.6：更新后回到「已存」且不可点")
        let m = try await h.store.load(a).meta
        XCTAssertEqual(m.overlayAlpha, 0.25, accuracy: 1e-9, "存的是新强度")
        XCTAssertGreaterThan(h.images.state.get().previews, previewsBefore, "预览重画")
        h.controller.stop()
    }

    /// B10.3 / B10.8：存储层，只改强度 → inserted == false、同 id、meta / layout 更新为新强度。
    func testRule4_StoreSaveAlphaOnlyIsNotInserted() async throws {
        let (store, _) = alphaStore(makeTempDir().appendingPathComponent("Works"))
        let first = try await store.save(draft(0.15))
        let second = try await store.save(draft(0.25))
        XCTAssertFalse(second.inserted, "只改强度不算新作品")
        XCTAssertEqual(second.summary.id, first.summary.id)
        XCTAssertEqual(second.summary.meta.overlayAlpha, 0.25, accuracy: 1e-9, "返回更新后的 meta")
        let n = await store.list().count
        XCTAssertEqual(n, 1)
        let loaded = try await store.load(first.summary.id)
        XCTAssertEqual(loaded.layout.params.overlayAlpha, 0.25, accuracy: 1e-9, "layout.json 也更新")
        XCTAssertEqual(loaded.layout.cellAssignments, draft(0.15).layout.cellAssignments, "布局不变")
    }

    /// B10.3 / B10.7：保留原日期和列表位置（createdAt 倒序，更新不顶到最前）。
    func testRule4_UpdateKeepsCreatedAtAndListPosition() async throws {
        let (store, _) = alphaStore(makeTempDir().appendingPathComponent("Works"))
        let older = try await store.save(draft(0.15, ids: ["a", "b", "c"]))
        let newer = try await store.save(draft(0.15, ids: ["x", "y", "z"]))
        let upd = try await store.save(draft(0.25, ids: ["a", "b", "c"]))
        XCTAssertEqual(upd.summary.id, older.summary.id)
        XCTAssertEqual(upd.summary.meta.createdAt, older.summary.meta.createdAt, "日期不变")
        let order = await store.list().map(\.id)
        XCTAssertEqual(order, [newer.summary.id, older.summary.id], "位置不变，不顶到最前")
    }

    /// B10.8 覆盖不留历史：预览换成新强度的内容；目录里只有 meta/layout/preview/target，没有旧预览、.tmp/.trash 残留。
    func testRule4_OverwriteLeavesNoHistory() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let (store, _) = alphaStore(dir)
        let a = try await store.save(draft(0.15, target: try smallTarget()))
        let workDir = dir.appendingPathComponent(a.summary.id.directoryName)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: workDir.path))
        _ = try await store.save(draft(0.25, target: try smallTarget()))
        let top = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(top, [a.summary.id.directoryName], "Works/ 下只有这一个作品目录，没有 .tmp-/.trash-/新目录")
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: workDir.path))
        XCTAssertEqual(after, before, "文件集合不变（没有 preview-old.jpg 之类历史文件）")
        let preview = try String(contentsOf: workDir.appendingPathComponent("preview.jpg"), encoding: .utf8)
        XCTAssertTrue(preview.hasPrefix("PREVIEW:alpha=0.25"), "预览被替换为新强度：\(preview)")
    }

    /// 格子变了（同时改了强度）→ 新的一张（B10.3 末句 / B10.2）。
    func testGuard4_CellsChangedWithAlphaIsNew() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"]); let a = try await h.mustSave()
        h.setAlpha(0.25)
        try h.newResult(["a", "c", "b"])
        let b = try await h.mustSave()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(h.controller.state.count, 2)
        h.controller.stop()
    }

    func testGuard4_SeedStillDistinguishes() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"], seed: 7); _ = await h.saveNow()
        try h.newResult(["a", "b", "c"], seed: 8); _ = await h.saveNow()
        XCTAssertEqual(h.controller.state.count, 2)
        h.controller.stop()
    }

    /// B10.10：导出档位不进指纹 —— 换档位再存（controller，resultContext.tier 变化）仍是同一张。
    func testGuard4_TierNotInFingerprintController() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"]); let a = try await h.mustSave()
        // 换档位：直接走存储层带不同 tier 的草稿（结果页按钮此时为已存不可点）
        let r = try await h.store.save(WorkDraft(layout: { var l = sampleLayout(["a", "b", "c"]); l.params.overlayAlpha = 0.15; return l }(),
                                                 target: nil, overlayAlpha: 0.15, tier: "hd", seed: 7, origin: .savedManually))
        XCTAssertFalse(r.inserted)
        XCTAssertEqual(r.summary.id, a)
        XCTAssertEqual(h.controller.state.count, 1)
        h.controller.stop()
    }

    /// B10.10 + B10.3：只改强度 + 换档位 → 仍更新同一张。
    func testRule4_AlphaAndTierChangeStillSameWork() async throws {
        let (store, _) = alphaStore(makeTempDir().appendingPathComponent("Works"))
        let a = try await store.save(draft(0.15, tier: "uhd"))
        let b = try await store.save(draft(0.25, tier: "hd"))
        XCTAssertEqual(b.summary.id, a.summary.id)
        let n = await store.list().count
        XCTAssertEqual(n, 1)
    }

    /// 强度来回改：0.15 → 0.25 → 0.15，每次都存 → 一份，最终强度 0.15。
    func testRule4_AlphaBackToOriginalStillOneWork() async throws {
        let (store, _) = alphaStore(makeTempDir().appendingPathComponent("Works"))
        var ids = Set<WorkID>()
        for a in [0.15, 0.25, 0.15] { ids.insert(try await store.save(draft(a)).summary.id) }
        XCTAssertEqual(ids.count, 1)
        let list = await store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.meta.overlayAlpha ?? -1, 0.15, accuracy: 1e-9)
    }

    /// B10.5：没存就把强度改回原值 → 视为没有改动，按钮保持「已存」不可点，不发生写入。
    func testGuard4_AlphaChangedThenRestoredWithoutSavingIsNoChange() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"]); let a = try await h.mustSave()
        let writes = h.images.state.get().previews
        h.setAlpha(0.25); h.setAlpha(0.15)
        XCTAssertEqual(h.controller.state.saveStatus, .saved(a))
        await h.controller.saveCurrentResultTapped()       // 即使被点到（按钮应不可点）也不写
        XCTAssertEqual(h.images.state.get().previews, writes, "没有改动不重画预览")
        XCTAssertEqual(h.controller.state.count, 1)
        h.controller.stop()
    }

    func testRule4_ConcurrentAlphaVariantsOneWork() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let (store, _) = alphaStore(dir)
        let d1 = draft(0.10), d2 = draft(0.20), d3 = draft(0.30)
        async let r1 = store.save(d1)
        async let r2 = store.save(d2)
        async let r3 = store.save(d3)
        let rs = try await [r1, r2, r3]
        XCTAssertEqual(Set(rs.map(\.summary.id)).count, 1, "并发保存同一张不同强度 → 同一个 id")
        let n = await store.list().count
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }, [], "不留临时目录")
    }

    /// 更新（重画预览）途中删除：更新写完后作品不能复活，也不能以新 id 出现。
    func testRule4_DeleteDuringAlphaUpdateNotResurrected() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"]); let a = try await h.mustSave()
        let gate = GatePoint()
        h.images.gate.set(gate)
        let updating = Task { @MainActor in
            _ = try? await h.store.save(WorkDraft(layout: { var l = sampleLayout(["a", "b", "c"]); l.params.overlayAlpha = 0.25; return l }(),
                                                  target: nil, overlayAlpha: 0.25, tier: nil, seed: 7, origin: .savedManually))
        }
        await gate.reached.wait()
        h.images.gate.set(nil)
        h.controller.deleteTapped(a)
        await h.controller.deleteConfirmed(a)
        await gate.release.open()
        _ = await updating.result
        await h.controller.reload()
        XCTAssertEqual(h.controller.state.count, 0, "更新途中被删的作品不能被写回")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.dir.path), [])
        h.controller.stop()
    }

    /// 把一个作品的 meta.json 改写成 v1 旧版（指纹 = 含强度的整份 layout JSON）。
    private func makeLegacy(_ dir: URL, _ id: WorkID, layout: MosaicLayout) throws {
        let url = dir.appendingPathComponent(id.directoryName).appendingPathComponent(FileWorksStore.metaFileName)
        var meta = try FileWorksStore.decoder().decode(WorkMeta.self, from: Data(contentsOf: url))
        meta.fingerprint = FileWorksStore.fingerprint(try FileWorksStore.encoder().encode(layout))
        meta.formatVersion = 1
        try FileWorksStore.encoder().encode(meta).write(to: url, options: .atomic)
    }

    /// 全栈加：新版存储层按内容指纹查重，已经造不出「同格子不同强度」的两份；这里先存一份别的格子，
    /// 再把它的 layout.json 换成同格子布局、meta 改写成 v1，模拟旧版本留下的重复。
    private func makeLegacyDuplicate(_ dir: URL, _ id: WorkID, layout: MosaicLayout) throws {
        let url = dir.appendingPathComponent(id.directoryName).appendingPathComponent(FileWorksStore.layoutFileName)
        try FileWorksStore.encoder().encode(layout).write(to: url, options: .atomic)
        try makeLegacy(dir, id, layout: layout)
    }

    /// B10.9 旧数据不合并：升级前已有「同格子、不同强度」两份 → 升级后两份都在、内容不变。（现在绿；实现迁移后必须保持绿）
    func testGuard4_LegacyDuplicatesNotMergedAfterUpgrade() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let (old, _) = alphaStore(dir)
        let x = try await old.save(draft(0.15)); try makeLegacy(dir, x.summary.id, layout: draft(0.15).layout)
        let y = try await old.save(draft(0.25, ids: ["q", "r", "s"])); try makeLegacyDuplicate(dir, y.summary.id, layout: draft(0.25).layout)
        let (upgraded, _) = alphaStore(dir)
        await upgraded.removeIncomplete()
        let list = await upgraded.list()
        XCTAssertEqual(list.map(\.id), [y.summary.id, x.summary.id], "两份都在，createdAt 倒序")
        XCTAssertEqual(list.map(\.meta.overlayAlpha), [0.25, 0.15])
    }

    /// B10.9 + B10.12：升级后再存同格子 → 命中 max(updatedAt ?? createdAt) 的那份并更新它；旧数据 updatedAt 都为空 = createdAt 最新。
    /// 另一份不动、数量仍是 2。（有 updatedAt 的情况见 pending）
    func testRule4_LegacyDuplicatesSaveHitsNewest() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let (old, _) = alphaStore(dir)
        let x = try await old.save(draft(0.15)); try makeLegacy(dir, x.summary.id, layout: draft(0.15).layout)
        let y = try await old.save(draft(0.25, ids: ["q", "r", "s"])); try makeLegacyDuplicate(dir, y.summary.id, layout: draft(0.25).layout)
        let (upgraded, _) = alphaStore(dir)
        await upgraded.removeIncomplete()
        let r = try await upgraded.save(draft(0.35))
        XCTAssertFalse(r.inserted, "不新增")
        XCTAssertEqual(r.summary.id, y.summary.id, "命中 createdAt 最新的一份")
        let list = await upgraded.list()
        XCTAssertEqual(list.count, 2, "不合并")
        let xm = try XCTUnwrap(list.first { $0.id == x.summary.id }).meta
        XCTAssertEqual(xm.overlayAlpha, 0.15, accuracy: 1e-9, "另一份不动")
    }

    /// 单份旧数据：升级后只改强度再存 → 更新它（旧指纹也能按新口径命中）。
    func testRule4_LegacySingleWorkMatchedAfterUpgrade() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let (old, _) = alphaStore(dir)
        let x = try await old.save(draft(0.15)); try makeLegacy(dir, x.summary.id, layout: draft(0.15).layout)
        let (upgraded, _) = alphaStore(dir)
        await upgraded.removeIncomplete()
        let r = try await upgraded.save(draft(0.25))
        XCTAssertFalse(r.inserted)
        XCTAssertEqual(r.summary.id, x.summary.id)
    }

    // MARK: 未保存提示文案（B10 第 4、6、11 条；quick-start 2e）

    /// 新 key 必须在 Localizable.strings 里，值与 B10 原文一致，且不含「删掉」「隐藏」。
    func testRule4_NewCopyKeysPresentAndClean() throws {
        let expected: [String: String] = [
            "works.update": "更新这张作品",
            "works.updated": "已更新这张作品",
            "quick.unsaved.update_title": "叠加强度改了还没保存，要更新这张作品吗？",
        ]
        for (k, want) in expected.sorted(by: { $0.key < $1.key }) {
            let v = try Self.stringsValue(k)
            XCTAssertEqual(v, want, "缺少或不一致：\(k)")
            XCTAssertFalse((v ?? "").contains("删掉") || (v ?? "").contains("隐藏"), k)
        }
        // 产品答复 2-2：按钮「已存」用 preview.saved_to_works，works.saved 作废。
        XCTAssertEqual(try Self.stringsValue("preview.saved_to_works"), "已存到我的作品")
        XCTAssertNil(try Self.stringsValue("works.saved"), "works.saved 已作废，不应进文案表")
        XCTAssertFalse(L10nKey.allUsed.map(\.rawValue).contains("works.saved"), "works.saved 不应在 allUsed")
    }

    /// quick.unsaved.* 基础 key（quick-start 2e）也应在表里：title / save / discard / cancel。
    func testRule4_UnsavedPromptBaseKeysPresent() throws {
        for k in ["quick.unsaved.title", "quick.unsaved.save", "quick.unsaved.discard", "quick.unsaved.cancel"] {
            let v = try Self.stringsValue(k)
            XCTAssertNotNil(v, "缺少 \(k)")
            XCTAssertFalse((v ?? "").contains("删掉") || (v ?? "").contains("隐藏"), k)
        }
    }

    // MARK: B10.14「再调一调」：只改强度 → 「完成」回原结果；改其他参数 → 「开始拼图」重新生成
    // 行为用例需要新接口（A11），放在 pending/QAWorksRulesPendingInterfaceTests.swift；这里只放现在能编译的守卫。

    /// 两个主按钮 key 都在文案表和 allUsed 里，文案正确、干净。
    func testGuard14_DoneAndGenerateKeysPresent() throws {
        XCTAssertEqual(L10nKey.commonDone.rawValue, "common.done")
        XCTAssertEqual(L10nKey.generateCTA.rawValue, "generate.cta")
        XCTAssertEqual(try Self.stringsValue("common.done"), "完成")
        XCTAssertEqual(try Self.stringsValue("generate.cta"), "开始拼图")
        let used = Set(L10nKey.allUsed.map(\.rawValue))
        XCTAssertTrue(used.contains("common.done"))
        XCTAssertTrue(used.contains("generate.cta"))
    }

    /// 源码守卫：设置页（SettingsStepView）主按钮按条件在 common.done 与 generate.cta 之间切换。
    func testRule14_SettingsViewUsesDoneAndGenerate() throws {
        let src = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainFlowView.swift"), encoding: .utf8)
        guard let start = src.range(of: "struct SettingsStepView") else { return XCTFail("找不到 SettingsStepView") }
        let rest = src[start.upperBound...]
        let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
        let view = String(rest[..<end])
        XCTAssertTrue(view.contains("L10nKey.generateCTA"), "改了其他参数时仍是「开始拼图」")
        XCTAssertTrue(view.contains("L10nKey.commonDone"), "只改强度时主按钮显示「完成」(common.done)")
    }

    /// B10.13：作品查看页这一轮没有强度入口（无 Slider / overlayAlpha / 「再调一调」）。
    func testGuard4_DetailViewHasNoAlphaControl() throws {
        let src = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Works/WorksViews.swift"), encoding: .utf8)
        guard let start = src.range(of: "struct WorkDetailView"), let end = src.range(of: "struct WorkExportPresentation") else {
            return XCTFail("找不到 WorkDetailView")
        }
        let detail = String(src[start.upperBound..<end.lowerBound])
        for bad in ["Slider(", "overlayAlpha", "previewAdjust", "backToSettings"] {
            XCTAssertFalse(detail.contains(bad), "查看页不应有强度入口：\(bad)")
        }
    }
}
