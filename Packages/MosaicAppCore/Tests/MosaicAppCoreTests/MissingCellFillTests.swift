import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 缺图格子的兜底分两种（需求 4.8 第 5e 条，架构师 11-17 意见二）：原照片被隐藏（或拿不准）→ 填目标图这一格的平均色；
/// 确认删除 → 旧预览裁切（4b）。原因只靠只读元数据分（`availability` / `PhotoFetch.classifyMissing`），不请求任何图像。
@MainActor
final class MissingCellFillTests: XCTestCase {
    typealias RGB8 = FakeWorkImages.RGB8

    // MARK: 纯函数

    func testDecideTable() {
        for reason in [MissingReason.hidden, .deleted, .unknown, nil] {
            XCTAssertEqual(MissingCellFill.decide(reason: reason, hasCandidate: true), .candidate, "有候选一律用候选")
        }
        XCTAssertEqual(MissingCellFill.decide(reason: .deleted, hasCandidate: false), .previewCrop)
        XCTAssertEqual(MissingCellFill.decide(reason: .hidden, hasCandidate: false), .targetColor)
        XCTAssertEqual(MissingCellFill.decide(reason: .unknown, hasCandidate: false), .targetColor, "拿不准按隐藏")
        XCTAssertEqual(MissingCellFill.decide(reason: nil, hasCandidate: false), .targetColor, "没有原因按隐藏")
    }

    func testClassifier() {
        let full = MissingPhotoClassifier.classify(["h", "d", "v", ""], found: ["h": true, "v": false], access: .full)
        XCTAssertEqual(full, ["h": .hidden, "d": .deleted, "v": .unknown], "查到但不是隐藏（竞态）→ 拿不准；空 ID 忽略")
        let limited = MissingPhotoClassifier.classify(["h", "d"], found: ["h": true], access: .limited)
        XCTAssertEqual(limited, ["h": .hidden, "d": .unknown], "受限访问查不到不能算删除")
        let none = MissingPhotoClassifier.classify(["d"], found: [:], access: .none)
        XCTAssertEqual(none, ["d": .unknown], "没有权限：拿不准")
    }

    /// 分类只做一次元数据查询（全部 ID 一起），不请求任何图像：查询闭包只拿到 ID、只返回 isHidden，
    /// 同时用计数缩略图假实现确认整个缺图处理过程取图 0 次。
    func testClassifyMissingIsOneMetadataLookupAndNoImages() async throws {
        var lookups: [[String]] = []
        let r = MissingPhotoClassifier.classify(["b", "a", ""], access: .full) { ids in lookups.append(ids); return ["a": true] }
        XCTAssertEqual(lookups, [["a", "b"]], "一次查询，空 ID 不查")
        XCTAssertEqual(r, ["a": .hidden, "b": .deleted])
        var none = 0
        _ = MissingPhotoClassifier.classify([""], access: .full) { _ in none += 1; return [:] }
        XCTAssertEqual(none, 0, "没有要查的 ID 不查")

        let h = Harness()
        let id = try await h.save(["a", "b", "c", "d", "e", "f"])
        let work = try await h.store.load(id)
        h.existence.hide("b"); h.existence.delete("c")
        let before = h.images.state.get().imageReads
        let availability = await h.existence.availability(among: work.layout.uniqueAssetIDs)
        XCTAssertEqual(availability.missing, ["b": .hidden, "c": .deleted])
        XCTAssertEqual(availability.present, ["a", "d", "e", "f"])
        XCTAssertEqual(h.existence.metadataCalls.get(), 1)
        XCTAssertEqual(h.images.state.get().imageReads, before, "分类不取任何图")
        XCTAssertEqual(h.existence.imageRequests.get(), 0)
    }

    func testTargetColorIsCellAverage() throws {
        let layout = sampleLayout(["a", "b", "c", "d", "e", "f"])
        let t = WorksRematchTests.target(cols: 3, rows: 2, colors: WorksRematchTests.cellColors)
        for i in 0..<6 {
            let c = WorksRematchTests.cellColors[i]
            XCTAssertEqual(MissingCellFill.targetColor(cell: i, layout: layout, target: t), CellColor(r: c.0, g: c.1, b: c.2))
        }
        XCTAssertEqual(MissingCellFill.targetColor(cell: 0, layout: layout, target: nil), MissingCellFill.neutral, "没有目标图副本：中性灰")
        // 缩小过的副本按比例换算
        let small = WorksRematchTests.target(cols: 3, rows: 2, colors: WorksRematchTests.cellColors, width: 150, height: 100)
        XCTAssertEqual(MissingCellFill.targetColor(cell: 4, layout: layout, target: small), CellColor(r: 30, g: 200, b: 200))
    }

    func testFillRoundTripsAndOldLayoutsUnchanged() throws {
        var l = sampleLayout(["a", "", "c"])
        let plain = String(decoding: try FileWorksStore.encoder().encode(l), as: UTF8.self)
        XCTAssertFalse(plain.contains("\"fc\""), "没有纯色格时 JSON 不变")
        XCTAssertEqual(WorkFingerprint.of(l), WorkFingerprint.of(try FileWorksStore.decoder().decode(MosaicLayout.self, from: Data(plain.utf8))))
        l.cellAssignments[1].fill = CellColor(r: 1, g: 2, b: 3)
        let data = try FileWorksStore.encoder().encode(l)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"fc\":[1,2,3]"))
        XCTAssertEqual(try FileWorksStore.decoder().decode(MosaicLayout.self, from: data), l)
        XCTAssertEqual(MissingCellFill.colorTiles(l).mapValues(FakeWorkImages.average), [1: RGB8(r: 1, g: 2, b: 3)])
    }

    // MARK: 端到端（WorksController + FileWorksStore）

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
        func save(_ ids: [String], alpha: Double = 0.2) async throws -> WorkID {
            let t = await WorksRematchTests.target(cols: 3, rows: 2, colors: WorksRematchTests.cellColors)
            return try await store.save(WorkDraft(layout: sampleLayout(ids), target: t, overlayAlpha: alpha, tier: "uhd",
                                                  seed: 7, origin: .autoSavedOnExport)).summary.id
        }
        func previewPixels(_ id: WorkID) async throws -> PixelBuffer {
            let url = try await store.load(id).summary.previewURL
            return try XCTUnwrap(FakeWorkImages.decodeRaw(try Data(contentsOf: url)))
        }
    }

    /// 隐藏且无候选：填目标图这一格的平均色；输出里不含旧预览（隐藏照片）的像素——旧预览压根没被读；不进兜底图。
    func testHiddenWithoutCandidateFillsTargetColorAndNoOldPreviewPixels() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c", "d", "e", "f"])
        await h.controller.start()
        h.existence.hide("b")
        let readsBefore = h.images.state.get().imageReads
        await h.controller.open(id)

        let red = CellColor(r: 200, g: 30, b: 30)   // 目标图格 1
        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(work.layout, sampleColorLayout(["a", "", "c", "d", "e", "f"], color: red))
        XCTAssertEqual(h.images.state.get().imageReads, readsBefore, "隐藏格不读旧预览（不可能带出隐藏照片的像素）")
        XCTAssertEqual(h.images.state.get().fallbackWrites, 0, "不写进 WorkFallbackImages")
        XCTAssertNil(work.meta.fallbackFile)
        XCTAssertEqual(h.images.state.get().lastFallbacks, [1: RGB8(r: 200, g: 30, b: 30)])

        // 新预览格 1 的像素 = 目标色（再叠加目标图，同一换算），与 b 的颜色无关
        let pixels = try await h.previewPixels(id)
        let t = WorksRematchTests.target(cols: 3, rows: 2, colors: WorksRematchTests.cellColors)
        let expected = FakeWorkImages.render(work.layout, target: t, overlayAlpha: 0.2, fallbacks: [1: RGB8(r: 200, g: 30, b: 30)])
        XCTAssertEqual(FakeWorkImages.raw(pixels), FakeWorkImages.raw(expected))
        let leaked = FakeWorkImages.render(work.layout, target: t, overlayAlpha: 0.2, fallbacks: [1: FakeWorkImages.color(of: "b")])
        XCTAssertNotEqual(FakeWorkImages.raw(pixels), FakeWorkImages.raw(leaked))
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]), "按格计入 works.missing")
        h.controller.stop()
    }

    /// 删除且无候选：照旧用旧预览裁切（4b），进兜底图。
    func testDeletedWithoutCandidateUsesOldPreviewCrop() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c", "d", "e", "f"])
        await h.controller.start()
        h.existence.delete("b")
        await h.controller.open(id)
        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(work.layout, sampleFallbackLayout(["a", "", "c", "d", "e", "f"]))
        XCTAssertNil(work.layout.cellAssignments[1].fill)
        XCTAssertEqual(h.images.state.get().fallbackWrites, 1)
        XCTAssertNotNil(work.meta.fallbackFile)
        XCTAssertTrue(WorksFallbackTests.close(h.images.state.get().lastFallbacks[1], FakeWorkImages.color(of: "b")),
                      "旧预览里 b 的颜色（叠加已去掉）")
        h.controller.stop()
    }

    /// 同一作品里一张隐藏、一张删除：各走各的；导出（含重开后）与预览颜色一致。
    func testMixedAndExportMatchesPreview() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c", "d", "e", "f"])
        await h.controller.start()
        h.existence.hide("b")
        h.existence.delete("e")
        await h.controller.open(id)
        let work = try XCTUnwrap(h.controller.openedWork)
        XCTAssertEqual(work.layout.cellAssignments[1].fill, CellColor(r: 200, g: 30, b: 30))
        XCTAssertFalse(work.layout.cellAssignments[1].fallback)
        XCTAssertTrue(work.layout.cellAssignments[4].fallback)
        XCTAssertNil(work.layout.cellAssignments[4].fill)
        let preview = h.images.state.get().lastFallbacks
        XCTAssertEqual(Set(preview.keys), [1, 4])

        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.exporter.fallbacks.last, preview, "导出和预览同一颜色")
        h.controller.stop()

        // 重开（新 store）：导出仍是同一颜色
        let fresh = FileWorksStore(directory: h.dir, images: h.images)
        let tiles = await fresh.fallbackTiles(for: id, transientCells: []).mapValues(FakeWorkImages.average)
        XCTAssertEqual(tiles, preview)
    }

    /// 纯色格之后找到相近照片：升级成照片，纯色去掉。
    func testColorCellUpgradedLater() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c"])
        let w1 = try await h.store.dropMissingPhotos(["b"], for: id, reasons: ["b": .hidden])
        XCTAssertNotNil(w1.layout.cellAssignments[1].fill)
        var next = w1.layout
        next.cellAssignments[1] = .init(localIdentifier: "x")
        let w2 = try await h.store.applyRematch(WorkRematchResult(layout: next, replacedCells: 1, blankCells: 0, droppedPhotos: 0),
                                                base: w1.layout, for: id)
        XCTAssertEqual(w2.layout, sampleLayout(["a", "x", "c"]))
        XCTAssertNil(w2.layout.cellAssignments[1].fill)
    }

    /// 受限访问（没处理、只临时补）：导出时拿不准原因 → 按隐藏填目标色，不读当前预览。
    func testLimitedAccessExportFillsTargetColor() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c", "d", "e", "f"])
        await h.controller.start()
        h.existence.fullAccess.set(false)
        h.existence.hide("b")
        h.existence.delete("e")
        await h.controller.open(id)
        let readsBefore = h.images.state.get().imageReads
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.exporter.calls.last?.0, sampleLayout(["a", "b", "c", "d", "e", "f"]), "受限访问不改写作品")
        XCTAssertEqual(h.exporter.fallbacks.last, [1: RGB8(r: 200, g: 30, b: 30), 4: RGB8(r: 30, g: 200, b: 200)])
        XCTAssertEqual(h.images.state.get().imageReads, readsBefore, "没有读当前预览")
        h.controller.stop()
    }

    /// 分类只调只读元数据接口，一次缺图处理只调一次；不经过任何取图的接口（假图片的读取计数不变）。
    func testClassificationIsMetadataOnly() async throws {
        let h = Harness()
        let id = try await h.save(["a", "b", "c", "d", "e", "f"])
        await h.controller.start()
        h.existence.hide("b", "c")
        let before = h.images.state.get()
        await h.controller.open(id)
        XCTAssertEqual(h.existence.metadataCalls.get(), 1)
        let after = h.images.state.get()
        XCTAssertEqual(after.imageReads, before.imageReads, "原图 / 旧预览请求 0 次")
        h.controller.stop()
    }
}
