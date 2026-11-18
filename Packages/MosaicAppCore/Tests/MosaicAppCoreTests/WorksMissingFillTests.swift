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
}
