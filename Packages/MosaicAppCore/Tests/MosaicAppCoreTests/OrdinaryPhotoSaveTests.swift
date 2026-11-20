import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 合成作品库上的普通照片填色。不是历史发布样本，也不表示 F1–F7 或 Apple 像素已通过。
@MainActor
final class OrdinaryPhotoSaveTests: XCTestCase {
    func testEquivalentFilledPhotoKeepsIDAndDoesNotTouchTheLibrary() async throws {
        let (dir, images, store) = try await library()
        let layout = filled(["a", "", "c"])
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        try plant(layout, id: saved.summary.id, overlay: layout.params.overlayAlpha, in: dir)
        let before = try snapshot(dir)
        let again = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.summary.id, saved.summary.id)
        XCTAssertEqual(try snapshot(dir), before)
        XCTAssertEqual(images.state.get().imageReads, 0)
        XCTAssertEqual(images.state.get().reads, 0)
        XCTAssertEqual(images.state.get().previews, 1, "等价命中不再画预览")
    }

    func testMissingDigestIsComputedFromLayoutAndNotWritten() async throws {
        let (dir, _, store) = try await library()
        let layout = filled(["a", "", "c"])
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        try plant(layout, id: saved.summary.id, overlay: layout.params.overlayAlpha, in: dir)
        let metaURL = dir.appendingPathComponent(saved.summary.id.directoryName).appendingPathComponent("meta.json")
        var object = try json(metaURL)
        object.removeValue(forKey: "contentDigest")
        object.removeValue(forKey: "revision")
        try write(object, metaURL)
        let raw = try String(contentsOf: metaURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("contentDigest"))
        let again = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertFalse(try String(contentsOf: metaURL, encoding: .utf8).contains("contentDigest"), "缺摘要只读计算，不补写")
    }

    func testSameFingerprintDifferentFillIsNotTheSameWork() async throws {
        let (dir, images, store) = try await library()
        let plain = sampleLayout(["a", "", "c"])
        _ = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        let black = filled(["a", "", "c"], color: CellColor(r: 0, g: 0, b: 0))
        let red = filled(["a", "", "c"], color: CellColor(r: 9, g: 0, b: 0))
        XCTAssertEqual(WorkFingerprint.of(plain), WorkFingerprint.of(black))
        XCTAssertNotEqual(WorkContentDigest.of(plain), WorkContentDigest.of(black))
        XCTAssertFalse(OrdinaryPhotoContent.same(plain, black, metaOverlay: plain.params.overlayAlpha))
        XCTAssertNotEqual(OrdinaryPhotoFlightKey.of(black), OrdinaryPhotoFlightKey.of(red))
        let before = try snapshot(dir)
        do {
            _ = try await store.save(WorkDraft(layout: black, target: nil, overlayAlpha: black.params.overlayAlpha, origin: .savedManually))
            XCTFail("不同 fc 不能沿用旧 ID")
        } catch WorksError.unsupportedFilledCells {}
        XCTAssertEqual(try snapshot(dir), before)
        XCTAssertEqual(images.state.get().previews, 1)
        XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"), "守护拒绝时不留下新建事务目录")
    }

    func testFallbackAndOverlayAreNotSwallowedByTheOldFingerprint() {
        let base = filled(["a", "", "c"])
        var fb = base
        fb.cellAssignments[1].fill = nil
        fb.cellAssignments[1].fallback = true
        var stronger = base
        stronger.params.overlayAlpha = 0.3
        XCTAssertEqual(WorkFingerprint.of(base), WorkFingerprint.of(fb))
        XCTAssertFalse(OrdinaryPhotoContent.same(base, fb, metaOverlay: base.params.overlayAlpha))
        XCTAssertFalse(OrdinaryPhotoContent.same(base, stronger, metaOverlay: stronger.params.overlayAlpha))
        XCTAssertNotEqual(OrdinaryPhotoFlightKey.of(base), OrdinaryPhotoFlightKey.of(fb))
        XCTAssertNotEqual(OrdinaryPhotoFlightKey.of(base), OrdinaryPhotoFlightKey.of(stronger))
    }

    func testExplicitExistingIDRejectsInsteadOfSavingANewCopy() async throws {
        let (dir, _, store) = try await library()
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let before = try snapshot(dir)
        do {
            _ = try await store.save(WorkDraft(layout: filled(["a", "", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually,
                                              updateWorkID: saved.summary.id))
            XCTFail("点名旧 ID 不能另存")
        } catch WorksError.unsupportedExistingWorkUpdate {}
        XCTAssertEqual(try snapshot(dir), before)
    }

    func testRelatedPendingBlocksAndUnrelatedPendingDoesNot() async throws {
        let (dir, _, store) = try await library()
        let plain = sampleLayout(["a", "", "c"])
        let saved = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        try markPending(saved.summary.id, in: dir)
        let before = try snapshot(dir)
        do {
            _ = try await store.save(WorkDraft(layout: filled(["a", "", "c"]), target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
            XCTFail("相关 pending 不能另存")
        } catch WorksError.cannotProvePhotoEquivalence {}
        XCTAssertEqual(try snapshot(dir), before)
        let unrelated = filled(["q", "", "z"], color: CellColor(r: 8, g: 8, b: 8))
        do {
            _ = try await store.save(WorkDraft(layout: unrelated, target: nil, overlayAlpha: unrelated.params.overlayAlpha, origin: .savedManually))
            XCTFail("无关作品的 pending 不能变成别的错误，但新建仍被守护挡住")
        } catch WorksError.unsupportedFilledCells {}
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent(saved.summary.id.directoryName).appendingPathComponent("meta.json"), encoding: .utf8).contains("pendingPreviewFile"))
    }

    func testHighFormatVersionIsSkippedAndNotDeleted() async throws {
        let (dir, _, store) = try await library()
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let metaURL = dir.appendingPathComponent(saved.summary.id.directoryName).appendingPathComponent("meta.json")
        var object = try json(metaURL)
        object["formatVersion"] = 99
        try write(object, metaURL)
        do {
            _ = try await store.save(WorkDraft(layout: filled(["q", "", "z"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
            XCTFail("仍被守护拒绝")
        } catch WorksError.unsupportedFilledCells {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path), "高版本只跳过，不清理")
        let raw = try String(contentsOf: metaURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("99"))
    }

    func testDifferentFillsDoNotShareAFlightKey() {
        let red = filled(["a", "", "c"], color: CellColor(r: 1, g: 0, b: 0))
        let blue = filled(["a", "", "c"], color: CellColor(r: 0, g: 0, b: 1))
        XCTAssertEqual(WorkFingerprint.of(red), WorkFingerprint.of(blue))
        XCTAssertNotEqual(OrdinaryPhotoFlightKey.of(red), OrdinaryPhotoFlightKey.of(blue))
    }

    func testShortFillArrayStaysNilAndIsNotAHistoricalSample() throws {
        let layout = sampleLayout(["a", "b", "c"])
        var object = try JSONSerialization.jsonObject(with: FileWorksStore.encoder().encode(layout)) as! [String: Any]
        var cells = object["cells"] as! [[String: Any]]
        cells[0]["fc"] = [1, 2]
        object["cells"] = cells
        let decoded = try FileWorksStore.decoder().decode(MosaicLayout.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.cellAssignments[0].fill, "长度不是 3 仍静默为 nil。这是合成 schema，不是历史发布样本，也不是 F5 整项通过")
    }

    func testNewTransactionPublishesANewIDAndLeavesTheSourceBytes() async throws {
        let (dir, images, store) = try await library()
        let source = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let sourceBytes = try snapshot(dir.appendingPathComponent(source.summary.id.directoryName))
        let layout = filled(["a", "", "c"])
        let made = try await store.publishNewFilledPhoto(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(made.outcome, .inserted)
        XCTAssertNotEqual(made.summary.id, source.summary.id)
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(source.summary.id.directoryName)), sourceBytes)
        let loaded = try await store.load(made.summary.id)
        XCTAssertEqual(loaded.layout.cellAssignments[1].fill, CellColor(r: 4, g: 5, b: 6))
        XCTAssertFalse(try String(contentsOf: dir.appendingPathComponent(made.summary.id.directoryName).appendingPathComponent("meta.json"), encoding: .utf8).contains("contentDigest"))
        XCTAssertEqual(images.state.get().imageReads, 0)
        let found = try await store.readPublishedFilledPhoto(id: made.summary.id, expecting: layout)
        XCTAssertEqual(found.id, made.summary.id)
        do {
            _ = try await store.readPublishedFilledPhoto(id: made.summary.id, expecting: filled(["a", "", "c"], color: CellColor(r: 9, g: 9, b: 9)))
            XCTFail("内容对不上仍返回了原结果")
        } catch WorksError.publishResultUncertain {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(made.summary.id.directoryName).path), "认不出时不删已发布目录")
    }

    func testEncodeFailureAndCollisionDoNotPublish() async throws {
        let (dir, images, store) = try await library()
        let source = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        images.state.update { $0.failAt = .preview }
        let layout = filled(["a", "", "c"])
        do {
            _ = try await store.publishNewFilledPhoto(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually))
            XCTFail("编码失败仍发布了")
        } catch {}
        XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"))
        images.state.update { $0.failAt = nil }
        let occupied = WorkID()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(occupied.directoryName), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: dir.appendingPathComponent(occupied.directoryName).appendingPathComponent("marker"))
        do {
            _ = try await store.publishNewFilledPhoto(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually), id: occupied)
            XCTFail("已有目录被盖掉了")
        } catch WorksError.publishCollision {}
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(occupied.directoryName).appendingPathComponent("marker"), encoding: .utf8), "keep")
        XCTAssertEqual(source.summary.id, source.summary.id)
    }

    func testStaleSourceAbortsBeforePublish() async throws {
        let (dir, _, store) = try await library()
        let source = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let layoutURL = dir.appendingPathComponent(source.summary.id.directoryName).appendingPathComponent("layout.json")
        let original = try Data(contentsOf: layoutURL)
        try Data("changed".utf8).write(to: layoutURL)
        do {
            _ = try await store.publishNewFilledPhoto(
                WorkDraft(layout: filled(["a", "", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually),
                sourceLayoutAtStart: original, sourceID: source.summary.id)
            XCTFail("来源变了仍发布")
        } catch WorksError.cannotProvePhotoEquivalence {}
        XCTAssertEqual(try Data(contentsOf: layoutURL), Data("changed".utf8), "发布前复核失败不改来源")
        XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"))
    }

    func testButtonDoesNotTreatADifferentFillAsSaved() async throws {
        let (_, images, store) = try await library()
        let plain = sampleLayout(["a", "", "c"])
        _ = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        let shown = filled(["a", "", "c"])
        let controller = WorksController(store: store, existence: FakeExistence(), images: images,
                                        resultContext: { WorkResultContext(layout: shown, target: nil,
                                                                           overlayAlpha: plain.params.overlayAlpha, tier: nil, resultRevision: 1) })
        await controller.refreshFilledPhotoStatus()
        XCTAssertEqual(controller.state.saveStatus, .idle)
    }

    private func library() async throws -> (URL, FakeWorkImages, FileWorksStore) {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        return (dir, images, FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider))
    }

    private func filled(_ ids: [String], color: CellColor = CellColor(r: 4, g: 5, b: 6)) -> MosaicLayout {
        sampleColorLayout(ids, color: color)
    }

    private func plant(_ layout: MosaicLayout, id: WorkID, overlay: Double, in dir: URL) throws {
        let work = dir.appendingPathComponent(id.directoryName, isDirectory: true)
        try FileWorksStore.encoder().encode(layout).write(to: work.appendingPathComponent("layout.json"), options: .atomic)
        let metaURL = work.appendingPathComponent("meta.json")
        var object = try json(metaURL)
        object["overlayAlpha"] = overlay
        object["fingerprint"] = WorkFingerprint.of(layout)
        try write(object, metaURL)
    }

    private func markPending(_ id: WorkID, in dir: URL) throws {
        let metaURL = dir.appendingPathComponent(id.directoryName).appendingPathComponent("meta.json")
        var object = try json(metaURL)
        object["pendingPreviewFile"] = ".preview-pending-test.jpg"
        try write(object, metaURL)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func write(_ object: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    private func snapshot(_ dir: URL) throws -> String {
        let fm = FileManager.default
        guard let names = fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] else { return "" }
        return try names.sorted { $0.path < $1.path }.map { url -> String in
            var isDir: ObjCBool = false
            let rel = url.path.replacingOccurrences(of: dir.path, with: "")
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return "dir \(rel)" }
            let data = try Data(contentsOf: url)
            return "file \(rel) \(data.base64EncodedString())"
        }.joined(separator: "\n")
    }
}

enum OrdinaryPhotoFlightKey {
    static func of(_ layout: MosaicLayout) -> String { OrdinaryPhotoContent.flightKey(layout) }
}
