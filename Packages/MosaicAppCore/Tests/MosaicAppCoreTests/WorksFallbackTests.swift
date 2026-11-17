import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 预览兜底（hd-export-req-v0.2 F 节；`works.missing`「这几格会稍模糊」）：找不到合格相近照片的格子，在重画预览**之前**
/// 从旧预览裁出该格、存进作品目录（布局里 `fb` 标记 + meta.fallbackFile），之后预览重画和高清导出都用它放大填充；
/// 没有旧预览才留白。兜底格以后能升级成照片（兜底图随之删掉）。
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

    /// 兜底图在重画预览之前从旧预览裁出（叠加按位置去掉），存进作品目录；重开后从磁盘读回，内容一致。
    func testFallbackCroppedFromOldPreviewAndPersisted() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c", "d", "e", "f"], target: try Self.gradientTarget())
        await h.controller.start()
        let oldPreview = try XCTUnwrap(h.controller.state.summaries.first?.previewURL)
        h.existence.delete("b", "f")
        await h.controller.open(id)

        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(work.layout, sampleFallbackLayout(["a", "", "c", "d", "e", ""]))
        XCTAssertEqual(work.layout.cellAssignments.map(\.fallback), [false, true, false, false, false, true])
        let file = try XCTUnwrap(work.meta.fallbackFile)
        XCTAssertTrue(file.hasPrefix("fallback-") && file.hasSuffix(".png"))
        XCTAssertTrue(try h.files(id).contains(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPreview.path), "旧预览已换掉")
        // 预览重画时这两格用了兜底图；颜色是原照片的（叠加已按位置去掉，不会叠两次）
        let used = h.images.state.get().lastFallbacks
        XCTAssertEqual(Set(used.keys), [1, 5])
        XCTAssertTrue(Self.close(used[1], FakeWorkImages.color(of: "b")), "\(String(describing: used[1]))")
        XCTAssertTrue(Self.close(used[5], FakeWorkImages.color(of: "f")), "\(String(describing: used[5]))")
        XCTAssertEqual(h.images.state.get().fallbackWrites, 1)

        // layout.json 里只有兜底格带 "fb"
        let json = String(decoding: try Data(contentsOf: h.workDir(id).appendingPathComponent(FileWorksStore.layoutFileName)), as: UTF8.self)
        XCTAssertEqual(json.components(separatedBy: "\"fb\":true").count - 1, 2)
        h.controller.stop()

        // 重开：从磁盘读回的兜底图与写入时一致
        let fresh = FileWorksStore(directory: h.dir, images: h.images)
        let reloaded = try await fresh.load(id)
        XCTAssertEqual(reloaded.layout, work.layout)
        let tiles = await fresh.fallbackTiles(for: id, transientCells: [])
        XCTAssertEqual(tiles.mapValues(FakeWorkImages.average), used)
        XCTAssertEqual(tiles[1].map { [$0.width, $0.height] }, [FakeWorkImages.cellPixels, FakeWorkImages.cellPixels])
    }

    /// 重导出（含杀掉 App 重开后）用存盘的兜底图放大填充，不出白格；不重新裁、不重画预览、不再提示。
    func testReexportUsesStoredFallback() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c"], target: try smallTarget())
        await h.controller.start()
        h.existence.delete("c")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]))
        let previews = h.images.state.get().previews
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertNil(h.controller.state.missingLine, "再导出：不再提示")
        XCTAssertEqual(h.exporter.calls.last?.0, sampleFallbackLayout(["a", "b", ""]))
        XCTAssertTrue(Self.close(h.exporter.fallbacks.last?[2], FakeWorkImages.color(of: "c")))
        XCTAssertEqual(h.exporter.fallbacks.last?.count, 1)
        h.controller.stop()

        let (c2, e2) = h.relaunched()
        await c2.start()
        await c2.open(id)
        XCTAssertNil(c2.state.missingLine, "重开：不再提示")
        await c2.exportOpenedTapped(purpose: .share)
        XCTAssertEqual(e2.fallbacks.last, h.exporter.fallbacks.last, "重开后导出用同一份兜底图")
        XCTAssertEqual(h.images.state.get().previews, previews, "没有再重画预览")
        XCTAssertEqual(h.images.state.get().fallbackWrites, 1, "没有再裁一次")

        // 再导出成功 → 自动保存按指纹查重命中（布局里的 fb 标记也在指纹里，一致）
        await c2.exportSucceeded(layout: try XCTUnwrap(e2.calls.last?.0))
        let count = await h.store.list().count
        XCTAssertEqual(count, 1)
        c2.stop()
    }

    /// 兜底格之后又有一张兜底、一张升级：仍兜底的直接搬旧兜底图（不从新预览二次裁），新兜底的从当前预览裁，
    /// 升级的那格兜底图删掉；旧兜底图文件换掉。
    func testFallbackKeptMovedAndUpgraded() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images)
        let id = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: try Self.gradientTarget(),
                                                overlayAlpha: 0.2, origin: .savedManually)).summary.id
        let w1 = try await store.dropMissingPhotos(["a", "b"], for: id, reasons: ["a": .deleted, "b": .deleted])
        XCTAssertEqual(w1.layout, sampleFallbackLayout(["", "", "c"]))
        let first = try XCTUnwrap(w1.meta.fallbackFile)
        let tiles1 = await store.fallbackTiles(for: id, transientCells: []).mapValues(FakeWorkImages.average)

        // 格 0 升级成照片 x，格 1 仍兜底，格 2（c）这次也找不到替代
        var next = w1.layout
        next.cellAssignments[0] = .init(localIdentifier: "x")
        next.cellAssignments[2] = .init(localIdentifier: "")
        let w2 = try await store.applyRematch(WorkRematchResult(layout: next, replacedCells: 1, blankCells: 2, droppedPhotos: 1),
                                              base: w1.layout, for: id, reasons: ["c": .deleted])
        XCTAssertEqual(w2.layout.cellAssignments.map(\.localIdentifier), ["x", "", ""])
        XCTAssertEqual(w2.layout.cellAssignments.map(\.fallback), [false, true, true])
        let second = try XCTUnwrap(w2.meta.fallbackFile)
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(id.directoryName).appendingPathComponent(first).path),
                       "旧兜底图删掉")
        let tiles2 = await store.fallbackTiles(for: id, transientCells: []).mapValues(FakeWorkImages.average)
        XCTAssertEqual(Set(tiles2.keys), [1, 2], "升级的格 0 没有兜底图了")
        XCTAssertEqual(tiles2[1], tiles1[1], "仍兜底的格子原样搬过来（逐位一致，不二次裁切）")
        XCTAssertTrue(Self.close(tiles2[2], FakeWorkImages.color(of: "c")))
        XCTAssertEqual(w2.meta.fallbackCellCount, 3, "按格累计：a、b、c")
        XCTAssertEqual(w2.meta.replacedCellCount, 1)

        // 全部升级：没有兜底格了，兜底图删掉、meta 不再指向它
        var all = w2.layout
        all.cellAssignments[1] = .init(localIdentifier: "y")
        all.cellAssignments[2] = .init(localIdentifier: "z")
        let w3 = try await store.applyRematch(WorkRematchResult(layout: all, replacedCells: 2, blankCells: 0, droppedPhotos: 0),
                                              base: w2.layout, for: id)
        XCTAssertNil(w3.meta.fallbackFile)
        XCTAssertEqual(w3.layout, sampleLayout(["x", "y", "z"]))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(id.directoryName).path)
        XCTAssertFalse(names.contains { $0.hasPrefix("fallback") })
        XCTAssertEqual(w3.meta.fallbackCellCount, 3, "累计不回退")
    }

    /// 没有旧预览（读不出）时才留白：格子不标兜底、不写兜底图，照样按格计数、提示一次。
    func testNoOldPreviewLeavesBlank() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c"])
        await h.controller.start()
        let preview = try XCTUnwrap(h.controller.state.summaries.first?.previewURL)
        try Data("not an image".utf8).write(to: preview)
        h.existence.delete("b")
        await h.controller.open(id)
        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(work.layout, sampleLayout(["a", "", "c"]))
        XCTAssertFalse(work.layout.cellAssignments[1].fallback)
        XCTAssertNil(work.meta.fallbackFile)
        XCTAssertEqual(h.images.state.get().fallbackWrites, 0)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]))
        XCTAssertEqual(work.meta.fallbackCellCount, 1)
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.exporter.fallbacks.last, [:], "没有兜底图可用，这格导出留白")
        h.controller.stop()
    }

    /// 写兜底图失败：作品原样（布局、meta、预览都不变），不留临时文件、不留孤儿文件，不提示；下次打开再做。
    func testFallbackWriteFailureKeepsWorkIntact() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c"])
        await h.controller.start()
        let filesBefore = try h.files(id)
        let metaBefore = try Data(contentsOf: h.workDir(id).appendingPathComponent(FileWorksStore.metaFileName))
        h.images.state.update { $0.failAt = .fallback }
        h.existence.delete("b")
        await h.controller.open(id)
        XCTAssertNil(h.controller.state.missingLine)
        XCTAssertEqual(try h.files(id), filesBefore)
        XCTAssertEqual(try Data(contentsOf: h.workDir(id).appendingPathComponent(FileWorksStore.metaFileName)).count, metaBefore.count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).filter { $0.hasPrefix(".") }, [])
        let onDisk = try await h.store.load(id)
        XCTAssertEqual(onDisk.layout, sampleLayout(["a", "b", "c"]))

        h.images.state.update { $0.failAt = nil }
        h.controller.close()
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleFallbackLayout(["a", "", "c"]))
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
