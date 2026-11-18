import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 架构师保存契约里，Linux 上能够真实跑完的部分。带 fc 的新预览提交被生产守护挡住，不能把跳过写成通过。
@MainActor
final class WorksContentContractTests: XCTestCase {
    func testDigestIgnoresOverlayAndDoesNotTreatMissingFillAsBlack() {
        let plain = sampleLayout(["a", "b"])
        var stronger = plain
        stronger.params.overlayAlpha = 0.3
        XCTAssertEqual(WorkContentDigest.of(plain), WorkContentDigest.of(stronger), "强度不在摘要里")
        XCTAssertEqual(WorkFingerprint.of(plain), WorkFingerprint.of(stronger))
        var black = plain
        black.cellAssignments[0].fill = CellColor(r: 0, g: 0, b: 0)
        XCTAssertNotEqual(WorkContentDigest.of(plain), WorkContentDigest.of(black), "没有 fc 不是黑色 fc")
        XCTAssertEqual(WorkFingerprint.of(plain), WorkFingerprint.of(black), "#17 指纹仍不含 fc")
        XCTAssertTrue(WorkContentDigest.of(plain).hasPrefix("cd1-"))
    }

    func testSameContentOverlayChangeWritesDigestWithoutNewIdentity() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
        let layout = sampleLayout(["a", "b", "c"])
        let saved = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0.1, origin: .savedManually))
        XCTAssertEqual(saved.summary.meta.contentDigest, WorkContentDigest.of(layout))
        XCTAssertEqual(saved.summary.meta.revision, 1)
        let updated = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0.2, origin: .savedManually))
        XCTAssertEqual(updated.outcome, .updatedOverlay)
        XCTAssertEqual(updated.summary.id, saved.summary.id)
        let loaded = try await store.load(saved.summary.id)
        XCTAssertEqual(loaded.meta.overlayAlpha, 0.2)
        XCTAssertEqual(loaded.meta.contentDigest, WorkContentDigest.of(layout))
        XCTAssertEqual(loaded.meta.revision, 2)
        XCTAssertEqual(loaded.meta.fingerprint, WorkFingerprint.of(layout))
        let listed = await store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(images.state.get().imageReads, 0)
    }

    func testOldWorkWithoutDigestLoadsAndIsNotRewrittenUntilCommit() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let metaURL = dir.appendingPathComponent(saved.summary.id.directoryName).appendingPathComponent("meta.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        obj.removeValue(forKey: "contentDigest")
        obj.removeValue(forKey: "revision")
        obj["fallbackFile"] = "fallback.png"
        try JSONSerialization.data(withJSONObject: obj).write(to: metaURL)
        let loaded = try await store.load(saved.summary.id)
        XCTAssertNil(loaded.meta.contentDigest)
        XCTAssertNil(loaded.meta.revision)
        XCTAssertTrue(loaded.meta.needsFallbackMigration, "缺摘要不取消隐私迁移")
        XCTAssertFalse(loaded.isLayoutOutOfSync)
        let raw = try String(contentsOf: metaURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("contentDigest"), "只打开不补写摘要，也不重画")
        XCTAssertEqual(images.state.get().previews, 1, "加载旧作品不重画预览")
    }

    func testStaleExplicitUpdateDoesNotOverwriteRematch() async throws {
        let dir = makeTempDir()
        let store = FileWorksStore(directory: dir, images: FakeWorkImages(), now: FakeWallClock().provider)
        let id = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: try smallTarget(),
                                                overlayAlpha: 0.2, origin: .savedManually)).summary.id
        let seen = try await store.load(id)
        var cleared = seen.layout
        cleared.cellAssignments[1] = .init(localIdentifier: "")
        let rematched = try await store.applyRematch(
            WorkRematchResult(layout: cleared, replacedCells: 0, blankCells: 1, droppedPhotos: 4, note: "留白"),
            base: seen.layout, for: id, reasons: ["b": .hidden])
        var draftLayout = rematched.layout
        draftLayout.cellAssignments[1].fill = CellColor(r: 4, g: 5, b: 6)
        do {
            _ = try await store.save(WorkDraft(layout: draftLayout, target: nil, overlayAlpha: 0.2, origin: .savedManually,
                                              updateWorkID: id, baselineRevision: seen.meta.revision ?? 0))
            XCTFail("过期草稿不能成功")
        } catch let e as WorksError {
            XCTAssertEqual(e, .staleWorkRevision)
        }
        let loaded = try await store.load(id)
        XCTAssertEqual(loaded.layout.cellAssignments[1].fill, rematched.layout.cellAssignments[1].fill)
        XCTAssertNotEqual(loaded.layout.cellAssignments[1].fill, CellColor(r: 4, g: 5, b: 6))
    }

    func testDeleteDuringOverlayDoesNotResurrect() async throws {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.1, origin: .savedManually))
        let gate = GatePoint()
        images.gate.set(gate)
        let updating = Task {
            try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.2, origin: .savedManually))
        }
        await gate.reached.wait()
        try await store.delete(saved.summary.id)
        images.gate.set(nil)
        await gate.release.open()
        do {
            _ = try await updating.value
            XCTFail("删掉之后不能写回")
        } catch let e as WorksStoreError {
            XCTAssertEqual(e, .notFound)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testRematchMetricUsesPendingCellsAndDropsUnsafeNote() async throws {
        XCTAssertEqual(WorksRematchMetric.safeNote("补格 1 · 留白 2", replaced: 1, blank: 2), "补格 1 · 留白 2")
        XCTAssertEqual(WorksRematchMetric.safeNote("see /tmp/album E4B2A1C0-1111-2222-3333-444444444444", replaced: 1, blank: 2),
                       "补格 1 · 留白 2")
        XCTAssertFalse(WorksRematchMetric.safeNote("NSError domain", replaced: 0, blank: 0).lowercased().contains("error"))

        let dir = makeTempDir()
        let images = FakeWorkImages()
        let existence = FakeExistence()
        let store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
        let ticks = Locked(0.0)
        let perf = PerfRecorder(clock: MonotonicClock { ticks.update { $0 += 0.5; return $0 } })
        let rematcher = ScriptedRematcher()
        let controller = WorksController(store: store, existence: existence, images: images, rematcher: rematcher, perf: perf)
        let id = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0,
                                                origin: .savedManually)).summary.id
        await controller.start()
        existence.hide("b")
        rematcher.next = .value(WorkRematchResult(layout: sampleLayout(["a", "", "c"]), replacedCells: 1, blankCells: 2,
                                                 droppedPhotos: 9, note: "path /Users/hidden"))
        await controller.open(id)
        let sample = try XCTUnwrap(perf.latestSample(of: .worksRematch))
        XCTAssertEqual(sample.phase.rawValue, "works_rematch")
        XCTAssertEqual(sample.items, 3, "items 是本次替换格 + 留白格，不是不同照片数 9")
        XCTAssertEqual(sample.note, "补格 1 · 留白 2")
        XCTAssertGreaterThanOrEqual(sample.seconds, 0)
        perf.reset()
        rematcher.next = .cancel
        existence.hide("a")
        await controller.open(id)
        XCTAssertNil(perf.latestSample(of: .worksRematch), "取消不记成功的 0")
        rematcher.next = .fail
        await controller.open(id)
        XCTAssertNil(perf.latestSample(of: .worksRematch), "错误不记成功的 0")
        controller.stop()
    }

    func testZeroRematchWorkMayRecordZero() async throws {
        let dir = makeTempDir()
        let existence = FakeExistence()
        let store = FileWorksStore(directory: dir, images: FakeWorkImages(), now: FakeWallClock().provider)
        let perf = PerfRecorder(clock: MonotonicClock { 1 })
        let rematcher = ScriptedRematcher()
        rematcher.next = .value(WorkRematchResult(layout: sampleLayout(["a", "b", "c"]), replacedCells: 0, blankCells: 0,
                                                 droppedPhotos: 0, note: "补格 0 · 留白 0"))
        let controller = WorksController(store: store, existence: existence, images: FakeWorkImages(), rematcher: rematcher, perf: perf)
        let id = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0,
                                                origin: .savedManually)).summary.id
        await controller.start()
        existence.hide("b")
        await controller.open(id)
        let sample = try XCTUnwrap(perf.latestSample(of: .worksRematch))
        XCTAssertEqual(sample.items, 0)
        XCTAssertEqual(sample.seconds, 0)
        controller.stop()
    }

    /// 守护还在：这些验收不能跑成「新颜色已写入预览/导出」。跳过不是通过。
    func testFcPreviewAcceptanceBlockedByGuard() throws {
        throw XCTSkip("unsupportedFilledCells 仍拒绝带 fc 的 save 预览。同网格只改 fc、fc+强度、applyRematch 后新鲜草稿改色，都不能在预览/导出里看到新 fc。Apple ImageIOWorkImages.writePreview 与 LiveMosaicExporter 也还没有真实类型检查和像素验证；Linux fake/parse 不能代替。")
    }
}

private final class ScriptedRematcher: MissingCellRematching, @unchecked Sendable {
    enum Step { case value(WorkRematchResult), cancel, fail }
    var next: Step = .fail
    func rematch(_ layout: MosaicLayout, missing: Set<String>, target: PixelBuffer?) async throws -> WorkRematchResult {
        switch next {
        case .value(let result): return result
        case .cancel: throw CancellationError()
        case .fail: throw WorkRematchError.indexUnavailable
        }
    }
}
