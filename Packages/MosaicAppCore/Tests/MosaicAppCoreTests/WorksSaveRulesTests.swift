import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

private func ruleDraft(_ ids: [String], alpha: Double = 0.15, seed: UInt64 = 7, cols: Int = 3,
                       target: PixelBuffer? = nil) -> WorkDraft {
    var layout = sampleLayout(ids, cols: cols, seed: seed)
    layout.params.overlayAlpha = alpha
    return WorkDraft(layout: layout, target: target, overlayAlpha: alpha, tier: nil, seed: seed, origin: .savedManually)
}

/// 「我的作品」保存规则（AndyL 11-16 22:20 定，product/hd-export-req-v0.2.md B10，改过的 B2 / B5 / B9-2、6–9）：
/// 指纹只看格子分配 + cols/rows + targetCrop；只改叠加强度 → 更新原作品；换拼法 → 新存；导出不自动存；
/// 旧作品指纹按新口径补算；已有重复不自动删；按钮状态（`works.saved`）。
final class WorksSaveRulesTests: XCTestCase {
    private func makeStore(_ dir: URL, images: FakeWorkImages = FakeWorkImages(),
                           clock: FakeWallClock = FakeWallClock()) -> FileWorksStore {
        FileWorksStore(directory: dir, images: images, now: clock.provider)
    }

    private func readMetaJSON(_ dir: URL, _ id: WorkID) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent(id.directoryName).appendingPathComponent("meta.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 把一个已存作品改成「旧版本写的」：指纹 = 旧口径（布局 JSON 的 FNV），没有 fingerprintVersion 字段。
    private func makeLegacy(_ dir: URL, _ id: WorkID) throws {
        let workDir = dir.appendingPathComponent(id.directoryName)
        let layoutData = try Data(contentsOf: workDir.appendingPathComponent("layout.json"))
        let metaURL = workDir.appendingPathComponent("meta.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        obj["fingerprint"] = FileWorksStore.fingerprint(layoutData)
        obj.removeValue(forKey: "fingerprintVersion")
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: metaURL)
    }

    // MARK: 指纹口径

    func testFingerprintIgnoresOverlaySeedDensityAndTargetSize() {
        let base = sampleLayout(["a", "b", "c"])
        var other = base
        other.params.overlayAlpha = 0.3
        other.params.seed = 999
        other.params.density = "fine"
        other.targetSize = .init(width: 4000, height: 3000)
        XCTAssertEqual(WorkFingerprint.of(base), WorkFingerprint.of(other), "叠加强度 / seed / 密度名 / 目标图尺寸不算")
        XCTAssertEqual(WorkFingerprint.of(base).count, 16)
    }

    func testFingerprintChangesWithCellsGridAndCrop() {
        let base = sampleLayout(["a", "b", "c", "d", "e", "f"])
        let fp = WorkFingerprint.of(base)
        XCTAssertNotEqual(fp, WorkFingerprint.of(sampleLayout(["b", "a", "c", "d", "e", "f"])), "换拼法")
        XCTAssertNotEqual(fp, WorkFingerprint.of(sampleLayout(["a", "b", "c", "d", "e", "f"], cols: 2)), "cols/rows")
        var crop = base
        crop.targetCrop = CropRect(x: 10, y: 0, width: 280, height: 200)
        XCTAssertNotEqual(fp, WorkFingerprint.of(crop), "targetCrop")
        var cellCrop = base
        cellCrop.cellAssignments[0].crop = CropRect(x: 0.1, y: 0, width: 0.9, height: 0.9)
        XCTAssertNotEqual(fp, WorkFingerprint.of(cellCrop), "格子裁剪")
        // 拼接歧义：["ab","c"] 与 ["a","bc"] 不能撞
        let x = sampleLayout(["ab", "c"], cols: 2)
        let y = sampleLayout(["a", "bc"], cols: 2)
        XCTAssertNotEqual(WorkFingerprint.of(x), WorkFingerprint.of(y))
    }

    func testFingerprintStableAcrossJSONRoundTrip() throws {
        var layout = sampleLayout(["a", "b", "c"])
        let w: Double = 0.1 + 0.2
        layout.targetCrop = CropRect(x: 0, y: 0, width: w, height: 200)
        let data = try FileWorksStore.encoder().encode(layout)
        let back = try FileWorksStore.decoder().decode(MosaicLayout.self, from: data)
        XCTAssertEqual(WorkFingerprint.of(layout), WorkFingerprint.of(back))
    }

    // MARK: 存储层

    /// 同格子不同叠加强度 → 一份；叠加强度、layout.json、预览图更新；日期和列表顺序不变；旧预览图删掉。
    func testOverlayOnlyChangeUpdatesExistingWork() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let images = FakeWorkImages()
        let store = makeStore(dir, images: images)
        let a = try await store.save(ruleDraft(["a", "b", "c"], alpha: 0.15, target: try smallTarget()))
        let b = try await store.save(ruleDraft(["x", "y", "z"]))
        XCTAssertEqual(images.state.get().previews, 2)
        let oldPreview = a.summary.previewURL

        let u = try await store.save(ruleDraft(["a", "b", "c"], alpha: 0.25, seed: 99))
        XCTAssertEqual(u.outcome, .updatedOverlay)
        XCTAssertFalse(u.inserted)
        XCTAssertEqual(u.summary.id, a.summary.id)
        XCTAssertEqual(images.state.get().previews, 3, "重画了预览图")
        XCTAssertEqual(images.state.get().reads, 1, "结果页没给目标图时读作品里存的副本做叠加")

        let list = await store.list()
        XCTAssertEqual(list.map(\.id), [b.summary.id, a.summary.id], "列表位置不变")
        let updated = try XCTUnwrap(list.first { $0.id == a.summary.id })
        XCTAssertEqual(updated.meta.createdAt, a.summary.meta.createdAt, "日期不变")
        XCTAssertEqual(updated.meta.overlayAlpha, 0.25)
        XCTAssertEqual(updated.meta.seed, 7, "seed 只作追溯，不跟着改")
        XCTAssertNotEqual(updated.previewURL, oldPreview, "新预览图换了文件名（列表按文件重新解码）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated.previewURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPreview.path), "旧预览图删掉")

        let work = try await store.load(a.summary.id)
        XCTAssertEqual(work.layout.params.overlayAlpha, 0.25, "layout.json 的叠加参数更新（从作品导出按新值）")
        XCTAssertEqual(work.layout.cellAssignments, sampleLayout(["a", "b", "c"]).cellAssignments, "布局不变")
        XCTAssertNotNil(work.targetURL, "目标图副本还在")
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(entries, [], "不留临时目录")

        // 再存同样的叠加强度：什么都不写
        let again = try await store.save(ruleDraft(["a", "b", "c"], alpha: 0.25))
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(images.state.get().previews, 3)
    }

    func testDifferentSeedSameCellsIsSameWork() async throws {
        let images = FakeWorkImages()
        let store = makeStore(makeTempDir(), images: images)
        let a = try await store.save(ruleDraft(["a", "b", "c"], seed: 7))
        let b = try await store.save(ruleDraft(["a", "b", "c"], seed: 8))
        XCTAssertEqual(b.outcome, .unchanged)
        XCTAssertEqual(b.summary.id, a.summary.id)
        XCTAssertEqual(images.state.get().previews, 1)
    }

    func testReshuffleOrDensityChangeIsNewWork() async throws {
        let store = makeStore(makeTempDir())
        _ = try await store.save(ruleDraft(["a", "b", "c", "d", "e", "f"]))
        let reshuffled = try await store.save(ruleDraft(["f", "e", "d", "c", "b", "a"]))
        let density = try await store.save(ruleDraft(["a", "b", "c", "d", "e", "f"], cols: 2))
        XCTAssertTrue(reshuffled.inserted)
        XCTAssertTrue(density.inserted)
        let n = await store.list().count
        XCTAssertEqual(n, 3)
    }

    /// 旧作品（v1 指纹，无 fingerprintVersion）：列表时按新口径补算并原子写回 meta.json；之后同格子的保存命中它。
    func testLegacyFingerprintBackfilledAndWrittenBack() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let images = FakeWorkImages()
        let old = try await makeStore(dir, images: images).save(ruleDraft(["a", "b", "c"], alpha: 0.15, seed: 7))
        try makeLegacy(dir, old.summary.id)
        let before = try readMetaJSON(dir, old.summary.id)
        XCTAssertNil(before["fingerprintVersion"])

        let upgraded = makeStore(dir, images: images)   // 升级后的新进程
        let list = await upgraded.list()
        XCTAssertEqual(list.first?.meta.fingerprint, WorkFingerprint.of(sampleLayout(["a", "b", "c"])))
        XCTAssertEqual(list.first?.meta.fingerprintVersion, WorkFingerprint.currentVersion)
        let after = try readMetaJSON(dir, old.summary.id)
        XCTAssertEqual(after["fingerprintVersion"] as? Int, WorkFingerprint.currentVersion, "写回 meta.json")
        XCTAssertEqual(after["fingerprint"] as? String, WorkFingerprint.of(sampleLayout(["a", "b", "c"])))
        XCTAssertEqual(after["createdAt"] as? Double, before["createdAt"] as? Double, "其余字段不变")

        // 新口径下，不同 seed 同格子 → 命中旧作品
        let r = try await upgraded.save(ruleDraft(["a", "b", "c"], alpha: 0.15, seed: 42))
        XCTAssertEqual(r.outcome, .unchanged)
        XCTAssertEqual(r.summary.id, old.summary.id)
    }

    /// 旧版本留下的重复（同格子、不同叠加 / seed，旧口径下算两张）：补算后指纹相同，但**都不删**；
    /// 保存命中最新的那份（和按钮状态取的同一份），旧的那份不动。
    func testExistingDuplicatesAreKeptAndNewestIsUsed() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let images = FakeWorkImages()
        let clock = FakeWallClock()
        let legacyStore = makeStore(dir, images: images, clock: clock)
        // 旧口径下这两份是两张（模拟：先各自存成不同格子，再把第二份的布局改成同格子）
        let older = try await legacyStore.save(ruleDraft(["a", "b", "c"], alpha: 0.10, seed: 1))
        let newer = try await legacyStore.save(ruleDraft(["q", "r", "s"], alpha: 0.20, seed: 2))
        var dupLayout = sampleLayout(["a", "b", "c"], seed: 2)
        dupLayout.params.overlayAlpha = 0.20
        try FileWorksStore.encoder().encode(dupLayout)
            .write(to: dir.appendingPathComponent(newer.summary.id.directoryName).appendingPathComponent("layout.json"))
        try makeLegacy(dir, older.summary.id)
        try makeLegacy(dir, newer.summary.id)

        let store = makeStore(dir, images: images, clock: clock)
        var list = await store.list()
        XCTAssertEqual(list.map(\.id), [newer.summary.id, older.summary.id], "重复的都还在，不自动删")
        XCTAssertEqual(list[0].meta.fingerprint, list[1].meta.fingerprint)

        let same = try await store.save(ruleDraft(["a", "b", "c"], alpha: 0.20))
        XCTAssertEqual(same.outcome, .unchanged)
        XCTAssertEqual(same.summary.id, newer.summary.id, "命中最新的那份")

        let upd = try await store.save(ruleDraft(["a", "b", "c"], alpha: 0.30))
        XCTAssertEqual(upd.outcome, .updatedOverlay)
        XCTAssertEqual(upd.summary.id, newer.summary.id)
        list = await store.list()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first { $0.id == older.summary.id }?.meta.overlayAlpha, 0.10, "旧的那份不动")
    }

    /// 并发保存同指纹：同叠加 → 一份；不同叠加 → 仍一份（后到的等前一个写完再更新），不出第二份。
    func testConcurrentSavesSameFingerprintOneWork() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let store = makeStore(dir)
        async let s1 = store.save(ruleDraft(["p", "q", "r"], alpha: 0.10))
        async let s2 = store.save(ruleDraft(["p", "q", "r"], alpha: 0.10))
        async let s3 = store.save(ruleDraft(["p", "q", "r"], alpha: 0.20, seed: 3))
        let (r1, r2, r3) = try await (s1, s2, s3)
        XCTAssertEqual(Set([r1.summary.id, r2.summary.id, r3.summary.id]).count, 1)
        XCTAssertEqual([r1, r2, r3].filter(\.inserted).count, 1)
        let list = await store.list()
        XCTAssertEqual(list.count, 1)
        let finalAlpha = try XCTUnwrap(list.first?.meta.overlayAlpha)
        XCTAssertTrue(finalAlpha == 0.10 || finalAlpha == 0.20)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    /// 更新叠加时作品被删（预览编码卡住期间）：不复活，报 notFound，不留临时目录。
    func testDeleteDuringOverlayUpdateDoesNotResurrect() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let images = FakeWorkImages()
        let store = makeStore(dir, images: images)
        let a = try await store.save(ruleDraft(["a", "b", "c"], alpha: 0.10))
        let gate = GatePoint()
        images.gate.set(gate)
        let updating = Task { try await store.save(ruleDraft(["a", "b", "c"], alpha: 0.20)) }
        await gate.reached.wait()
        try await store.delete(a.summary.id)
        images.gate.set(nil)
        await gate.release.open()
        do {
            _ = try await updating.value
            XCTFail("作品已删，更新应失败")
        } catch let e as WorksStoreError { XCTAssertEqual(e, .notFound) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [], "不复活、不留临时目录")
    }

    /// 更新叠加时预览编码失败：原作品原封不动。
    func testFailedOverlayUpdateLeavesOriginalIntact() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let images = FakeWorkImages()
        let store = makeStore(dir, images: images)
        let a = try await store.save(ruleDraft(["a", "b", "c"], alpha: 0.10))
        images.state.update { $0.failAt = .preview }
        do {
            _ = try await store.save(ruleDraft(["a", "b", "c"], alpha: 0.20))
            XCTFail("应失败")
        } catch {}
        let list = await store.list()
        XCTAssertEqual(list.map(\.id), [a.summary.id])
        XCTAssertEqual(list.first?.meta.overlayAlpha, 0.10)
        XCTAssertEqual(list.first?.previewURL, a.summary.previewURL)
        let layout = try await store.load(a.summary.id).layout
        XCTAssertEqual(layout.params.overlayAlpha, 0.10)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }
}

/// 结果页「存到我的作品」按钮状态（B10-5，产品补充）与导出不自动存（B10-1）。
@MainActor
final class WorksSaveButtonStateTests: XCTestCase {
    private struct H {
        let dir = makeTempDir().appendingPathComponent("Works")
        let images = FakeWorkImages()
        let store: FileWorksStore
        let controller: WorksController
        let relay = ExportSuccessRelay()
        let result = Locked(Box())
        struct Box: Sendable { var layout: MosaicLayout?; var target: PixelBuffer?; var alpha = 0.15; var revision = 0 }

        @MainActor init() {
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

        @MainActor func setAlpha(_ a: Double) {
            result.update { $0.alpha = a }
            controller.resultContextDidChange()
        }
    }

    func testButtonStateTransitions() async throws {
        let h = H()
        await h.controller.start()
        XCTAssertEqual(h.controller.state.saveStatus, .idle, "没有结果")
        try h.newResult(["a", "b", "c"])
        XCTAssertEqual(h.controller.state.saveStatus, .idle)
        XCTAssertTrue(h.controller.state.saveStatus.canSave)

        var seen: [WorkSaveStatus] = []
        let token = h.controller.observe { seen.append($0.saveStatus) }
        await h.controller.saveCurrentResultTapped()
        h.controller.removeObserver(token)
        guard case .saved(let id) = h.controller.state.saveStatus else { return XCTFail("应已存") }
        XCTAssertTrue(seen.contains(.saving))
        XCTAssertFalse(seen.dropFirst().contains(.idle), "存完直接变已存，不闪回可存")
        XCTAssertFalse(h.controller.state.saveStatus.canSave, "已存且没改：works.saved 不可点")

        // 只改叠加强度 → 恢复可点；改回原值 → 又是已存
        h.setAlpha(0.25)
        XCTAssertEqual(h.controller.state.saveStatus, .overlayChanged(id))
        XCTAssertTrue(h.controller.state.saveStatus.canSave)
        h.setAlpha(0.15)
        XCTAssertEqual(h.controller.state.saveStatus, .saved(id))

        // 改叠加再存 → 更新原作品，按钮回到已存
        h.setAlpha(0.3)
        await h.controller.saveCurrentResultTapped()
        XCTAssertEqual(h.controller.state.saveStatus, .saved(id))
        XCTAssertEqual(h.controller.state.summaries.map(\.id), [id])
        XCTAssertEqual(h.controller.state.summaries.first?.meta.overlayAlpha, 0.3)

        // 换一种拼法 → 新结果没存过 → 可点；存 → 两份
        try h.newResult(["c", "b", "a"])
        XCTAssertEqual(h.controller.state.saveStatus, .idle)
        await h.controller.saveCurrentResultTapped()
        XCTAssertEqual(h.controller.state.count, 2)
        guard case .saved(let id2) = h.controller.state.saveStatus else { return XCTFail("应已存") }
        XCTAssertNotEqual(id2, id)

        // 回到和第一张同格子的结果（比如重新生成出同一张）：直接显示已存（叠加 0.3 与作品一致）
        try h.newResult(["a", "b", "c"], seed: 123)
        XCTAssertEqual(h.controller.state.saveStatus, .saved(id))
        h.setAlpha(0.15)
        XCTAssertEqual(h.controller.state.saveStatus, .overlayChanged(id))

        // 删掉对应作品 → 回到可存
        h.controller.deleteTapped(id)
        await h.controller.deleteConfirmed(id)
        XCTAssertEqual(h.controller.state.saveStatus, .idle)
        h.controller.stop()
    }

    /// 从作品打开的结果同样适用：作品库里有同指纹作品就按它算（不靠「这次会话点过保存」）。
    func testStatusDerivedFromLibraryAfterRelaunch() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        await h.controller.saveCurrentResultTapped()
        guard case .saved(let id) = h.controller.state.saveStatus else { return XCTFail("应已存") }
        h.controller.stop()

        // 重启：新 controller 读同一个库，结果页是同一张
        let c2 = WorksController(store: FileWorksStore(directory: h.dir, images: h.images), existence: FakeExistence(), images: h.images)
        let r = h.result
        c2.attach(resultContext: {
            let b = r.get()
            var l = b.layout
            l?.params.overlayAlpha = b.alpha
            return WorkResultContext(layout: l, target: b.target, overlayAlpha: b.alpha, tier: nil, resultRevision: b.revision)
        }, relay: ExportSuccessRelay())
        await c2.start()
        XCTAssertEqual(c2.state.saveStatus, .saved(id))
        c2.stop()
    }

    func testFailedStaysUntilResultChanges() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        h.images.state.update { $0.failAt = .preview }
        await h.controller.saveCurrentResultTapped()
        XCTAssertEqual(h.controller.state.saveStatus, .failed)
        await h.controller.reload()
        XCTAssertEqual(h.controller.state.saveStatus, .failed, "结果没变：仍显示失败（works.save_failed）")
        XCTAssertTrue(h.controller.state.saveStatus.canSave, "失败可重试")
        h.setAlpha(0.2)
        XCTAssertEqual(h.controller.state.saveStatus, .idle, "结果变了：回到按库计算")
        h.images.state.update { $0.failAt = nil }
        await h.controller.saveCurrentResultTapped()
        if case .saved = h.controller.state.saveStatus {} else { XCTFail("重试应成功") }
        h.controller.stop()
    }

    /// 导出成功（经中继）不进库，按钮仍可点；只改叠加后导出也不更新原作品。
    func testExportViaRelayNeverSaves() async throws {
        let h = H()
        await h.controller.start()
        try h.newResult(["a", "b", "c"])
        let layout = try XCTUnwrap(h.result.get().layout)
        await h.relay.handler(layout, URL(fileURLWithPath: "/tmp/x.jpg"))
        await h.controller.exportSucceeded(layout: layout)
        var n = await h.store.list().count
        XCTAssertEqual(n, 0)
        XCTAssertEqual(h.controller.state.saveStatus, .idle)

        await h.controller.saveCurrentResultTapped()
        guard case .saved(let id) = h.controller.state.saveStatus else { return XCTFail("应已存") }
        h.setAlpha(0.28)
        var l2 = layout
        l2.params.overlayAlpha = 0.28
        await h.relay.handler(l2, URL(fileURLWithPath: "/tmp/y.jpg"))
        await h.controller.exportSucceeded(layout: l2)
        n = await h.store.list().count
        XCTAssertEqual(n, 1)
        XCTAssertEqual(h.controller.state.summaries.first?.meta.overlayAlpha, 0.15, "导出不更新作品")
        XCTAssertEqual(h.controller.state.saveStatus, .overlayChanged(id), "未保存的叠加改动仍待存")
        XCTAssertEqual(h.images.state.get().previews, 1)
        h.controller.stop()
    }
}
