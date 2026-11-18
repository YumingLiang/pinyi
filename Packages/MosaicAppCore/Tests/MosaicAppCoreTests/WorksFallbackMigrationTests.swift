import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 旧作品兜底迁移（架构师 11-17 最终方案第 5 条，`fallbackVersion = 2`）：旧兜底图整体作废、删文件；
/// 这些格子重新走 匹配 → 分类 → decide，旧作品里的删除格也一律填目标色（旧预览可能已带隐藏照片的像素）；
/// 经 `FileWorksStore` 串行入口重画预览 / 缩略图、写版本 2；完成前列表和查看页显示占位图。
@MainActor
final class WorksFallbackMigrationTests: XCTestCase {
    typealias RGB8 = FakeWorkImages.RGB8
    /// 哨兵色：旧兜底图 / 旧预览里「隐藏照片的像素」。离所有目标格颜色都远。
    nonisolated static let sentinel = RGB8(r: 3, g: 251, b: 7)
    static let red = RGB8(r: 200, g: 30, b: 30)        // 目标图格 1
    static let cyan = RGB8(r: 30, g: 200, b: 200)      // 目标图格 4

    private struct Harness {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let existence = FakeExistence()
        let store: FileWorksStore
        let controller: WorksController
        let exporter = RecordingWorkExporter()
        @MainActor init(rematcher: (any MissingCellRematching)? = nil) {
            store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
            controller = WorksController(store: store, existence: existence, images: images, rematcher: rematcher)
            controller.exportHandler = exporter
        }
        /// 造一个旧版（fallbackVersion 缺省）作品：格 1、4 是旧兜底格，旧兜底图和旧预览整张都是哨兵色。
        func legacyWork() async throws -> WorkID {
            let t = await WorksRematchTests.target(cols: 3, rows: 2, colors: WorksRematchTests.cellColors)
            let id = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c", "d", "e", "f"]), target: t, overlayAlpha: 0.2,
                                                    tier: "uhd", seed: 7, origin: .autoSavedOnExport)).summary.id
            let w = try await store.dropMissingPhotos(["b", "e"], for: id, reasons: ["b": .deleted, "e": .deleted])
            let wdir = dir.appendingPathComponent(id.directoryName, isDirectory: true)
            // 现在的写回不再产生兜底格 / 兜底图：手工改成旧版的样子——格 1、4 标 fb（去掉 fc）、登记一张旧兜底图
            var legacy = w.layout
            for i in [1, 4] { legacy.cellAssignments[i].fill = nil; legacy.cellAssignments[i].fallback = true }
            try FileWorksStore.encoder().encode(legacy).write(to: wdir.appendingPathComponent(FileWorksStore.layoutFileName))
            // 旧兜底图、旧预览都是哨兵色（同尺寸）
            let atlasName = "fallback-legacy0.png"
            let cp = FakeWorkImages.cellPixels
            try FakeWorkImages.raw(Self.solid(3 * cp, 2 * cp, WorksFallbackMigrationTests.sentinel)).write(to: wdir.appendingPathComponent(atlasName))
            let prev = try XCTUnwrap(FakeWorkImages.decodeRaw(try Data(contentsOf: w.summary.previewURL)))
            try FakeWorkImages.raw(Self.solid(prev.width, prev.height, WorksFallbackMigrationTests.sentinel)).write(to: w.summary.previewURL)
            // meta 去掉 fallbackVersion = 旧版，登记旧兜底图
            let metaURL = wdir.appendingPathComponent(FileWorksStore.metaFileName)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
            XCTAssertNotNil(json.removeValue(forKey: "fallbackVersion"), "新写的作品带版本号")
            json["fallbackFile"] = atlasName
            try JSONSerialization.data(withJSONObject: json).write(to: metaURL)
            return id
        }
        func atlasURL(_ id: WorkID, _ name: String) -> URL {
            dir.appendingPathComponent(id.directoryName, isDirectory: true).appendingPathComponent(name)
        }
        static func solid(_ w: Int, _ h: Int, _ c: RGB8) -> PixelBuffer {
            try! PixelBuffer(width: w, height: h, bytes: Array((0..<(w * h)).map { _ in [c.r, c.g, c.b, 255] }.joined()))
        }
    }

    static func containsSentinel(_ p: PixelBuffer) -> Bool {
        for y in 0..<p.height { for x in 0..<p.width {
            let c = p.rgb(x: x, y: y)
            let r = Int(c.r), g = Int(c.g), b = Int(c.b)
            if abs(r - Int(sentinel.r)) <= 12 && abs(g - Int(sentinel.g)) <= 12 && abs(b - Int(sentinel.b)) <= 12 { return true }
        } }
        return false
    }
    static func near(_ a: RGB8?, _ b: RGB8, _ tol: Int = 10) -> Bool {
        guard let a else { return false }
        return abs(Int(a.r) - Int(b.r)) <= tol && abs(Int(a.g) - Int(b.g)) <= tol && abs(Int(a.b) - Int(b.b)) <= tol
    }

    func testLegacyMetaNeedsMigrationAndListShowsPlaceholder() async throws {
        let h = Harness()
        let id = try await h.legacyWork()
        let s = try await h.store.load(id).summary
        XCTAssertNil(s.meta.fallbackVersion)
        XCTAssertTrue(s.meta.needsFallbackMigration)
        XCTAssertTrue(s.showsPlaceholder, "迁移前列表 / 查看页用占位图，不显示旧预览")
        // 没有兜底格的旧作品不需要迁移
        var plain = s.meta
        plain.fallbackCellCount = 0; plain.fallbackFile = nil
        XCTAssertFalse(plain.needsFallbackMigration)
        plain.fallbackCellCount = 2; plain.fallbackVersion = 2
        XCTAssertFalse(plain.needsFallbackMigration, "v2 只有纯色格（没有兜底图）：不用迁移")
        plain.fallbackFile = "fallback-v2crop.png"
        XCTAssertTrue(plain.needsFallbackMigration, "Q1：v2 删除格裁的旧预览兜底图同样作废")
        plain.fallbackVersion = WorkMeta.currentFallbackVersion
        XCTAssertTrue(plain.needsFallbackMigration, "任何还登记着的兜底图都要迁移")
    }

    /// 打开：旧兜底图删掉、格子改填目标色、重画预览、写当前版本；哨兵色哪儿都不出现（预览、兜底、导出）。
    func testOpenMigratesAndSentinelNeverAppears() async throws {
        let h = Harness()
        let id = try await h.legacyWork()
        let oldAtlas = try await h.store.load(id).meta.fallbackFile
        await h.controller.start()
        XCTAssertTrue(h.controller.state.summaries.first { $0.id == id }?.showsPlaceholder ?? false)
        let readsBefore = h.images.state.get().imageReads
        await h.controller.open(id)
        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(work.meta.fallbackVersion, WorkMeta.currentFallbackVersion)
        XCTAssertFalse(work.summary.showsPlaceholder)
        XCTAssertNil(work.meta.fallbackFile, "旧兜底图整体作废")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.atlasURL(id, try XCTUnwrap(oldAtlas)).path), "旧兜底图文件删掉")
        XCTAssertFalse(work.layout.cellAssignments[1].fallback || work.layout.cellAssignments[4].fallback)
        XCTAssertEqual(work.layout.cellAssignments[1].fill, CellColor(r: 200, g: 30, b: 30), "删除格也填目标色（不裁旧预览）")
        XCTAssertEqual(work.layout.cellAssignments[4].fill, CellColor(r: 30, g: 200, b: 200))
        XCTAssertEqual(h.images.state.get().imageReads, readsBefore, "迁移不读旧兜底图 / 旧预览")
        XCTAssertFalse(Self.containsSentinel(try XCTUnwrap(FakeWorkImages.decodeRaw(try Data(contentsOf: work.summary.previewURL)))),
                       "新预览没有哨兵色")
        XCTAssertEqual(h.controller.state.summaries.first { $0.id == id }?.showsPlaceholder, false, "列表换成新预览")

        await h.controller.exportOpenedTapped(purpose: .save)
        let fb = try XCTUnwrap(h.exporter.fallbacks.last)
        XCTAssertTrue(Self.near(fb[1], Self.red) && Self.near(fb[4], Self.cyan), "\(fb)")
        XCTAssertFalse(fb.values.contains { Self.near($0, Self.sentinel, 12) })
        let tiles = await FileWorksStore(directory: h.dir, images: h.images).fallbackTiles(for: id, transientCells: [])
        XCTAssertFalse(tiles.values.contains { Self.containsSentinel($0) }, "重开后的 HQ 导出兜底也没有哨兵色")
        h.controller.stop()

        // 再打开：已是当前版本，不再改写
        let again = try await h.store.load(id)
        XCTAssertEqual(again.layout, work.layout)
    }

    /// 迁移之前直接取兜底（例如导出先于打开完成）：旧兜底图 / 旧预览一律不用，按目标色补。
    func testLegacyFallbackTilesNeverUseOldAtlas() async throws {
        let h = Harness()
        let id = try await h.legacyWork()
        let readsBefore = h.images.state.get().imageReads
        let tiles = await h.store.fallbackTiles(for: id, transientCells: [])
        XCTAssertEqual(Set(tiles.keys), [1, 4])
        XCTAssertFalse(tiles.values.contains { Self.containsSentinel($0) })
        XCTAssertTrue(Self.near(FakeWorkImages.average(try XCTUnwrap(tiles[1])), Self.red))
        XCTAssertEqual(h.images.state.get().imageReads, readsBefore)
    }

    /// 受限访问（产品 04:00 Q2、架构师 A）：不迁移、不改写作品（文件逐字节不变），列表 / 查看页都是占位；
    /// 导出照样填目标色、不写回；拿到完整权限、回到前台后再迁移。
    func testLimitedAccessDoesNotMigrateUntilFullAccess() async throws {
        let h = Harness()
        let id = try await h.legacyWork()
        let wdir = h.dir.appendingPathComponent(id.directoryName, isDirectory: true)
        func snapshot() throws -> [String: Data] {
            var r: [String: Data] = [:]
            for f in try FileManager.default.contentsOfDirectory(atPath: wdir.path) { r[f] = try Data(contentsOf: wdir.appendingPathComponent(f)) }
            return r
        }
        let before = try snapshot()
        h.existence.fullAccess.set(false)
        await h.controller.start()
        XCTAssertTrue(h.controller.state.limitedAccess)
        await h.controller.open(id)
        XCTAssertEqual(h.controller.state.openedPreviewDisplay, .limitedAccess)
        await h.controller.exportOpenedTapped(purpose: .save)
        let fb = try XCTUnwrap(h.exporter.fallbacks.last)
        XCTAssertTrue(Self.near(fb[1], Self.red) && Self.near(fb[4], Self.cyan), "\(fb)")
        XCTAssertEqual(try snapshot(), before, "受限访问下作品目录逐字节不变")

        h.existence.fullAccess.set(true)
        await h.controller.refreshLibraryAccess()
        XCTAssertFalse(h.controller.state.limitedAccess)
        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(work.meta.fallbackVersion, WorkMeta.currentFallbackVersion)
        XCTAssertNil(work.meta.fallbackFile)
        XCTAssertEqual(work.layout.cellAssignments[1].fill, CellColor(r: 200, g: 30, b: 30))
        XCTAssertFalse(Self.containsSentinel(try XCTUnwrap(FakeWorkImages.decodeRaw(try Data(contentsOf: work.summary.previewURL)))))
        XCTAssertEqual(h.controller.state.openedPreviewDisplay, .preview(work.summary.previewURL))
        h.controller.stop()
    }

    /// 补格器在迁移时也跑：旧兜底格能补上照片的补照片，补不上的才填色。
    func testMigrationRematchesOldFallbackCells() async throws {
        let rm = CountingRematcher { layout, _ in
            var l = layout
            l.cellAssignments[1] = .init(localIdentifier: "x")
            return WorkRematchResult(layout: l, replacedCells: 1, blankCells: 1, droppedPhotos: 0)
        }
        let h = Harness(rematcher: rm)
        let id = try await h.legacyWork()
        await h.controller.start()
        await h.controller.open(id)
        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(rm.calls.get(), 1)
        XCTAssertEqual(work.layout.cellAssignments[1].localIdentifier, "x")
        XCTAssertEqual(work.layout.cellAssignments[4].fill, CellColor(r: 30, g: 200, b: 200))
        XCTAssertEqual(work.meta.fallbackVersion, WorkMeta.currentFallbackVersion)
        h.controller.stop()
    }

    /// P3：同一作品重找过一次没找到，再打开不重找；相册变化后再找。
    func testBlankRetryNotRepeatedUntilLibraryChanges() async throws {
        let rm = CountingRematcher { layout, _ in WorkRematchResult(layout: layout, replacedCells: 0, blankCells: 1, droppedPhotos: 0) }
        let h = Harness(rematcher: rm)
        let t = WorksRematchTests.target(cols: 3, rows: 2, colors: WorksRematchTests.cellColors)
        let id = try await h.store.save(WorkDraft(layout: sampleLayout(["a", "b", "c", "d", "e", "f"]), target: t, overlayAlpha: 0.2,
                                                  tier: "uhd", seed: 7, origin: .autoSavedOnExport)).summary.id
        _ = try await h.store.dropMissingPhotos(["b"], for: id, reasons: ["b": .hidden])
        await h.controller.start()
        await h.controller.open(id)
        XCTAssertEqual(rm.calls.get(), 1)
        h.controller.close()
        await h.controller.open(id)
        XCTAssertEqual(rm.calls.get(), 1, "没变化不重找")
        h.controller.close()
        h.controller.libraryDidChange()
        await h.controller.open(id)
        XCTAssertEqual(rm.calls.get(), 2, "相册变了再找一次")
        h.controller.stop()
    }

    /// 源码守护：Works/ 下不再有逐张清晰度探测。
    func testWorksSourcesHaveNoResolutionProbe() throws {
        let here = URL(fileURLWithPath: #filePath)
        let pkg = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let roots = [pkg.appendingPathComponent("Sources/MosaicAppCore/Works"),
                     pkg.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Works")]
        var checked = 0
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                let src = try String(contentsOf: url, encoding: .utf8)
                for banned in ["LocalResolutionChecker", "PhotoKitResolutionProbe", "invalidateLocalResolution"] {
                    XCTAssertFalse(src.contains(banned), "\(url.lastPathComponent) 用了 \(banned)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 3)
    }
}

/// 计数补格器（不碰图片）。
final class CountingRematcher: MissingCellRematching, Sendable {
    let calls = Locked(0)
    let body: @Sendable (MosaicLayout, Set<String>) -> WorkRematchResult
    init(_ body: @escaping @Sendable (MosaicLayout, Set<String>) -> WorkRematchResult) { self.body = body }
    func rematch(_ layout: MosaicLayout, missing: Set<String>, target: PixelBuffer?) async throws -> WorkRematchResult {
        calls.update { $0 += 1 }
        return body(layout, missing)
    }
}
