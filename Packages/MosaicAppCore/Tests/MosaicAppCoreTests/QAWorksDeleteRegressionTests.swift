import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

// QA 回归：「我的作品」删除 + 防重复保存（AndyL 真机 22:08 报「这个删除不工作」，构建 e8355ae Internal）。
// 依赖 MosaicAppCoreTests 里已有的 WorksFakes.swift / Fakes.swift / CoordinatorFakes.swift
// （FakeWorkImages、FakeExistence、FakeWallClock、sampleLayout、smallTarget、makeTempDir、Locked、GatePoint、AsyncGate）。
// 用法：临时拷进 Packages/MosaicAppCore/Tests/MosaicAppCoreTests/ 后 `swift test --filter QAWorksDelete`。

/// 可在第 N 次查询时停住的「原照片还在不在」（模拟打开作品时的 PhotoKit 批量查询很慢）。
final class QAGatedExistence: PhotoExistenceChecking, Sendable {
    let gate: GatePoint
    let calls = Locked(0)
    let gateAt: Int
    init(gate: GatePoint, gateAt: Int = 1) { self.gate = gate; self.gateAt = gateAt }
    func existingIdentifiers(among identifiers: [String]) async -> Set<String> {
        let n = calls.update { c -> Int in c += 1; return c }
        if n == gateAt {
            await gate.reached.open()
            await gate.release.wait()
        }
        // 一半照片「现在用不了」，保证 missingCount != 0，会走 setMissingCount 写回 meta.json
        return Set(identifiers.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
    }
}

@MainActor
final class QAWorksDeleteRegressionTests: XCTestCase {
    private struct H {
        let dir: URL
        let images: FakeWorkImages
        let clock = FakeWallClock()
        let store: FileWorksStore
        let controller: WorksController
        let relay = ExportSuccessRelay()
        let result = Locked(Box())
        struct Box: Sendable { var layout: MosaicLayout?; var target: PixelBuffer?; var alpha = 0.15; var revision = 0 }

        @MainActor init(dir: URL = makeTempDir().appendingPathComponent("Works"),
                        images: FakeWorkImages = FakeWorkImages(),
                        existence: any PhotoExistenceChecking = FakeExistence()) {
            self.dir = dir
            self.images = images
            store = FileWorksStore(directory: dir, images: images, now: clock.provider)
            controller = WorksController(store: store, existence: existence, images: images)
            let r = result
            // 与 AppCoordinator+Works.workResultContext 一致：layout 的 params.overlayAlpha = 当前滑杆值
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

        /// 存一张新作品，返回 id。
        @MainActor func saveNew(_ ids: [String], seed: UInt64 = 7) async throws -> WorkID {
            try newResult(ids, seed: seed)
            await controller.saveCurrentResultTapped()
            guard case .saved(let id) = controller.state.saveStatus else { throw XCTSkip("保存失败") }
            return id
        }

        /// 走 controller 的二次确认删除（UI 正确接线时的调用顺序：先 tapped，再 confirmed）。
        @MainActor func delete(_ id: WorkID) async {
            controller.deleteTapped(id)
            await controller.deleteConfirmed()
        }

        func exists(_ id: WorkID) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(id.directoryName).path) }
        func entries() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] }
    }

    // MARK: 1 删除后列表立即消失

    func testDeleteRemovesFromListImmediately() async throws {
        let h = H()
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c"])
        let b = try await h.saveNew(["d", "e", "f"])
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [b, a])
        await h.delete(a)
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [b], "deleteConfirmed 返回时列表已刷新")
        XCTAssertEqual(h.controller.state.count, 1, "首页入口角标数同步")
        XCTAssertNil(h.controller.state.pendingDelete)
        XCTAssertNil(h.controller.state.notice)
        h.controller.stop()
    }

    // MARK: 2 重新加载 / 「杀进程重启」后仍不在

    func testDeletedWorkStaysGoneAfterRelaunch() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let h = H(dir: dir)
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c"])
        let b = try await h.saveNew(["d", "e", "f"])
        await h.delete(a)
        await h.controller.reload()
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [b], "同一 controller reload 后不回来")
        h.controller.stop()

        // 新 store + 新 controller（同目录）= 重启
        let relaunched = H(dir: dir)
        await relaunched.controller.start()
        XCTAssertEqual(relaunched.controller.state.summaries.map(\.id), [b], "重启后仍不在")
        do {
            _ = try await relaunched.store.load(a)
            XCTFail("已删作品重启后不能再打开")
        } catch let e as WorksStoreError { XCTAssertEqual(e, .notFound) }
        relaunched.controller.stop()
    }

    // MARK: 3 作品目录、预览、目标图、meta、layout 全部删掉，不留 .trash

    func testDeleteRemovesDirectoryPreviewAndLeavesNoTrash() async throws {
        let h = H()
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c"])
        let summary = try XCTUnwrap(h.controller.state.summaries.first { $0.id == a })
        let workDir = h.dir.appendingPathComponent(a.directoryName)
        for f in ["meta.json", "layout.json", "preview.jpg", "target.jpg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: workDir.appendingPathComponent(f).path), "删前应有 \(f)")
        }
        await h.delete(a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.path), "作品目录删掉")
        XCTAssertFalse(FileManager.default.fileExists(atPath: summary.previewURL.path), "预览（列表缩略图来源）删掉")
        XCTAssertEqual(h.entries(), [], "不留 .trash- / .tmp- 目录")
        h.controller.stop()
    }

    // MARK: 4 删除正在打开（PhotoKit 缺失检查中）的作品：之后的 setMissingCount 不会把目录写回来

    func testDeleteWhileOpenMissingCheckInFlightIsNotWrittenBack() async throws {
        let gate = GatePoint()
        let h = H(existence: QAGatedExistence(gate: gate))
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c", "d", "e", "f"])
        let opening = Task { @MainActor in await h.controller.open(a) }
        await gate.reached.wait()                 // open() 已读完布局，卡在缺失检查
        XCTAssertEqual(h.controller.state.opened?.id, a)
        await h.delete(a)                         // 查看页上点删除并确认
        await gate.release.open()
        await opening.value
        XCTAssertFalse(h.exists(a), "缺失检查结束后的 setMissingCount 不能重建作品目录")
        XCTAssertEqual(h.entries(), [], "也不能留下孤立的 meta.json")
        XCTAssertNil(h.controller.state.opened, "查看页已关闭，不会被迟到的 open 重新打开")
        await h.controller.reload()
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [], "reload 后列表仍为空")
        h.controller.stop()
    }

    // MARK: 4b 删除时另一张作品正在写（预览编码卡住）：写完后被删的不回来，新作品正常出现

    func testDeleteWhileAnotherSaveIsEncodingPreview() async throws {
        let h = H()
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c"])
        let gate = GatePoint()
        h.images.gate.set(gate)
        try h.newResult(["x", "y", "z"])
        let saving = Task { @MainActor in await h.controller.saveCurrentResultTapped() }
        await gate.reached.wait()
        await h.delete(a)
        h.images.gate.set(nil)
        await gate.release.open()
        await saving.value
        let ids = h.controller.state.summaries.map(\.id)
        XCTAssertEqual(ids.count, 1)
        XCTAssertFalse(ids.contains(a), "被删的不被并发保存的 reload 写回列表")
        XCTAssertFalse(h.exists(a))
        h.controller.stop()
    }

    // MARK: 4c 删除后，同一结果再导出成功不会存（B10-1 导出不自动存）；再点「存到我的作品」是新 id 的新作品，不是旧目录复活
    // （原 testExportAfterDeleteSavesAgainAsNewWork：按 AndyL 11-16 22:20 新规则改名改断言）

    func testExportAfterDeleteDoesNotSaveManualSaveAddsNewWork() async throws {
        let h = H()
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c"])
        await h.delete(a)
        XCTAssertEqual(h.controller.state.saveStatus, .idle, "删掉后结果页按钮回到可存")
        await h.controller.exportSucceeded(layout: try XCTUnwrap(h.result.get().layout.map { var l = $0; l.params.overlayAlpha = 0.15; return l }))
        XCTAssertEqual(h.controller.state.count, 0, "导出不自动存")
        await h.controller.saveCurrentResultTapped()
        let ids = h.controller.state.summaries.map(\.id)
        XCTAssertEqual(ids.count, 1)
        XCTAssertNotEqual(ids.first, a, "是新 id 的新作品，不是旧目录复活")
        h.controller.stop()
    }

    // MARK: 5 连续删除多个

    func testDeleteSeveralInARow() async throws {
        let h = H()
        await h.controller.start()
        var ids: [WorkID] = []
        for i in 0..<5 { ids.append(try await h.saveNew(["p\(i)", "q\(i)", "r\(i)"])) }
        XCTAssertEqual(h.controller.state.count, 5)
        await h.delete(ids[0]); await h.delete(ids[2]); await h.delete(ids[4])
        XCTAssertEqual(Set(h.controller.state.summaries.map(\.id)), [ids[1], ids[3]])
        await h.delete(ids[1]); await h.delete(ids[3])
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [])
        XCTAssertEqual(h.entries(), [])
        h.controller.stop()
    }

    // MARK: 6 删除后再存新作品，索引（列表顺序、查重）仍正确

    func testSaveAfterDeleteKeepsListCorrect() async throws {
        let h = H()
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c"])
        let b = try await h.saveNew(["d", "e", "f"])
        await h.delete(b)
        let c = try await h.saveNew(["g", "h", "i"])
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [c, a], "新的在前，删掉的不在")
        // 删掉 b 后再存与 b 相同的布局：应能重新存进来（查重不能还认已删的 b）
        let b2 = try await h.saveNew(["d", "e", "f"])
        XCTAssertNotEqual(b2, b)
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [b2, c, a])
        let relaunched = H(dir: h.dir)
        await relaunched.controller.start()
        XCTAssertEqual(relaunched.controller.state.summaries.map(\.id), [b2, c, a])
        h.controller.stop(); relaunched.controller.stop()
    }

    // MARK: B 防重复保存（截图里两张几乎一样的作品）

    /// 同一结果连点两次（含并发双击）→ 只有一份；按钮变「已保存」(.saved)。
    func testSaveSameResultTwiceIsIdempotent() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        async let t1: Void = h.controller.saveCurrentResultTapped()
        async let t2: Void = h.controller.saveCurrentResultTapped()
        _ = await (t1, t2)
        await h.controller.saveCurrentResultTapped()
        XCTAssertEqual(h.controller.state.count, 1, "连点只存一份")
        guard case .saved = h.controller.state.saveStatus else { return XCTFail("按钮应为已保存") }
        let onDisk = await h.store.list().count
        XCTAssertEqual(onDisk, 1)
        h.controller.stop()
    }

    /// 存储层并发保存同一布局 → 一份（inFlight 合并）。
    func testStoreConcurrentSaveSameLayoutOneWork() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let store = FileWorksStore(directory: dir, images: FakeWorkImages(), now: FakeWallClock().provider)
        let d = WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, tier: nil, seed: 7, origin: .savedManually)
        async let r1 = store.save(d)
        async let r2 = store.save(d)
        let (x, y) = try await (r1, r2)
        XCTAssertEqual(x.summary.id, y.summary.id)
        XCTAssertEqual([x.inserted, y.inserted].filter { $0 }.count, 1)
        let n = await store.list().count
        XCTAssertEqual(n, 1)
    }

    /// 手动存 → 再导出同一结果 → 仍一份（导出不自动存，B10-1）；按钮仍是「已存」。
    /// （原 testSaveThenExportSameResultOneWork：新规则下改名）
    func testSaveThenExportSameResultStillOneWork() async throws {
        let h = H()
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c"])
        var l = try XCTUnwrap(h.result.get().layout); l.params.overlayAlpha = h.result.get().alpha
        await h.controller.exportSucceeded(layout: l)
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [a])
        XCTAssertEqual(h.controller.state.saveStatus, .saved(a))
        h.controller.stop()
    }

    // MARK: B4–B6 查重口径（AndyL 11-16 22:20 定，需求 B10；原 characterize 现状记录按新规则改）

    /// B4：结果页存 →「调整」改叠加滑杆 → 导出：不新增；按钮变回可点（.overlayChanged）→ 再存：仍一份，原作品叠加强度更新。
    func testRule_SameCellsDifferentAlphaUpdatesOneWork() async throws {
        let h = H()
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c"])
        h.result.update { $0.alpha = 0.25 }                       // 不换结果，revision 不变
        h.controller.resultContextDidChange()
        XCTAssertEqual(h.controller.state.saveStatus, .overlayChanged(a))
        var l = try XCTUnwrap(h.result.get().layout); l.params.overlayAlpha = 0.25
        await h.controller.exportSucceeded(layout: l)
        XCTAssertEqual(h.controller.state.count, 1, "导出不自动存")
        await h.controller.saveCurrentResultTapped()
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [a], "只改叠加强度算同一张")
        XCTAssertEqual(h.controller.state.summaries.first?.meta.overlayAlpha, 0.25)
        XCTAssertEqual(h.controller.state.saveStatus, .saved(a))
    }

    /// B5：格子分配完全相同、只有 seed 不同 → 同一张（指纹不含 seed）。
    func testRule_SameCellsDifferentSeedIsSameWork() async throws {
        let h = H()
        await h.controller.start()
        let a = try await h.saveNew(["a", "b", "c"], seed: 7)
        try h.newResult(["a", "b", "c"], seed: 8)
        XCTAssertEqual(h.controller.state.saveStatus, .saved(a), "新结果和已存作品是同一张：直接显示已存")
        let b = try await h.saveNew(["a", "b", "c"], seed: 8)
        XCTAssertEqual(b, a)
        XCTAssertEqual(h.controller.state.count, 1)
    }

    /// B6：「换一种拼法」后（新 revision）按钮回到可存，再存 → 两份（B10-2）。
    func testRule_ReshuffleThenSaveBecomesTwoWorks() async throws {
        let h = H()
        await h.controller.start()
        _ = try await h.saveNew(["a", "b", "c"])
        _ = try await h.saveNew(["b", "a", "c"])
        XCTAssertEqual(h.controller.state.count, 2)
    }
}
