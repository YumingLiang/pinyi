import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 作品存储层（design/works-storage-v0.1.md；QA：存 / 列 / 删 / 重开、升级兼容、原子性）。
final class WorksStoreTests: XCTestCase {
    private func makeStore(_ dir: URL, images: FakeWorkImages = FakeWorkImages(),
                           clock: FakeWallClock = FakeWallClock()) -> FileWorksStore {
        FileWorksStore(directory: dir, images: images, now: clock.provider)
    }

    private func draft(_ ids: [String], target: PixelBuffer? = nil, origin: WorkOrigin = .savedManually) -> WorkDraft {
        WorkDraft(layout: sampleLayout(ids), target: target, overlayAlpha: 0.15, tier: "uhd", seed: 7, origin: origin)
    }

    func testSaveListLoadDeleteNewestFirst() async throws {
        let dir = makeTempDir().appendingPathComponent("Works")
        let store = makeStore(dir)
        let a = try await store.save(draft(["a", "b", "c", "a", "b", "c"], target: try smallTarget()))
        let b = try await store.save(draft(["x", "y", "z"]))
        XCTAssertTrue(a.inserted)
        XCTAssertTrue(b.inserted)

        let list = await store.list()
        XCTAssertEqual(list.map(\.id), [b.summary.id, a.summary.id], "按保存时间倒序")
        XCTAssertEqual(list[1].meta.photoCount, 3)
        XCTAssertEqual(list[1].meta.columns, 3)
        XCTAssertEqual(list[1].meta.rows, 2)
        XCTAssertEqual(list[1].meta.tier, "uhd")
        XCTAssertEqual(list[1].meta.formatVersion, WorkMeta.currentFormatVersion)
        XCTAssertEqual(list[1].meta.previewPixelWidth, WorkImageLimits.previewLongEdge)

        // 目录结构：一个作品一个 <uuid>/ 目录
        let workDir = dir.appendingPathComponent(a.summary.id.directoryName)
        for f in ["meta.json", "layout.json", "preview.jpg", "target.jpg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: workDir.appendingPathComponent(f).path), f)
        }

        // 重开：显式布局逐格一致（不靠种子重算）
        let work = try await store.load(a.summary.id)
        XCTAssertEqual(work.layout, sampleLayout(["a", "b", "c", "a", "b", "c"]))
        XCTAssertNotNil(work.targetURL)

        try await store.delete(a.summary.id)
        let after = await store.list()
        XCTAssertEqual(after.map(\.id), [b.summary.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.path), "删除后磁盘文件清掉（B9-4）")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
        do {
            try await store.delete(a.summary.id)
            XCTFail("再删应报 notFound")
        } catch let e as WorksStoreError { XCTAssertEqual(e, .notFound) }
        do {
            _ = try await store.load(a.summary.id)
            XCTFail("已删作品不能打开")
        } catch let e as WorksStoreError { XCTAssertEqual(e, .notFound) }
    }

    /// B9-2：同一张不重复存（指纹按显式布局算）；布局 JSON 往返后指纹不变（从作品再导出也命中）。
    func testSameLayoutIsStoredOnce() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let store = makeStore(dir, images: images)
        let first = try await store.save(draft(["a", "b", "c"], origin: .savedManually))
        let again = try await store.save(draft(["a", "b", "c"], origin: .autoSavedOnExport))
        XCTAssertFalse(again.inserted)
        XCTAssertEqual(again.summary.id, first.summary.id)
        XCTAssertEqual(images.state.get().previews, 1, "命中查重时不再渲染预览")

        let reloaded = try await store.load(first.summary.id).layout
        let roundTrip = try await store.save(WorkDraft(layout: reloaded, target: nil, overlayAlpha: 0.15, origin: .autoSavedOnExport))
        XCTAssertFalse(roundTrip.inserted)

        let other = try await store.save(draft(["a", "c", "b"]))
        XCTAssertTrue(other.inserted, "换一种排列是另一张作品")
        let count = await store.list().count
        XCTAssertEqual(count, 2)
    }

    /// 并发保存同一布局（自动保存与手动保存同时到）：actor 串行，只存一份。
    func testConcurrentSavesOfSameLayoutStoreOnce() async throws {
        let store = makeStore(makeTempDir())
        let d = draft(["p", "q", "r"])
        async let s1 = store.save(d)
        async let s2 = store.save(d)
        let (r1, r2) = try await (s1, s2)
        XCTAssertEqual(r1.summary.id, r2.summary.id)
        XCTAssertNotEqual(r1.inserted, r2.inserted)
        let count = await store.list().count
        XCTAssertEqual(count, 1)
    }

    /// 原子性：写到一半失败（预览 / 目标图编码失败、磁盘满）不留半个作品，临时目录也删掉。
    func testFailedWriteLeavesNoPartialWork() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let store = makeStore(dir, images: images)
        for step in [FakeWorkImages.Step.preview, .target] {
            images.state.update { $0.failAt = step }
            do {
                _ = try await store.save(draft(["a", "b", "c"], target: try smallTarget()))
                XCTFail("应失败：\(step)")
            } catch {}
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertEqual(names, [], "失败后目录里什么都不留（\(step)）")
            let count = await store.list().count
            XCTAssertEqual(count, 0)
        }
        images.state.update { $0.failAt = nil }
        let ok = try await store.save(draft(["a", "b", "c"], target: try smallTarget()))
        XCTAssertTrue(ok.inserted, "失败不影响之后再存")
    }

    /// 模拟写到一半进程被杀：临时目录 / 待删目录残留——列表不认，启动清理后消失，已有作品不受影响。
    func testKilledMidWriteLeftoversIgnoredAndCleaned() async throws {
        let dir = makeTempDir()
        let store = makeStore(dir)
        let good = try await store.save(draft(["a", "b", "c"]))
        let fm = FileManager.default
        // 1) 写临时目录时被杀：有 layout、没有 meta
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tmp.appendingPathComponent("layout.json"))
        // 2) 删除到一半被杀
        let trash = dir.appendingPathComponent(".trash-\(UUID().uuidString)")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        // 3) 外来的、没有 meta 的 uuid 目录（不该出现，但不能把列表搞崩）
        let stray = dir.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: stray, withIntermediateDirectories: true)

        let relaunched = makeStore(dir)   // 新进程
        let list = await relaunched.list()
        XCTAssertEqual(list.map(\.id), [good.summary.id])
        await relaunched.removeIncomplete()
        XCTAssertFalse(fm.fileExists(atPath: tmp.path))
        XCTAssertFalse(fm.fileExists(atPath: trash.path))
        let list2 = await relaunched.list()
        XCTAssertEqual(list2.map(\.id), [good.summary.id])
    }

    /// 升级兼容（QA「升级后重开旧作品」）：旧版 meta（缺后加字段）照常列出、打开，预览图逐字节不变；
    /// 新版写的作品（formatVersion 更高）旧版不列出、不删除。
    func testFormatVersionCompatibility() async throws {
        let dir = makeTempDir()
        let store = makeStore(dir)
        let saved = try await store.save(draft(["a", "b", "c"]))
        let previewBefore = try Data(contentsOf: saved.summary.previewURL)

        // 改成「最早版本」的 meta：只有必填字段
        let legacyID = WorkID()
        let legacyDir = dir.appendingPathComponent(legacyID.directoryName)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let layoutJSON = try FileWorksStore.encoder().encode(sampleLayout(["m", "n", "o"]))
        try layoutJSON.write(to: legacyDir.appendingPathComponent("layout.json"))
        try Data("P".utf8).write(to: legacyDir.appendingPathComponent("preview.jpg"))
        let legacyMeta = #"{"formatVersion":1,"id":"\#(legacyID.directoryName)","createdAt":1000,"columns":3,"rows":1}"#
        try Data(legacyMeta.utf8).write(to: legacyDir.appendingPathComponent("meta.json"))

        // 新版写的作品
        let futureID = WorkID()
        let futureDir = dir.appendingPathComponent(futureID.directoryName)
        try FileManager.default.createDirectory(at: futureDir, withIntermediateDirectories: true)
        try Data("P".utf8).write(to: futureDir.appendingPathComponent("preview.jpg"))
        let futureMeta = #"{"formatVersion":99,"id":"\#(futureID.directoryName)","createdAt":5000000000000,"columns":3,"rows":1}"#
        try Data(futureMeta.utf8).write(to: futureDir.appendingPathComponent("meta.json"))

        let upgraded = makeStore(dir)   // 升级后的新进程
        let list = await upgraded.list()
        XCTAssertEqual(list.map(\.id), [saved.summary.id, legacyID])
        let legacy = try await upgraded.load(legacyID)
        XCTAssertEqual(legacy.meta.previewFile, "preview.jpg")
        XCTAssertEqual(legacy.meta.missingCount, 0)
        XCTAssertNil(legacy.targetURL)
        XCTAssertEqual(legacy.layout.uniqueAssetIDs, ["m", "n", "o"])
        let reopened = try await upgraded.load(saved.summary.id)
        XCTAssertEqual(try Data(contentsOf: reopened.summary.previewURL), previewBefore, "查看用保存的预览图，逐字节一致")
        do {
            _ = try await upgraded.load(futureID)
            XCTFail("新版作品不应被旧版打开")
        } catch let e as WorksStoreError { XCTAssertEqual(e, .unsupportedFormat(99)) }
        await upgraded.removeIncomplete()
        XCTAssertTrue(FileManager.default.fileExists(atPath: futureDir.path), "新版作品不删")
    }

    func testSetMissingCountPersists() async throws {
        let dir = makeTempDir()
        let store = makeStore(dir)
        let s = try await store.save(draft(["a", "b", "c"]))
        try await store.setMissingCount(2, for: s.summary.id)
        let reloaded = await makeStore(dir).list()
        XCTAssertEqual(reloaded.first?.meta.missingCount, 2)
    }

    func testFingerprintIsStableHex() {
        XCTAssertEqual(FileWorksStore.fingerprint(Data()), "cbf29ce484222325")
        XCTAssertEqual(FileWorksStore.fingerprint(Data("a".utf8)).count, 16)
    }

    /// 文案 key 都在 Localizable.strings 里（copy_v1.1 §5.5）。
    func testWorksKeysExistInStringsFile() throws {
        let keys = try L10nKeyTests.stringsKeys()
        XCTAssertEqual(L10nKey.allWorks.map(\.rawValue).filter { !keys.contains($0) }, [])
        XCTAssertEqual(Set(L10nKey.allWorks).count, L10nKey.allWorks.count)
    }
}
