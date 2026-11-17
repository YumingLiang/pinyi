import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 找不到合格相近照片的格子（hd-export-req-v0.2 F 节；产品 03:55 Q1 取消 4b 之后）：不论原因一律填目标图这一格的平均色
/// （布局里 `fc`），预览重画和高清导出都用同一颜色；不读旧预览、不再写兜底图（`WorkFallbackImages` 只剩旧作品迁移 / 纯函数）。
/// 纯色格以后能升级成照片。
@MainActor
final class WorksFallbackTests: XCTestCase {
    typealias RGB8 = FakeWorkImages.RGB8

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

        /// 「杀掉 App 重开」：新 store / controller，同一个作品目录。
        @MainActor func relaunched() -> (WorksController, RecordingWorkExporter) {
            let c = WorksController(store: FileWorksStore(directory: dir, images: images), existence: existence, images: images)
            let e = RecordingWorkExporter()
            c.exportHandler = e
            return (c, e)
        }

        func save(_ ids: [String], target: PixelBuffer? = nil) async throws -> WorkID {
            try await store.save(WorkDraft(layout: sampleLayout(ids), target: target, overlayAlpha: 0.15, tier: "uhd",
                                           seed: 7, origin: .autoSavedOnExport)).summary.id
        }
        func workDir(_ id: WorkID) -> URL { dir.appendingPathComponent(id.directoryName) }
        func files(_ id: WorkID) throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: workDir(id).path)) }
    }

    /// 300×200 左右渐变的目标图（叠加不是纯色，验证裁兜底时按位置去掉叠加）。
    static func gradientTarget() throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: 300 * 200 * 4)
        for y in 0..<200 { for x in 0..<300 {
            let o = (y * 300 + x) * 4
            bytes[o] = UInt8(x * 255 / 299); bytes[o + 1] = UInt8(y * 255 / 199); bytes[o + 2] = 90
        } }
        return try PixelBuffer(width: 300, height: 200, bytes: bytes)
    }

    static func close(_ a: RGB8?, _ b: RGB8, tolerance: Int = 2) -> Bool {
        guard let a else { return false }
        return abs(Int(a.r) - Int(b.r)) <= tolerance && abs(Int(a.g) - Int(b.g)) <= tolerance && abs(Int(a.b) - Int(b.b)) <= tolerance
    }

    // MARK: 文案

    /// 文案已定（copy_v1.1.md → gen-localizable.py）：两条都按格计，不写「删掉」「隐藏」。
    func testCopyTextAndPerCellPlaceholder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("App/Resources/zh-Hans.lproj/Localizable.strings"), encoding: .utf8)
        func value(_ key: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix("\"\(key)\"") }.map(String.init)
        }
        XCTAssertEqual(value("works.missing"), #""works.missing" = "有 %1$@ 格原来的照片现在用不了，这几格会稍模糊";"#)
        XCTAssertEqual(value("works.replaced"), #""works.replaced" = "有 %1$@ 格原来的照片现在用不了，已换成相近的照片";"#)
        for key in ["works.missing", "works.replaced"] {
            let line = try XCTUnwrap(value(key))
            XCTAssertFalse(line.contains("删"), key)
            XCTAssertFalse(line.contains("隐藏"), key)
        }
        let md = try String(contentsOf: root.appendingPathComponent("App/Resources/copy_v1.1.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("| 有 {count} 格原来的照片现在用不了，这几格会稍模糊 |"))
        XCTAssertTrue(md.contains("| 有 {count} 格原来的照片现在用不了，已换成相近的照片 |"))
        XCTAssertFalse(md.contains("works.replaced` | 查看页 / 导出前：原照片已删除或隐藏"), "占位说明已去掉")
    }

    /// `works.missing` 按格算：同一张照片用在 3 格，提示「3 格」。
    func testMissingCountIsPerCell() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "a", "a", "c", "d"])
        await h.controller.start()
        h.existence.delete("a")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["3"]))
        let meta = try await h.store.load(id).meta
        XCTAssertEqual(meta.fallbackCellCount, 3)
        XCTAssertEqual(meta.droppedPhotoCount, 1, "按张的旧字段照旧（兼容）")
        h.controller.stop()
    }

    // MARK: 兜底图

    /// 目标图这一格的平均色（Q1 后找不到相近照片的格子一律填它）。
    static func fill(_ cell: Int, _ ids: [String], _ target: PixelBuffer?) -> CellColor {
        MissingCellFill.targetColor(cell: cell, layout: sampleLayout(ids), target: target)
    }
    static func rgb(_ c: CellColor) -> RGB8 { RGB8(r: c.r, g: c.g, b: c.b) }

    /// 删除格（产品 03:55 Q1 取消 4b）：不裁旧预览，填目标图这一格的平均色存进布局（`fc`）；不写兜底图；
    /// 重开后从布局读回同一颜色。
    func testDeletedCellsFillTargetColorAndPersisted() async throws {
        let h = Harness()
        let ids = ["a", "b", "c", "d", "e", "f"]
        let target = try Self.gradientTarget()
        let id = try await h.save(ids, target: target)
        await h.controller.start()
        let oldPreview = try XCTUnwrap(h.controller.state.summaries.first?.previewURL)
        h.existence.delete("b", "f")
        let reads = h.images.state.get().imageReads
        await h.controller.open(id)

        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(work.layout.cellAssignments.map(\.localIdentifier), ["a", "", "c", "d", "e", ""])
        XCTAssertEqual(work.layout.cellAssignments.map(\.fallback), [false, false, false, false, false, false])
        XCTAssertEqual(work.layout.cellAssignments[1].fill, Self.fill(1, ids, target))
        XCTAssertEqual(work.layout.cellAssignments[5].fill, Self.fill(5, ids, target))
        XCTAssertNil(work.meta.fallbackFile)
        XCTAssertFalse(try h.files(id).contains { $0.hasPrefix("fallback") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPreview.path), "旧预览已换掉")
        XCTAssertEqual(h.images.state.get().imageReads, reads, "没读旧预览")
        XCTAssertEqual(h.images.state.get().fallbackWrites, 0)
        let used = h.images.state.get().lastFallbacks
        XCTAssertEqual(used, [1: Self.rgb(Self.fill(1, ids, target)), 5: Self.rgb(Self.fill(5, ids, target))])

        let json = String(decoding: try Data(contentsOf: h.workDir(id).appendingPathComponent(FileWorksStore.layoutFileName)), as: UTF8.self)
        XCTAssertEqual(json.components(separatedBy: "\"fc\":").count - 1, 2)
        XCTAssertFalse(json.contains("\"fb\""))
        h.controller.stop()

        let fresh = FileWorksStore(directory: h.dir, images: h.images)
        let reloaded = try await fresh.load(id)
        XCTAssertEqual(reloaded.layout, work.layout)
        let tiles = await fresh.fallbackTiles(for: id, transientCells: [])
        XCTAssertEqual(tiles.mapValues(FakeWorkImages.average), used)
    }

    /// 重导出（含杀掉 App 重开后）用布局里存的颜色填充，不出白格；不重画预览、不再提示。
    func testReexportUsesStoredFillColor() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c"], target: try smallTarget())
        await h.controller.start()
        h.existence.delete("c")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]))
        let previews = h.images.state.get().previews
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]),
                       "同一次查看里马上导出：没有新变化，提示保留到自动消失（QA Q1 门禁）")
        h.controller.dismissCellNotice()
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertNil(h.controller.state.missingLine, "消失后再导出：不再提示")
        XCTAssertEqual(h.exporter.calls.last?.0, sampleColorLayout(["a", "b", ""], color: smallTargetColor))
        XCTAssertEqual(h.exporter.fallbacks.last, [2: Self.rgb(smallTargetColor)])
        h.controller.stop()

        let (c2, e2) = h.relaunched()
        await c2.start()
        await c2.open(id)
        XCTAssertNil(c2.state.missingLine, "重开：不再提示")
        await c2.exportOpenedTapped(purpose: .share)
        XCTAssertEqual(e2.fallbacks.last, h.exporter.fallbacks.last, "重开后导出同一颜色")
        XCTAssertEqual(h.images.state.get().previews, previews, "没有再重画预览")
        XCTAssertEqual(h.images.state.get().fallbackWrites, 0)

        await c2.exportSucceeded(layout: try XCTUnwrap(e2.calls.last?.0))
        let count = await h.store.list().count
        XCTAssertEqual(count, 1, "再导出成功 → 自动保存按指纹查重命中")
        c2.stop()
    }

    /// 纯色格之后一格升级、一格仍空、一格新空：仍空的颜色不变，新空的填目标色，升级的去掉颜色；始终没有兜底图。
    func testFillKeptAndUpgraded() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images)
        let ids = ["a", "b", "c"]
        let target = try Self.gradientTarget()
        let id = try await store.save(WorkDraft(layout: sampleLayout(ids), target: target,
                                                overlayAlpha: 0.2, origin: .savedManually)).summary.id
        let w1 = try await store.dropMissingPhotos(["a", "b"], for: id, reasons: ["a": .deleted, "b": .deleted])
        XCTAssertEqual(w1.layout.cellAssignments.map(\.fill), [Self.fill(0, ids, target), Self.fill(1, ids, target), nil])
        XCTAssertNil(w1.meta.fallbackFile)

        var next = w1.layout
        next.cellAssignments[0] = .init(localIdentifier: "x")
        next.cellAssignments[2] = .init(localIdentifier: "")
        let w2 = try await store.applyRematch(WorkRematchResult(layout: next, replacedCells: 1, blankCells: 2, droppedPhotos: 1),
                                              base: w1.layout, for: id, reasons: ["c": .deleted])
        XCTAssertEqual(w2.layout.cellAssignments.map(\.localIdentifier), ["x", "", ""])
        XCTAssertEqual(w2.layout.cellAssignments.map(\.fill), [nil, Self.fill(1, ids, target), Self.fill(2, ids, target)])
        XCTAssertEqual(w2.layout.cellAssignments.map(\.fallback), [false, false, false])
        XCTAssertNil(w2.meta.fallbackFile)
        XCTAssertEqual(w2.meta.fallbackCellCount, 3, "按格累计：a、b、c")
        XCTAssertEqual(w2.meta.replacedCellCount, 1)

        var all = w2.layout
        all.cellAssignments[1] = .init(localIdentifier: "y")
        all.cellAssignments[2] = .init(localIdentifier: "z")
        let w3 = try await store.applyRematch(WorkRematchResult(layout: all, replacedCells: 2, blankCells: 0, droppedPhotos: 0),
                                              base: w2.layout, for: id)
        XCTAssertEqual(w3.layout, sampleLayout(["x", "y", "z"]))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(id.directoryName).path)
        XCTAssertFalse(names.contains { $0.hasPrefix("fallback") })
        XCTAssertEqual(w3.meta.fallbackCellCount, 3, "累计不回退")
        XCTAssertEqual(images.state.get().fallbackWrites, 0)
    }

    /// 旧预览读不出来也无所谓：补格本来就不读它，删除格照样填目标色、提示一次，导出同一颜色。
    func testUnreadableOldPreviewDoesNotMatter() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c"], target: try smallTarget())
        await h.controller.start()
        let preview = try XCTUnwrap(h.controller.state.summaries.first?.previewURL)
        try Data("not an image".utf8).write(to: preview)
        h.existence.delete("b")
        await h.controller.open(id)
        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(work.layout, sampleColorLayout(["a", "", "c"], color: smallTargetColor))
        XCTAssertNil(work.meta.fallbackFile)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]))
        XCTAssertEqual(work.meta.fallbackCellCount, 1)
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.exporter.fallbacks.last, [1: Self.rgb(smallTargetColor)])
        h.controller.stop()
    }

    /// 重画预览失败：作品原样（布局、meta、文件都不变），不留临时文件，不提示；下次打开再做。
    func testPreviewWriteFailureKeepsWorkIntact() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c"], target: try smallTarget())
        await h.controller.start()
        let filesBefore = try h.files(id)
        let metaBefore = try Data(contentsOf: h.workDir(id).appendingPathComponent(FileWorksStore.metaFileName))
        h.images.state.update { $0.failAt = .preview }
        h.existence.delete("b")
        await h.controller.open(id)
        XCTAssertNil(h.controller.state.missingLine)
        XCTAssertEqual(try h.files(id), filesBefore)
        XCTAssertEqual(try Data(contentsOf: h.workDir(id).appendingPathComponent(FileWorksStore.metaFileName)).count, metaBefore.count, "只记待处理数")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).filter { $0.hasPrefix(".") }, [])
        let onDisk = try await h.store.load(id)
        XCTAssertEqual(onDisk.layout, sampleLayout(["a", "b", "c"]))

        h.images.state.update { $0.failAt = nil }
        h.controller.close()
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleColorLayout(["a", "", "c"], color: smallTargetColor))
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]))
        h.controller.stop()
    }

    // MARK: 纯函数

    /// 裁切去掉叠加：渐变目标图、α = 0.3，按位置反解，误差 ≤ 1。
    func testCropRemovesOverlayByPosition() throws {
        let layout = sampleLayout(["a", "b", "c", "d", "e", "f"])
        let target = try Self.gradientTarget()
        let preview = FakeWorkImages.render(layout, target: target, overlayAlpha: 0.3, fallbacks: [:])
        let tiles = WorkFallbackImages.crop(from: preview, cells: Array(0..<6), layout: layout, target: target, overlayAlpha: 0.3)
        XCTAssertEqual(tiles.count, 6)
        for (i, id) in ["a", "b", "c", "d", "e", "f"].enumerated() {
            let tile = try XCTUnwrap(tiles[i])
            let want = FakeWorkImages.color(of: id)
            for y in 0..<tile.height { for x in 0..<tile.width {
                let p = tile.rgb(x: x, y: y)
                XCTAssertTrue(Self.close(RGB8(r: p.r, g: p.g, b: p.b), want, tolerance: 1), "cell \(i) (\(x),\(y))")
            } }
        }
        // 没有目标图：原样裁
        let plain = FakeWorkImages.render(layout, target: nil, overlayAlpha: 0.3, fallbacks: [:])
        XCTAssertEqual(WorkFallbackImages.crop(from: plain, cells: [4], layout: layout, target: nil, overlayAlpha: 0.3)
            .mapValues(FakeWorkImages.average)[4], FakeWorkImages.color(of: "e"))
    }

    /// 拼图 ↔ 拆回逐位一致；格子区域等分。
    func testAtlasRoundTripAndCellRect() throws {
        let layout = sampleLayout(["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(WorkFallbackImages.cellRect(4, cols: 3, rows: 2, width: 12, height: 8), PixelRegion(x: 4, y: 4, width: 4, height: 4))
        XCTAssertNil(WorkFallbackImages.cellRect(6, cols: 3, rows: 2, width: 12, height: 8))
        let tiles: [Int: PixelBuffer] = [1: try .solid(width: 4, height: 4, red: 10, green: 20, blue: 30),
                                         5: try .solid(width: 4, height: 4, red: 200, green: 100, blue: 50)]
        let atlas = try XCTUnwrap(WorkFallbackImages.atlas(tiles, layout: layout, width: 12, height: 8))
        let back = WorkFallbackImages.split(atlas, cells: [1, 5], layout: layout)
        XCTAssertEqual(back[1]?.bytes, tiles[1]?.bytes)
        XCTAssertEqual(back[5]?.bytes, tiles[5]?.bytes)
        XCTAssertNil(WorkFallbackImages.atlas([:], layout: layout, width: 12, height: 8))
    }

    // MARK: 旧版兼容

    /// 旧版 layout.json（没有 fb）、meta.json（没有 fallbackCellCount / fallbackFile）照常解码；
    /// 普通格子编码不写 fb（旧作品指纹不变）。
    func testLegacyLayoutAndMetaDecode() throws {
        let legacyLayout = #"{"cells":[{"crop":[0,0,1,1],"id":"a"},{"crop":[0,0,1,1],"id":""}],"cols":2,"formatVersion":1,"params":{"density":"coarse","overlayAlpha":0.1,"seed":7},"rows":1,"targetCrop":[0,0,300,200],"targetSize":{"height":200,"width":300}}"#
        let layout = try FileWorksStore.decoder().decode(MosaicLayout.self, from: Data(legacyLayout.utf8))
        XCTAssertEqual(layout.cellAssignments.map(\.fallback), [false, false])
        XCTAssertEqual(String(decoding: try FileWorksStore.encoder().encode(layout), as: UTF8.self), legacyLayout,
                       "重编码逐字节一致：指纹不变")
        var marked = layout
        marked.cellAssignments[1].fallback = true
        let round = try FileWorksStore.decoder().decode(MosaicLayout.self, from: FileWorksStore.encoder().encode(marked))
        XCTAssertEqual(round, marked)

        let id = WorkID()
        let legacyMeta = #"{"formatVersion":1,"id":"\#(id.directoryName)","createdAt":1000,"columns":2,"rows":1,"overlayAlpha":0.1,"droppedPhotoCount":2,"replacedCellCount":1}"#
        let meta = try FileWorksStore.decoder().decode(WorkMeta.self, from: Data(legacyMeta.utf8))
        XCTAssertEqual(meta.fallbackCellCount, 0)
        XCTAssertNil(meta.fallbackFile)
        XCTAssertEqual(meta.droppedPhotoCount, 2)
        XCTAssertEqual(meta.replacedCellCount, 1)
        XCTAssertFalse(String(decoding: try FileWorksStore.encoder().encode(meta), as: UTF8.self).contains("fallbackFile"))
    }

    /// 旧版留白的作品（之前的版本把缺图格清成空串、不带兜底）：打开不出错，没有旧预览可裁的那格保持留白，不提示。
    func testLegacyBlankWorkOpensQuietly() async throws {
        let h = Harness()
        let id = try await h.save(["a", "", "c"])
        await h.controller.start()
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "", "c"]))
        XCTAssertNil(h.controller.state.missingLine)
        XCTAssertNil(h.controller.state.replacedLine)
        XCTAssertEqual(h.images.state.get().previews, 1)
        h.controller.stop()
    }
}
