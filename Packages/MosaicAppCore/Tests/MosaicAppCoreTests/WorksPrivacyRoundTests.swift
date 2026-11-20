import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// #11 隐私修复轮（产品 03:55 Q1–Q4 / 04:00 Q2 修订、架构师 11-17 A–D）。
@MainActor
final class WorksPrivacyRoundTests: XCTestCase {
    typealias RGB8 = FakeWorkImages.RGB8
    static let sentinel = RGB8(r: 3, g: 251, b: 7)

    private struct Harness {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let existence = FakeExistence()
        let store: FileWorksStore
        let controller: WorksController
        let exporter = RecordingWorkExporter()
        @MainActor init() {
            store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
            controller = WorksController(store: store, existence: existence, images: images)
            controller.exportHandler = exporter
        }
        func save(_ ids: [String] = ["a", "b", "c", "d", "e", "f"]) async throws -> WorkID {
            let t = await WorksRematchTests.target(cols: 3, rows: 2, colors: WorksRematchTests.cellColors)
            return try await store.save(WorkDraft(layout: sampleLayout(ids), target: t, overlayAlpha: 0.2, tier: "uhd",
                                                  seed: 7, origin: .autoSavedOnExport)).summary.id
        }
        func workDir(_ id: WorkID) -> URL { dir.appendingPathComponent(id.directoryName, isDirectory: true) }
        func files(_ id: WorkID) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: workDir(id).path).sorted() }
        func meta(_ id: WorkID) throws -> WorkMeta {
            try FileWorksStore.decoder().decode(WorkMeta.self, from: Data(contentsOf: workDir(id).appendingPathComponent(FileWorksStore.metaFileName)))
        }
        static func solid(_ w: Int, _ h: Int, _ c: RGB8) -> PixelBuffer {
            try! PixelBuffer(width: w, height: h, bytes: Array((0..<(w * h)).map { _ in [c.r, c.g, c.b, 255] }.joined()))
        }
        /// 作品目录里有没有哪个图片文件带哨兵色（= 隐藏照片的像素）。
        func anyFileContainsSentinel(_ id: WorkID) throws -> Bool {
            for f in try files(id) {
                guard let p = FakeWorkImages.decodeRaw(try Data(contentsOf: workDir(id).appendingPathComponent(f))) else { continue }
                for y in 0..<p.height { for x in 0..<p.width {
                    let c = p.rgb(x: x, y: y)
                    if abs(Int(c.r) - 3) <= 12 && abs(Int(c.g) - 251) <= 12 && abs(Int(c.b) - 7) <= 12 { return true }
                } }
            }
            return false
        }
    }

    // MARK: B

    /// 普通照片只有 fc、没有旧作时可以新存。fb 布尔和形状 fc 仍拒绝，不留临时目录。
    func testWriteRejectsFilledCells() async throws {
        let h = Harness()
        var layout = sampleLayout(["a", "", "c"])
        layout.cellAssignments[1].fill = CellColor(r: 1, g: 2, b: 3)
        let made = try await h.store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0.2, origin: .savedManually))
        XCTAssertEqual(made.outcome, .inserted)
        var marked = layout
        marked.cellAssignments[1].fallback = true
        do {
            _ = try await h.store.save(WorkDraft(layout: marked, target: nil, overlayAlpha: 0.2, origin: .savedManually))
            XCTFail("fb 布尔不能跟着 fc 新作一起放开")
        } catch let e as WorksError {
            XCTAssertEqual(e, .unsupportedFilledCells)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: h.dir.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".tmp-fc-new-") })
        XCTAssertEqual(names.filter { !$0.hasPrefix(".") }.count, 1)
    }

    // MARK: D-a 孤儿文件

    /// 启动（removeIncomplete）和打开作品前，都删掉 meta 没登记的 preview* / fallback* / 临时预览；登记的不动；meta 读不出不删。
    func testOrphanImagesRemovedAtStartupAndBeforeOpen() async throws {
        let h = Harness()
        let id = try await h.save()
        let registered = try h.files(id)
        let orphans = ["preview-dead0001.jpg", "preview.jpg.old", "fallback-dead0002.png", "fallback.png",
                       FileWorksStore.pendingPreviewPrefix + "x.jpg"]
        func plant() throws {
            for f in orphans where !registered.contains(f) {
                try FakeWorkImages.raw(Harness.solid(4, 4, Self.sentinel)).write(to: h.workDir(id).appendingPathComponent(f))
            }
        }
        try plant()
        XCTAssertTrue(try h.anyFileContainsSentinel(id))
        await h.controller.start()
        XCTAssertEqual(try h.files(id), registered, "启动清掉孤儿，登记的文件都在")
        XCTAssertFalse(try h.anyFileContainsSentinel(id))

        try plant()
        await h.controller.open(id)
        XCTAssertEqual(try h.files(id), registered, "打开前也清")
        h.controller.stop()

        // meta 读不出：什么都不删
        try plant()
        try Data("garbage".utf8).write(to: h.workDir(id).appendingPathComponent(FileWorksStore.metaFileName))
        await h.store.removeIncomplete()
        XCTAssertTrue(try h.files(id).contains("preview-dead0001.jpg"))
    }

    // MARK: D-b / D-c meta 提交后、layout 没写成

    /// 模拟写回在 meta 写完、layout 写之前被杀：layout.json 还是旧的，旧预览（带隐藏像素）还在目录里。
    /// 重启清理后目录里没有任何文件带哨兵色；之后打开按待处理重新写回，指纹对齐；整个过程读旧文件 0 次。
    func testKillAfterMetaBeforeLayoutLeavesNoSentinelAndRealigns() async throws {
        for unhideBeforeReopen in [false, true] {
            let h = Harness()
            let id = try await h.save()
            let oldMeta = try h.meta(id)
            let oldLayoutData = try Data(contentsOf: h.workDir(id).appendingPathComponent(FileWorksStore.layoutFileName))
            // 旧预览里有隐藏照片 b 的像素：用哨兵色代表
            let oldPreviewURL = h.workDir(id).appendingPathComponent(oldMeta.previewFile)
            let prev = try XCTUnwrap(FakeWorkImages.decodeRaw(try Data(contentsOf: oldPreviewURL)))
            let sentinelPreview = FakeWorkImages.raw(Harness.solid(prev.width, prev.height, Self.sentinel))
            h.existence.hide("b")
            _ = try await h.store.dropMissingPhotos(["b"], for: id, reasons: ["b": .hidden])
            // 「被杀」：layout.json 回到旧的，旧预览没来得及删
            try oldLayoutData.write(to: h.workDir(id).appendingPathComponent(FileWorksStore.layoutFileName))
            try sentinelPreview.write(to: oldPreviewURL)
            let stuck = try await h.store.load(id)
            XCTAssertTrue(stuck.isLayoutOutOfSync)
            XCTAssertTrue(try h.anyFileContainsSentinel(id))

            // 重启
            let c = WorksController(store: FileWorksStore(directory: h.dir, images: h.images), existence: h.existence, images: h.images)
            await c.start()
            XCTAssertFalse(try h.anyFileContainsSentinel(id), "重启清理后作品目录里没有哨兵色")
            if unhideBeforeReopen { h.existence.unhide("b") }
            let reads = h.images.state.get().imageReads
            await c.open(id)
            let work = try XCTUnwrap(c.openedWork)
            XCTAssertFalse(work.isLayoutOutOfSync, "按待处理重新写回，指纹对齐")
            XCTAssertEqual(work.meta.fingerprint, WorkFingerprint.of(work.layout))
            XCTAssertEqual(h.images.state.get().imageReads, reads, "不读旧预览 / 旧兜底图")
            XCTAssertFalse(try h.anyFileContainsSentinel(id))
            if !unhideBeforeReopen { XCTAssertEqual(work.layout.cellAssignments[1].localIdentifier, "") }
            c.stop()
        }
    }

    // MARK: Q2 受限访问占位

    /// 受限访问：列表缩略图和查看页都不读、不解码预览文件（解码入口调用 0 次）；回到前台权限变了刷新列表。
    func testLimitedAccessReadsNoPreviewFiles() async throws {
        let h = Harness()
        let id = try await h.save()
        _ = try await h.save(["f", "e", "d", "c", "b", "a"])
        h.existence.fullAccess.set(false)
        await h.controller.start()
        XCTAssertTrue(h.controller.state.limitedAccess)
        var decodes = 0
        for s in h.controller.state.summaries {
            XCTAssertEqual(h.controller.state.previewDisplay(for: s), .limitedAccess)
            let img: Data? = h.controller.state.decodePreview(for: s) { decodes += 1; return try? Data(contentsOf: $0) }
            XCTAssertNil(img)
        }
        h.existence.hide("b")
        let reads = h.images.state.get().imageReads
        await h.controller.open(id)
        let opened = try XCTUnwrap(h.controller.state.opened)
        XCTAssertEqual(h.controller.state.openedPreviewDisplay, .limitedAccess)
        let img: Data? = h.controller.state.decodePreview(for: opened.summary) { decodes += 1; return try? Data(contentsOf: $0) }
        XCTAssertNil(img)
        XCTAssertEqual(decodes, 0, "缩略图 + 查看页读预览文件 0 次")
        XCTAssertEqual(h.images.state.get().imageReads, reads)
        let l1 = try await h.store.load(id).layout
        XCTAssertEqual(l1, sampleLayout(["a", "b", "c", "d", "e", "f"]), "受限访问不改写作品")

        // 导出：填色、不写回
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.exporter.fallbacks.last, [1: RGB8(r: 200, g: 30, b: 30)])
        let l2 = try await h.store.load(id).layout
        XCTAssertEqual(l2, sampleLayout(["a", "b", "c", "d", "e", "f"]))

        // 回到前台：权限没变，不刷新；变成完整权限，刷新列表、查看页重新打开（这时才处理缺图）
        await h.controller.refreshLibraryAccess()
        XCTAssertTrue(h.controller.state.limitedAccess)
        h.existence.fullAccess.set(true)
        await h.controller.refreshLibraryAccess()
        XCTAssertFalse(h.controller.state.limitedAccess)
        for s in h.controller.state.summaries {
            let d: Data? = h.controller.state.decodePreview(for: s) { decodes += 1; return try? Data(contentsOf: $0) }
            XCTAssertNotNil(d)
        }
        XCTAssertEqual(decodes, 2)
        XCTAssertEqual(h.controller.openedWork?.layout.cellAssignments[1].fill, CellColor(r: 200, g: 30, b: 30))
        // 又变回受限：列表重新变占位
        h.existence.fullAccess.set(false)
        await h.controller.refreshLibraryAccess()
        XCTAssertEqual(h.controller.state.openedPreviewDisplay, .limitedAccess)
        h.controller.stop()
    }

    /// 文案 key 在 Localizable.strings 里，值来自 copy v1.7a；works.limited_note 暂不收。
    func testLimitedPlaceholderCopy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("App/Resources/zh-Hans.lproj/Localizable.strings"), encoding: .utf8)
        XCTAssertTrue(text.contains(#""works.limited_placeholder" = "这张作品里有些照片拼忆现在看不到，允许访问全部照片后就能查看";"#))
        XCTAssertTrue(text.contains(#""works.limited_note.settings" = "去设置";"#))
        XCTAssertFalse(text.contains(#""works.limited_note" ="#))
    }
}

/// Q4：取消隐藏 / 恢复的照片在补格时能被重新选中（没有黑名单）。
@MainActor
final class WorksRematchNoBlacklistTests: XCTestCase {
    func testUnhiddenOrRestoredPhotoCanBePickedAgain() async throws {
        for restore in ["unhide", "undelete"] {
            let colors = Array(WorksRematchTests.cellColors.prefix(3))
            let index: [(String, WorksRematchTests.RGB)] = [("b", colors[1])]   // 索引里能补格 1 的只有 b 本身
            let h = WorksRematchTests.Harness(ids: ["a", "b", "c"], cols: 3, colors: colors, index: index)
            let id = try await h.save()
            await h.controller.start()
            if restore == "unhide" { h.existence.hide("b") } else { h.existence.delete("b") }
            await h.controller.open(id)
            XCTAssertEqual(h.controller.openedWork?.layout.cellAssignments[1].localIdentifier, "", "\(restore)：先填色")
            XCTAssertNotNil(h.controller.openedWork?.layout.cellAssignments[1].fill)
            h.controller.close()
            if restore == "unhide" { h.existence.unhide("b") } else { h.existence.deleted.update { $0.remove("b") } }
            h.controller.libraryDidChange()
            await h.controller.open(id)
            XCTAssertEqual(h.controller.openedWork?.layout.cellAssignments[1].localIdentifier, "b", "\(restore)：b 重新被选中")
            XCTAssertNil(h.controller.openedWork?.layout.cellAssignments[1].fill)
            h.controller.stop()
        }
    }
}
