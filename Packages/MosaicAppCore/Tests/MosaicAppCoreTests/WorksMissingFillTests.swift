import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// works-missing-fill：渲染 / 导出直接读 fc，提示按格，补格走串行入口，并记 `works_rematch`。
@MainActor
final class WorksMissingFillTests: XCTestCase {
    /// 有 fc 时忽略调用方传来的裁切小图（哨兵色），预览头写成 fc# 而不是 fb#。
    func testRendererReadsFillInsteadOfFallbackCrop() {
        var layout = sampleLayout(["a", ""])
        layout.cellAssignments[1].fill = CellColor(r: 9, g: 8, b: 7)
        XCTAssertEqual(layout.renderSource(at: 0), .photo(id: "a", crop: MosaicLayout.CellAssignment.fullSquare))
        XCTAssertEqual(layout.renderSource(at: 1), .fill(CellColor(r: 9, g: 8, b: 7)))
        XCTAssertEqual(layout.renderSource(at: 9), .blank)
        let sentinel = FakeWorkImages.RGB8(r: 3, g: 251, b: 7)
        let buf = FakeWorkImages.render(layout, target: nil, overlayAlpha: 0, fallbacks: [1: sentinel])
        let p = buf.rgb(x: FakeWorkImages.cellPixels, y: 0)
        XCTAssertEqual(p.r, 9)
        XCTAssertEqual(p.g, 8)
        XCTAssertEqual(p.b, 7)
        let header = String(decoding: FakeWorkImages.previewBytes(layout, fallbacks: [1: sentinel]), as: UTF8.self)
        XCTAssertTrue(header.contains("fc#090807"))
        XCTAssertFalse(header.contains("fb#"))
        XCTAssertFalse(header.contains("03fb07"))
    }

    /// App 侧预览渲染器和导出器都调用 `renderSource`；清晰层提供 `invalidate()`。Linux 不能编译 Apple SDK，只核对源码。
    func testAppRendererExporterAndDetailLayerMentionFill() throws {
        let pkg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repo = pkg.deletingLastPathComponent().deletingLastPathComponent()
        let preview = try String(contentsOf: repo.appendingPathComponent("App/Works/WorksAdapters.swift"), encoding: .utf8)
        let export = try String(contentsOf: repo.appendingPathComponent("App/Export/LiveMosaicExporter.swift"), encoding: .utf8)
        let detail = try String(contentsOf: repo.appendingPathComponent("App/Rendering/PreviewDetailLayer.swift"), encoding: .utf8)
        XCTAssertTrue(preview.contains("renderSource(at:"))
        XCTAssertTrue(export.contains("renderSource(at:"))
        XCTAssertTrue(detail.contains("func invalidate()"))
        XCTAssertTrue(detail.contains("DetailCacheKey"))
        XCTAssertFalse(preview.contains("previewCrop"))
        XCTAssertFalse(export.contains("previewCrop"))
    }

    /// 缺失数写入必须等这一作品的补格写回结束（同一个串行入口）。
    func testMissingCountWaitsForSerialRematch() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil,
                                                   overlayAlpha: 0, origin: .savedManually))
        let id = saved.summary.id
        let work = try await store.load(id)
        var cleared = work.layout
        cleared.cellAssignments[1] = .init(localIdentifier: "")
        let gate = GatePoint()
        images.gate.set(gate)
        let apply = Task {
            try await store.applyRematch(
                WorkRematchResult(layout: cleared, replacedCells: 0, blankCells: 1, droppedPhotos: 1, note: "留白"),
                base: work.layout, for: id, reasons: ["b": .deleted])
        }
        await gate.reached.wait()
        let set = Task { try await store.setMissingCount(7, for: id) }
        try await Task.sleep(for: .milliseconds(150))
        let mid = try await store.load(id)
        XCTAssertNotEqual(mid.meta.missingCount, 7, "补格还停在写预览时，缺失数不能先写完")
        await gate.release.open()
        _ = try await apply.value
        _ = try await set.value
        let end = try await store.load(id)
        XCTAssertEqual(end.meta.missingCount, 7)
        XCTAssertNotNil(end.layout.cellAssignments[1].fill, "留白格写回时填上 fc")
    }

    /// `works_rematch` 记在现有 PerfSample 上：相位名、附注沿用补格结果，items = 替换格 + 留白格。
    func testRematchRecordsWorksRematchSample() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let existence = FakeExistence()
        let store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
        let ticks = Locked(0.0)
        let perf = PerfRecorder(clock: MonotonicClock { ticks.update { $0 += 0.2; return $0 } })
        let note = "补格 0 · 留白 1"
        let rematcher = CountingRematcher { layout, missing in
            var out = layout
            for i in out.cellAssignments.indices where missing.contains(out.cellAssignments[i].localIdentifier) {
                out.cellAssignments[i] = .init(localIdentifier: "")
            }
            return WorkRematchResult(layout: out, replacedCells: 0, blankCells: 1, droppedPhotos: 1, note: note)
        }
        let controller = WorksController(store: store, existence: existence, images: images, rematcher: rematcher, perf: perf)
        let id = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil,
                                                overlayAlpha: 0, origin: .savedManually)).summary.id
        await controller.start()
        existence.hide("b")
        await controller.open(id)
        let sample = try XCTUnwrap(perf.latestSample(of: .worksRematch))
        XCTAssertEqual(sample.phase.rawValue, "works_rematch")
        XCTAssertEqual(sample.note, note)
        XCTAssertEqual(sample.items, 1)
        XCTAssertGreaterThanOrEqual(sample.seconds, 0)
        XCTAssertEqual(controller.openedWork?.layout.cellAssignments[1].fill != nil, true)
        controller.stop()
    }

    /// 提示按格计数，到点只收起一次；取消或已经不是这一页就不再收。
    func testCellNoticePresenterCountsCellsAndFiresOnce() async throws {
        let presenter = CellNoticePresenter(duration: .milliseconds(40))
        let fires = Locked(0)
        presenter.present(missingCells: 0, replacedCells: 0, stillCurrent: { true }, fire: { fires.update { $0 += 1 } })
        presenter.present(missingCells: 3, replacedCells: 1, stillCurrent: { true }, fire: { fires.update { $0 += 1 } })
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(fires.get(), 1)
        presenter.present(missingCells: 2, replacedCells: 0, stillCurrent: { false }, fire: { fires.update { $0 += 1 } })
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fires.get(), 1, "已经不是这一页就不收起")
        presenter.present(missingCells: 2, replacedCells: 0, stillCurrent: { true }, fire: { fires.update { $0 += 1 } })
        presenter.cancel()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fires.get(), 1, "取消后不再收起")
    }

    /// 复现：同一网格只改 fc。旧指纹会把第二次 save 收成 unchanged 并留下第一次的颜色。
    /// 契约之后，没有显式 WorkID 时不得再这样覆盖；守护未撤时带 fc 的新草稿被拒绝，第一张保持原色。
    func testSameGridDifferentFillKeepsStoredColor() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
        let existence = FakeExistence()
        let exporter = RecordingWorkExporter()
        let controller = WorksController(store: store, existence: existence, images: images)
        controller.exportHandler = exporter

        let plain = sampleLayout(["a", "", "c"])
        var colored = plain
        colored.cellAssignments[1].fill = CellColor(r: 1, g: 2, b: 9)
        XCTAssertEqual(WorkFingerprint.of(plain), WorkFingerprint.of(colored), "fc 不参与 #17 指纹")
        XCTAssertNotEqual(WorkContentDigest.of(plain), WorkContentDigest.of(colored))

        let saved = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: 0.2, origin: .savedManually))
        XCTAssertEqual(saved.outcome, .inserted)
        do {
            _ = try await store.save(WorkDraft(layout: colored, target: nil, overlayAlpha: 0.2, origin: .savedManually))
            XCTFail("无显式 WorkID 时不能按旧指纹 unchanged，守护未撤时也不能把带 fc 的新草稿写进去")
        } catch let e as WorksError {
            XCTAssertEqual(e, .unsupportedFilledCells)
        }
        let listed = await store.list()
        XCTAssertEqual(listed.count, 1)
        var loaded = try await store.load(saved.summary.id)
        XCTAssertNil(loaded.layout.cellAssignments[1].fill, "第一张没有被草稿的 fc 改掉")
        XCTAssertFalse(String(decoding: try FakeWorkImages.previewHeader(loaded.summary.previewURL), as: UTF8.self).contains("fc#010209"))

        do {
            _ = try await store.save(WorkDraft(layout: colored, target: nil, overlayAlpha: 0.25,
                                              origin: .savedManually, updateWorkID: saved.summary.id,
                                              baselineRevision: loaded.meta.revision ?? 0))
            XCTFail("显式更新改了 fc 时不能只改强度；守护未撤，也不能提交新预览")
        } catch let e as WorksError {
            XCTAssertEqual(e, .unsupportedFilledCells)
        }
        loaded = try await store.load(saved.summary.id)
        XCTAssertEqual(loaded.meta.overlayAlpha, 0.2, "失败时强度也不能被改掉")
        XCTAssertNil(loaded.layout.cellAssignments[1].fill)

        let id = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: try smallTarget(),
                                                overlayAlpha: 0.2, origin: .savedManually)).summary.id
        let base = try await store.load(id)
        var cleared = base.layout
        cleared.cellAssignments[1] = .init(localIdentifier: "")
        let rematched = try await store.applyRematch(
            WorkRematchResult(layout: cleared, replacedCells: 0, blankCells: 1, droppedPhotos: 1, note: "留白"),
            base: base.layout, for: id, reasons: ["b": .deleted])
        let stored = try XCTUnwrap(rematched.layout.cellAssignments[1].fill)
        XCTAssertEqual(stored, CellColor(r: 200, g: 200, b: 200))
        var other = rematched.layout
        other.cellAssignments[1].fill = CellColor(r: 4, g: 5, b: 6)
        XCTAssertEqual(WorkFingerprint.of(other), WorkFingerprint.of(rematched.layout))
        do {
            _ = try await store.save(WorkDraft(layout: other, target: nil, overlayAlpha: 0.2, origin: .savedManually))
            XCTFail("不能按旧指纹把另一份 fc 收成 unchanged")
        } catch let e as WorksError {
            XCTAssertEqual(e, .unsupportedFilledCells)
        }
        loaded = try await store.load(id)
        XCTAssertEqual(loaded.layout.cellAssignments[1].fill, stored)
        let freshRevision = loaded.meta.revision ?? 0
        do {
            _ = try await store.save(WorkDraft(layout: other, target: nil, overlayAlpha: 0.2, origin: .savedManually,
                                              updateWorkID: id, baselineRevision: freshRevision))
            XCTFail("新鲜草稿改 fc：守护未撤，不能把新颜色写进预览")
        } catch let e as WorksError {
            XCTAssertEqual(e, .unsupportedFilledCells)
        }
        do {
            _ = try await store.save(WorkDraft(layout: other, target: nil, overlayAlpha: 0.2, origin: .savedManually,
                                              updateWorkID: id, baselineRevision: freshRevision - 1))
            XCTFail("过期草稿应该冲突")
        } catch let e as WorksError {
            XCTAssertEqual(e, .staleWorkRevision)
        }
        loaded = try await store.load(id)
        XCTAssertEqual(loaded.layout.cellAssignments[1].fill, stored, "冲突和守护都没有改掉 applyRematch 的颜色")

        await controller.start()
        await controller.open(id)
        await controller.exportOpenedTapped(purpose: .save)
        let painted = try XCTUnwrap(exporter.fallbacks.last?[1])
        XCTAssertEqual(painted, FakeWorkImages.RGB8(r: stored.r, g: stored.g, b: stored.b))
        XCTAssertNotEqual(painted, FakeWorkImages.RGB8(r: 4, g: 5, b: 6))
        XCTAssertEqual(images.state.get().imageReads, 0)
        controller.stop()
    }
}
