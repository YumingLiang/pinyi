import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 更新叠加强度的原子性（QA PR #17 复核 P3「更新途中被杀，强度和预览对不上」）：
/// meta.json 是唯一提交点，带 `pendingPreviewFile` 日志；在每个可能被杀的位置造出磁盘状态，验证读时一致。
final class WorksAtomicUpdateTests: XCTestCase {
    private func makeStore(_ dir: URL, _ images: FakeWorkImages) -> FileWorksStore {
        FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
    }

    private func draft(_ alpha: Double) -> WorkDraft {
        var l = sampleLayout(["a", "b", "c"])
        l.params.overlayAlpha = alpha
        return WorkDraft(layout: l, target: nil, overlayAlpha: alpha, tier: nil, seed: 7, origin: .savedManually)
    }

    private func metaJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func writeJSON(_ obj: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: url)
    }

    private func layoutAlpha(_ workDir: URL) throws -> Double {
        let data = try Data(contentsOf: workDir.appendingPathComponent("layout.json"))
        return try FileWorksStore.decoder().decode(MosaicLayout.self, from: data).params.overlayAlpha
    }

    /// 一个存好的作品（强度 0.15），返回作品目录。
    private func savedWork() async throws -> (dir: URL, id: WorkID, workDir: URL, images: FakeWorkImages) {
        let dir = makeTempDir().appendingPathComponent("Works")
        let images = FakeWorkImages()
        let r = try await makeStore(dir, images).save(draft(0.15))
        return (dir, r.summary.id, dir.appendingPathComponent(r.summary.id.directoryName), images)
    }

    /// 正常更新：结束后没有临时预览、没有日志，三处强度一致。
    func testNormalUpdateLeavesNoJournal() async throws {
        let w = try await savedWork()
        let store = makeStore(w.dir, w.images)
        let u = try await store.save(draft(0.25))
        XCTAssertEqual(u.outcome, .updatedOverlay)
        XCTAssertNil(u.summary.meta.pendingPreviewFile)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: w.workDir.path))
        XCTAssertEqual(files, ["meta.json", "layout.json", "preview.jpg"])
        XCTAssertNil(try metaJSON(w.workDir.appendingPathComponent("meta.json"))["pendingPreviewFile"], "JSON 里不留这一项")
        XCTAssertEqual(try layoutAlpha(w.workDir), 0.25)
        XCTAssertEqual(w.images.state.get().previews, 2, "重画了预览")
    }

    /// 在提交点（meta.json）之前被杀：只多了一个临时预览。作品还是旧强度、旧预览；启动清理删掉临时预览。
    func testKilledBeforeCommitKeepsOldAndCleansOrphan() async throws {
        let w = try await savedWork()
        let orphan = w.workDir.appendingPathComponent(FileWorksStore.pendingPreviewPrefix + "X.jpg")
        try Data("PREVIEW:alpha=0.25".utf8).write(to: orphan)

        let store = makeStore(w.dir, w.images)
        let list = await store.list()
        XCTAssertEqual(list.first?.meta.overlayAlpha, 0.15)
        let work = try await store.load(w.id)
        XCTAssertEqual(work.layout.params.overlayAlpha, 0.15)
        let preview = String(decoding: try FakeWorkImages.previewHeader(w.workDir.appendingPathComponent("preview.jpg")), as: UTF8.self)   // #11 的假预览第一行之后是像素
        XCTAssertTrue(preview.hasPrefix("PREVIEW:3x1:"), "还是原来的预览：\(preview)")

        await store.removeIncomplete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "没登记的临时预览被清掉")
    }

    /// 提交点之后、预览还没换过去时被杀：读时前滚，预览换成新强度、layout 对齐、日志清掉。
    func testKilledAfterCommitRollsForwardPreviewAndLayout() async throws {
        let w = try await savedWork()
        let pendingName = FileWorksStore.pendingPreviewPrefix + "Y.jpg"
        try Data("PREVIEW:alpha=0.25".utf8).write(to: w.workDir.appendingPathComponent(pendingName))
        let metaURL = w.workDir.appendingPathComponent("meta.json")
        var obj = try metaJSON(metaURL)
        obj["overlayAlpha"] = 0.25
        obj["updatedAt"] = 5_000
        obj["pendingPreviewFile"] = pendingName
        try writeJSON(obj, metaURL)

        let store = makeStore(w.dir, w.images)
        await store.removeIncomplete()                       // 启动清理不能删掉已登记的临时预览
        let list = await store.list()
        XCTAssertEqual(list.first?.meta.overlayAlpha, 0.25)
        XCTAssertNil(list.first?.meta.pendingPreviewFile)
        let preview = try String(contentsOf: w.workDir.appendingPathComponent("preview.jpg"), encoding: .utf8)
        XCTAssertTrue(preview.hasPrefix("PREVIEW:alpha=0.25"), "预览前滚成新强度：\(preview)")
        XCTAssertEqual(try layoutAlpha(w.workDir), 0.25, "layout.json 对齐 meta")
        XCTAssertNil(try metaJSON(metaURL)["pendingPreviewFile"], "日志写回清掉")
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: w.workDir.path))
        XCTAssertEqual(files, ["meta.json", "layout.json", "preview.jpg"])
        let work = try await store.load(w.id)
        XCTAssertEqual(work.layout.params.overlayAlpha, 0.25)
    }

    /// 预览已换过去、layout.json 还没改时被杀：读时清日志；打开作品以 meta 的强度为准（导出按新强度）。
    func testKilledAfterPreviewSwapUsesMetaAlpha() async throws {
        let w = try await savedWork()
        try Data("PREVIEW:alpha=0.25".utf8).write(to: w.workDir.appendingPathComponent("preview.jpg"))
        let metaURL = w.workDir.appendingPathComponent("meta.json")
        var obj = try metaJSON(metaURL)
        obj["overlayAlpha"] = 0.25
        obj["updatedAt"] = 5_000
        obj["pendingPreviewFile"] = FileWorksStore.pendingPreviewPrefix + "Z.jpg"   // 文件已经不在了
        try writeJSON(obj, metaURL)

        let store = makeStore(w.dir, w.images)
        let work = try await store.load(w.id)
        XCTAssertEqual(work.layout.params.overlayAlpha, 0.25, "以 meta 为准")
        XCTAssertEqual(work.meta.overlayAlpha, 0.25)
        XCTAssertEqual(try layoutAlpha(w.workDir), 0.25, "前滚时 layout.json 也对齐了")
        XCTAssertNil(try metaJSON(metaURL)["pendingPreviewFile"])
    }

    /// 只有 layout.json 是旧强度（更早的实现被杀留下的状态也一样）：打开时以 meta 为准。
    func testLoadPrefersMetaAlphaForUpdatedWork() async throws {
        let w = try await savedWork()
        let metaURL = w.workDir.appendingPathComponent("meta.json")
        var obj = try metaJSON(metaURL)
        obj["overlayAlpha"] = 0.30
        obj["updatedAt"] = 5_000
        try writeJSON(obj, metaURL)
        let work = try await makeStore(w.dir, w.images).load(w.id)
        XCTAssertEqual(work.layout.params.overlayAlpha, 0.30)
    }
}
