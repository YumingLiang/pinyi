import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

// 全栈接入（fix/works-delete）：A1–A10 按这里的名字实现。按已定规则改了两处断言（标「全栈改」）：
//   A2 的 seed / 密度名：AndyL 22:20 定「去重只看格子分配、cols/rows 和 targetCrop」，seed、密度名不进内容指纹
//   （改密度在真实流程里会改 cols/rows，指纹照样不同）。
// 规则原文：product/hd-export-req-v0.2.md B5、B7、B9-6~9、B10 第 1–13 条（产品答复 22:40、22:45）。
// 接口假设（同 qa/works-rules-test-plan.md「给全栈的接口假设」）：
//   A1  WorkMeta.updatedAt: Date?                    旧数据 nil；更新时写 now()；不参与排序、不显示（B10.7）
//   A2  FileWorksStore.contentFingerprint(_:) -> String  不含 params.overlayAlpha、不含导出档位（B10.10）；
//                                                     含 cols/rows/cellAssignments(含 crop)/targetSize/targetCrop/density/seed
//   A3  WorkMeta.currentFormatVersion == 2           v1 读入时按 layout.json 重算 A2 指纹（只用于命中，不合并，B10.9）
//   A4  store.save 同内容不同强度 → inserted == false，summary 为更新后 meta；同内容同强度 → 不写盘；
//       多份同内容（仅旧数据）→ 命中 max(updatedAt ?? createdAt)（B10.12）
//   A5  WorkSaveStatus 新增 .needsUpdate(WorkID)    已存作品只改了强度时；UI 显示 works.update「更新这张作品」
//   A6  WorksController.overlayAlphaDidChange(_:)    平台层滑杆变化时调（或 controller 自己比较 resultContext 与已存 meta）
//   A7  WorksState.toast: L10nKey?                    更新成功置 .worksUpdated（约 2 s 由平台层清掉）；新存一张不置
//   A8  WorksController.unsavedPrompt: UnsavedPrompt  .none / .unsaved（quick.unsaved.title）/ .alphaChanged(WorkID)（quick.unsaved.update_title）
//   A9  L10nKey.worksUpdate / .worksUpdated / .quickUnsavedTitle / .quickUnsavedUpdateTitle；「已存」沿用 previewSavedToWorks，works.saved 作废
//   A10 「再调一调」只改强度后回到结果：保留原结果（格子 + seed 不变），resultDidChange 后状态为 .needsUpdate(id)（B10.3）
@MainActor
final class QAWorksRulesPendingInterfaceTests: XCTestCase {
    private func store(_ dir: URL) -> FileWorksStore { FileWorksStore(directory: dir, images: FakeWorkImages(), now: FakeWallClock().provider) }
    private func draft(_ alpha: Double, ids: [String] = ["a", "b", "c"], seed: UInt64 = 7, tier: String? = nil) -> WorkDraft {
        var l = sampleLayout(ids, seed: seed); l.params.overlayAlpha = alpha
        return WorkDraft(layout: l, target: nil, overlayAlpha: alpha, tier: tier, seed: seed, origin: .savedManually)
    }

    /// 结果页现状可变的 controller 夹具。
    private final class Ctx: @unchecked Sendable {
        var alpha = 0.15; var ids = ["a", "b", "c"]; var seed: UInt64 = 7; var revision = 1
    }
    private func controller(_ dir: URL, _ ctx: Ctx) -> WorksController {
        let images = FakeWorkImages()
        let c = WorksController(store: FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider),
                                existence: FakeExistence(), images: images)
        c.attach(resultContext: {
            var l = sampleLayout(ctx.ids, seed: ctx.seed); l.params.overlayAlpha = ctx.alpha
            return WorkResultContext(layout: l, target: nil, overlayAlpha: ctx.alpha, tier: "uhd", resultRevision: ctx.revision)
        }, relay: ExportSuccessRelay())
        c.resultDidChange(revision: ctx.revision)
        return c
    }

    // MARK: A2 指纹

    func testFingerprintIgnoresAlphaTierSeedButNotCells() {
        var l = sampleLayout(["a", "b", "c"]); l.params.overlayAlpha = 0.1
        var m = l; m.params.overlayAlpha = 0.3
        XCTAssertEqual(FileWorksStore.contentFingerprint(l), FileWorksStore.contentFingerprint(m), "不含强度")
        var s = l; s.params.seed = 8
        // 全栈改：seed 不进内容指纹（AndyL 22:20：格子分配相同就是同一张）
        XCTAssertEqual(FileWorksStore.contentFingerprint(l), FileWorksStore.contentFingerprint(s), "不含 seed")
        var c = l; c.cellAssignments.swapAt(0, 1)
        XCTAssertNotEqual(FileWorksStore.contentFingerprint(l), FileWorksStore.contentFingerprint(c), "含格子分配")
        var crop = l; crop.cellAssignments[0].crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        XCTAssertNotEqual(FileWorksStore.contentFingerprint(l), FileWorksStore.contentFingerprint(crop), "含单格裁剪")
        var d = l; d.params.density = "fine"
        // 全栈改：密度名本身不进指纹；真实改密度会改 cols/rows，那时指纹不同
        XCTAssertEqual(FileWorksStore.contentFingerprint(l), FileWorksStore.contentFingerprint(d), "密度名不算")
        let denser = sampleLayout(["a", "b", "c", "d", "e", "f"], cols: 3)
        let coarser = sampleLayout(["a", "b", "c", "d", "e", "f"], cols: 2)
        XCTAssertNotEqual(FileWorksStore.contentFingerprint(denser), FileWorksStore.contentFingerprint(coarser), "cols/rows 不同")
        var t = l; t.targetCrop = CropRect(x: 10, y: 0, width: 280, height: 200)
        XCTAssertNotEqual(FileWorksStore.contentFingerprint(l), FileWorksStore.contentFingerprint(t), "含目标裁剪")
        // 档位不在 MosaicLayout 里：WorkDraft.tier 不同的两次保存在 store 层同一张（runnable 文件已测）
    }

    // MARK: A1 / A4 更新元数据

    func testAlphaUpdateKeepsIdCreatedAtBumpsUpdatedAt() async throws {
        let st = store(makeTempDir().appendingPathComponent("Works"))
        let a = try await st.save(draft(0.15))
        XCTAssertNil(a.summary.meta.updatedAt)
        let b = try await st.save(draft(0.25))
        XCTAssertEqual(b.summary.id, a.summary.id)
        XCTAssertEqual(b.summary.meta.createdAt, a.summary.meta.createdAt, "日期不变（B10.3）")
        let u = try XCTUnwrap(b.summary.meta.updatedAt)
        XCTAssertGreaterThan(u, a.summary.meta.createdAt)
        XCTAssertEqual(b.summary.meta.fingerprint, FileWorksStore.contentFingerprint(draft(0.25).layout))
    }

    func testSameContentSameAlphaDoesNotTouchUpdatedAt() async throws {
        let st = store(makeTempDir().appendingPathComponent("Works"))
        _ = try await st.save(draft(0.15))
        let again = try await st.save(draft(0.15))
        XCTAssertFalse(again.inserted)
        XCTAssertNil(again.summary.meta.updatedAt, "没有改动不算更新")
    }

    /// B10.7：updatedAt 不参与排序。
    func testListOrderIgnoresUpdatedAt() async throws {
        let st = store(makeTempDir().appendingPathComponent("Works"))
        let older = try await st.save(draft(0.15, ids: ["a", "b", "c"]))
        let newer = try await st.save(draft(0.15, ids: ["x", "y", "z"]))
        _ = try await st.save(draft(0.25, ids: ["a", "b", "c"]))
        let list = await st.list()
        XCTAssertEqual(list.map(\.id), [newer.summary.id, older.summary.id])
        XCTAssertNotNil(list.last?.meta.updatedAt)
    }

    // MARK: A3 迁移（不合并）

    func testV1MetaReadableAndMatchedButNotRewrittenOnLaunch() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let st = store(dir)
        let d = draft(0.15)
        let w = try await st.save(d)
        let metaURL = dir.appendingPathComponent(w.summary.id.directoryName).appendingPathComponent(FileWorksStore.metaFileName)
        var meta = try FileWorksStore.decoder().decode(WorkMeta.self, from: Data(contentsOf: metaURL))
        meta.formatVersion = 1
        meta.fingerprint = FileWorksStore.fingerprint(try FileWorksStore.encoder().encode(d.layout))
        try FileWorksStore.encoder().encode(meta).write(to: metaURL, options: .atomic)
        let upgraded = store(dir)
        await upgraded.removeIncomplete()
        let first = await upgraded.list().first
        let listed = try XCTUnwrap(first)
        XCTAssertNil(listed.meta.updatedAt, "旧数据 updatedAt 为 nil")
        let r = try await upgraded.save(draft(0.30))
        XCTAssertFalse(r.inserted, "旧指纹的作品按内容指纹命中")
        XCTAssertEqual(r.summary.meta.fingerprint, FileWorksStore.contentFingerprint(d.layout), "更新后写成新口径指纹")
        XCTAssertEqual(r.summary.meta.formatVersion, WorkMeta.currentFormatVersion)
    }

    /// B10.12：多份同内容旧数据，其中 createdAt 较旧的那份 updatedAt 更新 → 命中它（max(updatedAt ?? createdAt)）。
    func testLegacyDuplicatesHitMaxUpdatedAtOrCreatedAt() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let st = store(dir)
        let dx = draft(0.15), dy = draft(0.25)
        let x = try await st.save(dx)        // 实现后同内容会命中 x，所以先各自写成 v1 旧数据
        func rewrite(_ id: WorkID, layout: MosaicLayout, updatedAt: Date?) throws {
            let url = dir.appendingPathComponent(id.directoryName).appendingPathComponent(FileWorksStore.metaFileName)
            var m = try FileWorksStore.decoder().decode(WorkMeta.self, from: Data(contentsOf: url))
            m.formatVersion = 1
            m.fingerprint = FileWorksStore.fingerprint(try FileWorksStore.encoder().encode(layout))
            m.updatedAt = updatedAt
            try FileWorksStore.encoder().encode(m).write(to: url, options: .atomic)
        }
        // 第二份：复制 x 的目录成新 id（模拟升级前已存在的重复），createdAt 更新、layout 强度 0.25
        let y = WorkID()
        try FileManager.default.copyItem(at: dir.appendingPathComponent(x.summary.id.directoryName),
                                         to: dir.appendingPathComponent(y.directoryName))
        let yURL = dir.appendingPathComponent(y.directoryName)
        var ym = try FileWorksStore.decoder().decode(WorkMeta.self, from: Data(contentsOf: yURL.appendingPathComponent(FileWorksStore.metaFileName)))
        ym.id = y; ym.createdAt = x.summary.meta.createdAt.addingTimeInterval(60); ym.overlayAlpha = 0.25
        try FileWorksStore.encoder().encode(ym).write(to: yURL.appendingPathComponent(FileWorksStore.metaFileName), options: .atomic)
        try FileWorksStore.encoder().encode(dy.layout).write(to: yURL.appendingPathComponent(FileWorksStore.layoutFileName), options: .atomic)
        // x：createdAt 较旧，但 updatedAt 比 y 的 createdAt 还晚
        try rewrite(x.summary.id, layout: dx.layout, updatedAt: x.summary.meta.createdAt.addingTimeInterval(120))
        try rewrite(y, layout: dy.layout, updatedAt: nil)

        let upgraded = store(dir)
        await upgraded.removeIncomplete()
        let order = await upgraded.list().map(\.id)
        XCTAssertEqual(order, [y, x.summary.id], "排序仍按 createdAt（B10.7）")
        let r = try await upgraded.save(draft(0.35))
        XCTAssertFalse(r.inserted)
        XCTAssertEqual(r.summary.id, x.summary.id, "命中 max(updatedAt ?? createdAt) = x")
        let n = await upgraded.list().count
        XCTAssertEqual(n, 2, "不合并")
    }

    // MARK: A5–A7 按钮状态机（B10.5 / B10.6）

    /// 已存 → 改强度 →「更新这张作品」→ 更新 → 已存不可点 + 轻提示「已更新这张作品」。
    func testButtonStateMachineUpdateFlow() async throws {
        let ctx = Ctx()
        let c = controller(makeTempDir().appendingPathComponent("Works"), ctx)
        await c.start()
        XCTAssertEqual(c.state.saveStatus, .idle, "未存：「存到我的作品」可点")
        await c.saveCurrentResultTapped()
        guard case .saved(let id) = c.state.saveStatus else { return XCTFail("应为已存") }
        XCTAssertNil(c.state.toast, "新存一张不加提示（B10.6 末句）")

        ctx.alpha = 0.25; c.overlayAlphaDidChange(0.25)
        XCTAssertEqual(c.state.saveStatus, .needsUpdate(id), "按钮「更新这张作品」(works.update)")

        await c.saveCurrentResultTapped()                    // 不弹确认框，直接覆盖
        XCTAssertEqual(c.state.saveStatus, .saved(id), "回到「已存到我的作品」不可点")
        XCTAssertEqual(c.state.toast, .worksUpdated, "轻提示「已更新这张作品」")
        XCTAssertEqual(c.state.count, 1)
        c.stop()
    }

    /// 改强度后又改回已存的值（没点更新）→ 回到已存不可点，没有提示；改回值以“已存版本”为准（更新后基准随之变化）。
    func testButtonStateWhenAlphaRestored() async throws {
        let ctx = Ctx()
        let c = controller(makeTempDir().appendingPathComponent("Works"), ctx)
        await c.start()
        await c.saveCurrentResultTapped()
        guard case .saved(let id) = c.state.saveStatus else { return XCTFail() }
        ctx.alpha = 0.25; c.overlayAlphaDidChange(0.25)
        ctx.alpha = 0.15; c.overlayAlphaDidChange(0.15)
        XCTAssertEqual(c.state.saveStatus, .saved(id), "改回原值 = 没有改动")
        // 更新到 0.25 后，0.15 反而成了“改动”
        ctx.alpha = 0.25; c.overlayAlphaDidChange(0.25)
        await c.saveCurrentResultTapped()
        ctx.alpha = 0.15; c.overlayAlphaDidChange(0.15)
        XCTAssertEqual(c.state.saveStatus, .needsUpdate(id))
        c.stop()
    }

    /// 改了强度以外的东西（换一种拼法）→ 回到「存到我的作品」(.idle)，再存是新的一张，无提示。
    func testButtonStateAfterReshuffleIsIdleAndSavesNew() async throws {
        let ctx = Ctx()
        let c = controller(makeTempDir().appendingPathComponent("Works"), ctx)
        await c.start()
        await c.saveCurrentResultTapped()
        ctx.alpha = 0.25; c.overlayAlphaDidChange(0.25)
        ctx.ids = ["c", "a", "b"]; ctx.revision += 1; c.resultDidChange(revision: ctx.revision)
        XCTAssertEqual(c.state.saveStatus, .idle)
        await c.saveCurrentResultTapped()
        XCTAssertEqual(c.state.count, 2)
        XCTAssertNil(c.state.toast)
        c.stop()
    }

    /// A10 / B10.3：「再调一调」往返——结果 revision 变了，但格子和 seed 与已存版本相同、只差强度 → .needsUpdate(id)，不是 .idle。
    func testAdjustRoundTripEntersNeedsUpdate() async throws {
        let ctx = Ctx()
        let c = controller(makeTempDir().appendingPathComponent("Works"), ctx)
        await c.start()
        await c.saveCurrentResultTapped()
        guard case .saved(let id) = c.state.saveStatus else { return XCTFail() }
        ctx.alpha = 0.25; ctx.revision += 1                 // 再调一调 → 回到结果：新 revision、同格子同 seed
        c.resultDidChange(revision: ctx.revision)
        XCTAssertEqual(c.state.saveStatus, .needsUpdate(id))
        XCTAssertEqual(c.unsavedPrompt, .alphaChanged(id))
        await c.saveCurrentResultTapped()
        XCTAssertEqual(c.state.saveStatus, .saved(id))
        XCTAssertEqual(c.state.toast, .worksUpdated)
        XCTAssertEqual(c.state.count, 1)
        // 往返但强度没变 → 仍是已存
        ctx.revision += 1; c.resultDidChange(revision: ctx.revision)
        XCTAssertEqual(c.state.saveStatus, .saved(id))
        c.stop()
    }

    // MARK: A8 未保存提示（B10.4 / B10.11）

    func testUnsavedPromptKinds() async throws {
        let ctx = Ctx()
        let c = controller(makeTempDir().appendingPathComponent("Works"), ctx)
        await c.start()
        XCTAssertEqual(c.unsavedPrompt, .unsaved, "没存过 → quick.unsaved.title")
        await c.saveCurrentResultTapped()
        guard case .saved(let id) = c.state.saveStatus else { return XCTFail() }
        XCTAssertEqual(c.unsavedPrompt, UnsavedPrompt.none, "存过且没改 → 不弹")
        ctx.alpha = 0.25; c.overlayAlphaDidChange(0.25)
        XCTAssertEqual(c.unsavedPrompt, .alphaChanged(id), "存过但强度改了 → quick.unsaved.update_title")
        XCTAssertEqual(c.unsavedPrompt.titleKey, .quickUnsavedUpdateTitle)
        await c.saveCurrentResultTapped()                    // 提示里点「保存」= 更新
        XCTAssertEqual(c.unsavedPrompt, UnsavedPrompt.none)
        XCTAssertEqual(c.state.count, 1)
        c.stop()
    }

    func testUnsavedPromptAfterExportStillShows() async throws {
        let ctx = Ctx()
        let c = controller(makeTempDir().appendingPathComponent("Works"), ctx)
        await c.start()
        var l = sampleLayout(ctx.ids); l.params.overlayAlpha = ctx.alpha
        await c.exportSucceeded(layout: l)                  // B10.1：导出不存；B10.4：导出过不算存过
        XCTAssertEqual(c.state.count, 0)
        XCTAssertEqual(c.unsavedPrompt, .unsaved)
        c.stop()
    }

    func testNewKeysDeclared() {
        XCTAssertEqual(L10nKey.worksUpdate.rawValue, "works.update")
        XCTAssertEqual(L10nKey.worksUpdated.rawValue, "works.updated")
        XCTAssertEqual(L10nKey.quickUnsavedUpdateTitle.rawValue, "quick.unsaved.update_title")
        for k in [L10nKey.worksUpdate, .worksUpdated, .quickUnsavedUpdateTitle] {
            XCTAssertTrue(L10nKey.allUsed.contains(k), "\(k.rawValue) 要进 allUsed，让 L10nKeyTests 检查表里存在")
        }
    }
}
