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
        let namesBefore = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let oldName = try XCTUnwrap(namesBefore.first { !$0.hasPrefix(".") })
        let oldBytes = try snapshot(dir.appendingPathComponent(oldName))
        let made = try await store.save(WorkDraft(layout: black, target: nil, overlayAlpha: black.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(made.outcome, .inserted)
        XCTAssertNotEqual(made.summary.id.directoryName, oldName, "不同 fc 新存一份，不沿用旧 ID")
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(oldName)), oldBytes, "旧库字节不变")
        XCTAssertEqual(images.state.get().previews, 2)
        XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"))
        let stable = try snapshot(dir)
        let again = try await store.save(WorkDraft(layout: black, target: nil, overlayAlpha: black.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.summary.id, made.summary.id)
        XCTAssertEqual(try snapshot(dir), stable, "同内容第二次公开保存不写盘")
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
        let pendingBytes = try snapshot(dir.appendingPathComponent(saved.summary.id.directoryName))
        let unrelated = filled(["q", "", "z"], color: CellColor(r: 8, g: 8, b: 8))
        let other = try await store.save(WorkDraft(layout: unrelated, target: nil, overlayAlpha: unrelated.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(other.outcome, .inserted)
        XCTAssertNotEqual(other.summary.id, saved.summary.id)
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(saved.summary.id.directoryName)), pendingBytes, "无关新作不改有 pending 的那一份")
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent(saved.summary.id.directoryName).appendingPathComponent("meta.json"), encoding: .utf8).contains("pendingPreviewFile"))
    }

    func testHighFormatVersionIsSkippedAndNotDeleted() async throws {
        let (dir, _, store) = try await library()
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let metaURL = dir.appendingPathComponent(saved.summary.id.directoryName).appendingPathComponent("meta.json")
        var object = try json(metaURL)
        object["formatVersion"] = 99
        try write(object, metaURL)
        let made = try await store.save(WorkDraft(layout: filled(["q", "", "z"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        XCTAssertEqual(made.outcome, .inserted)
        XCTAssertNotEqual(made.summary.id, saved.summary.id)
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

    func testDeletingTheMatchedDirectoryClearsSavedStatus() async throws {
        let (dir, images, store) = try await library()
        let plain = sampleLayout(["a", "", "c"])
        let saved = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        let matched = filled(["a", "", "c"])
        try plant(matched, id: saved.summary.id, overlay: matched.params.overlayAlpha, in: dir)
        var shown = matched
        let controller = WorksController(store: store, existence: FakeExistence(), images: images,
                                        resultContext: { WorkResultContext(layout: shown, target: nil,
                                                                           overlayAlpha: shown.params.overlayAlpha, tier: nil, resultRevision: 1) })
        await controller.refreshFilledPhotoStatus()
        XCTAssertEqual(controller.state.saveStatus, .saved(saved.summary.id))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(saved.summary.id.directoryName))
        await controller.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(saved.summary.id.directoryName).path), "重扫不能把删掉的作品目录补回来")
        if case .saved = controller.state.saveStatus { XCTFail("目录删了仍报已保存 \(controller.state.saveStatus)") }
        shown = filled(["a", "", "c"], color: CellColor(r: 1, g: 1, b: 1))
        await controller.resultContextDidChange().value
        XCTAssertEqual(controller.state.saveStatus, .idle)
    }

    func testContextChangeDoesNotKeepAStaleSavedID() async throws {
        let (dir, images, store) = try await library()
        let plain = sampleLayout(["a", "", "c"])
        let saved = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        let matched = filled(["a", "", "c"])
        try plant(matched, id: saved.summary.id, overlay: matched.params.overlayAlpha, in: dir)
        let shown = matched
        let controller = WorksController(store: store, existence: FakeExistence(), images: images,
                                        resultContext: { WorkResultContext(layout: shown, target: nil,
                                                                           overlayAlpha: shown.params.overlayAlpha, tier: nil, resultRevision: 1) })
        await controller.refreshFilledPhotoStatus()
        XCTAssertEqual(controller.state.saveStatus, .saved(saved.summary.id))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(saved.summary.id.directoryName))
        let scan = controller.resultContextDidChange()
        if case .saved = controller.state.saveStatus { XCTFail("上下文失效后仍沿用已删作品 \(controller.state.saveStatus)") }
        await scan.value
        XCTAssertEqual(controller.state.saveStatus, .idle)
    }

    func testLateSavedScanCannotRestoreTheSameKeyAfterANewerMiss() async throws {
        let (dir, images, store) = try await library()
        let plain = sampleLayout(["a", "", "c"])
        let saved = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        let matched = filled(["a", "", "c"])
        try plant(matched, id: saved.summary.id, overlay: matched.params.overlayAlpha, in: dir)
        let shown = matched
        let key = OrdinaryPhotoFlightKey.of(shown)
        let controller = WorksController(store: store, existence: FakeExistence(), images: images,
                                        resultContext: { WorkResultContext(layout: shown, target: nil,
                                                                           overlayAlpha: shown.params.overlayAlpha, tier: nil, resultRevision: 1) })
        await controller.refreshFilledPhotoStatus()
        XCTAssertEqual(controller.state.saveStatus, .saved(saved.summary.id))
        let hold = ScanHold()
        controller.filledPhotoHoldAfterRead = {
            controller.filledPhotoHoldAfterRead = nil
            hold.markEntered()
            await hold.waitRelease()
        }
        let older = Task { await controller.refreshFilledPhotoStatus() }
        await hold.waitEntered()
        XCTAssertEqual(OrdinaryPhotoFlightKey.of(shown), key, "布局和缓存键都没有换")
        try FileManager.default.removeItem(at: dir.appendingPathComponent(saved.summary.id.directoryName))
        let newer = Task { await controller.refreshFilledPhotoStatus() }
        await newer.value
        if case .saved = controller.state.saveStatus { XCTFail("新扫描已经看不到目录 \(controller.state.saveStatus)") }
        hold.release()
        await older.value
        if case .saved = controller.state.saveStatus {
            XCTFail("同一缓存键的迟到 .saved 盖回了已删除目录 \(controller.state.saveStatus)")
        }
        XCTAssertEqual(OrdinaryPhotoFlightKey.of(shown), key)
    }

    func testSameFillRevisionChangeDoesNotKeepADeletedWork() async throws {
        let (dir, images, store) = try await library()
        let plain = sampleLayout(["a", "", "c"])
        let saved = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        let matched = filled(["a", "", "c"])
        try plant(matched, id: saved.summary.id, overlay: matched.params.overlayAlpha, in: dir)
        let revision = RevisionBox(1)
        let controller = WorksController(store: store, existence: FakeExistence(), images: images,
                                        resultContext: { WorkResultContext(layout: matched, target: nil,
                                                                           overlayAlpha: matched.params.overlayAlpha, tier: nil, resultRevision: revision.value) })
        await controller.refreshFilledPhotoStatus()
        XCTAssertEqual(controller.state.saveStatus, .saved(saved.summary.id))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(saved.summary.id.directoryName))
        revision.value = 2
        let scan = controller.resultDidChange(revision: revision.value)
        if case .saved = controller.state.saveStatus { XCTFail("只改 revision 仍沿用已删作品 \(controller.state.saveStatus)") }
        await scan.value
        if case .saved = controller.state.saveStatus { XCTFail("revision 重扫结束后仍是已保存 \(controller.state.saveStatus)") }
    }

    func testPreferredEquivalentCandidateWins() async throws {
        let (dir, _, store) = try await library()
        let first = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let second = try await store.save(WorkDraft(layout: sampleLayout(["d", "e", "f"], seed: 8), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let matched = filled(["a", "", "c"])
        try plant(matched, id: first.summary.id, overlay: matched.params.overlayAlpha, in: dir)
        try plant(matched, id: second.summary.id, overlay: matched.params.overlayAlpha, in: dir)
        let before = try snapshot(dir)
        let chosen = try await store.save(WorkDraft(layout: matched, target: nil, overlayAlpha: matched.params.overlayAlpha,
                                                    origin: .savedManually, preferredWorkID: second.summary.id))
        XCTAssertEqual(chosen.outcome, .unchanged)
        XCTAssertEqual(chosen.summary.id, second.summary.id)
        XCTAssertEqual(try snapshot(dir), before, "多份等价里选偏好，不写库")
    }

    func testConcurrentPublishesKeepBothDirectories() async throws {
        let (dir, _, store) = try await library()
        let source = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let before = try snapshot(dir.appendingPathComponent(source.summary.id.directoryName))
        let red = filled(["a", "", "c"], color: CellColor(r: 1, g: 0, b: 0))
        let blue = filled(["a", "", "c"], color: CellColor(r: 0, g: 0, b: 2))
        let redID = WorkID()
        let blueID = WorkID()
        async let left = store.publishNewFilledPhoto(WorkDraft(layout: red, target: nil, overlayAlpha: red.params.overlayAlpha, origin: .savedManually), id: redID)
        async let right = store.publishNewFilledPhoto(WorkDraft(layout: blue, target: nil, overlayAlpha: blue.params.overlayAlpha, origin: .savedManually), id: blueID)
        let (one, two) = try await (left, right)
        XCTAssertEqual(one.summary.id, redID)
        XCTAssertEqual(two.summary.id, blueID)
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(source.summary.id.directoryName)), before)
        let leftLayout = try await store.load(redID).layout.cellAssignments[1].fill
        let rightLayout = try await store.load(blueID).layout.cellAssignments[1].fill
        XCTAssertEqual(leftLayout, CellColor(r: 1, g: 0, b: 0))
        XCTAssertEqual(rightLayout, CellColor(r: 0, g: 0, b: 2))
    }

    func testReceiptFailureAfterRenameDoesNotDuplicateOnSave() async throws {
        let (dir, _, store) = try await library()
        let layout = filled(["a", "", "c"])
        let id = WorkID()
        await store.armFilledPublishInterrupt(.afterRename)
        do {
            _ = try await store.publishNewFilledPhoto(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually), id: id)
            XCTFail("rename 成功后仍把回执交回去了")
        } catch WorksError.publishResultUncertain {}
        let published = dir.appendingPathComponent(id.directoryName)
        let stored = try FileWorksStore.decoder().decode(MosaicLayout.self, from: Data(contentsOf: published.appendingPathComponent("layout.json")))
        XCTAssertEqual(stored.cellAssignments[1].fill, layout.cellAssignments[1].fill, "失败发生在目录已经换上正式名字之后")
        XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"), "已发布目录不能被当成未发布临时目录删掉")
        let before = try snapshot(dir)
        let again = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.summary.id, id)
        XCTAssertEqual(try snapshot(dir), before, "回执丢失后，公开保存只读命中这一份，不另写")
        let found = try await store.readPublishedFilledPhoto(id: id, expecting: layout)
        XCTAssertEqual(found.id, id)
        do {
            _ = try await store.readPublishedFilledPhoto(id: id, expecting: filled(["a", "", "c"], color: CellColor(r: 3, g: 3, b: 3)))
            XCTFail("认不出不能当成原结果")
        } catch WorksError.publishResultUncertain {}
        XCTAssertEqual(try snapshot(dir), before, "认不出只报不确定，不删已发布目录")
    }

    func testPublishInterruptBeforeRenameLeavesTheOldLibrary() async throws {
        for point in [FilledPublishInterrupt.afterLayout, .afterPreview, .afterMeta] {
            let (dir, _, store) = try await library()
            let source = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
            let before = try snapshot(dir)
            await store.armFilledPublishInterrupt(point)
            let layout = filled(["a", "", "c"])
            do {
                _ = try await store.publishNewFilledPhoto(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually))
                XCTFail("\(point) 仍把事务发布了")
            } catch {}
            XCTAssertEqual(try snapshot(dir), before, "\(point) 之后旧库字节和目录不变")
            XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(source.summary.id.directoryName).path))
        }
    }

    func testQueueKeyIsNotTheButtonKeyAndTracksFillFallbackAndOverlay() {
        let layout = filled(["a", "", "c"])
        let button = OrdinaryPhotoContent.flightKey(layout)
        let queue = OrdinaryPhotoContent.queueKey(layout, overlay: layout.params.overlayAlpha)
        XCTAssertNotEqual(button, queue, "按钮缓存键和队列键不是同一串")
        XCTAssertNotEqual(queue, WorkFingerprint.of(layout), "队列键不是 s2-")
        var marked = layout
        marked.cellAssignments[1].fallback = true
        XCTAssertNotEqual(queue, OrdinaryPhotoContent.queueKey(marked, overlay: layout.params.overlayAlpha))
        let other = filled(["a", "", "c"], color: CellColor(r: 9, g: 9, b: 9))
        XCTAssertNotEqual(queue, OrdinaryPhotoContent.queueKey(other, overlay: other.params.overlayAlpha))
        XCTAssertNotEqual(queue, OrdinaryPhotoContent.queueKey(layout, overlay: layout.params.overlayAlpha + 0.05))
    }

    func testPublicConcurrentDifferentFillsPublishTwoWorks() async throws {
        let (dir, _, store) = try await library()
        let plain = sampleLayout(["a", "b", "c"])
        let saved = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        let oldBytes = try snapshot(dir.appendingPathComponent(saved.summary.id.directoryName))
        let red = filled(["a", "", "c"], color: CellColor(r: 1, g: 0, b: 0))
        let blue = filled(["a", "", "c"], color: CellColor(r: 0, g: 0, b: 2))
        async let left = store.save(WorkDraft(layout: red, target: nil, overlayAlpha: red.params.overlayAlpha, origin: .savedManually))
        async let right = store.save(WorkDraft(layout: blue, target: nil, overlayAlpha: blue.params.overlayAlpha, origin: .savedManually))
        let (one, two) = try await (left, right)
        XCTAssertEqual(one.outcome, .inserted)
        XCTAssertEqual(two.outcome, .inserted)
        XCTAssertNotEqual(one.summary.id, two.summary.id)
        XCTAssertNotEqual(one.summary.id, saved.summary.id)
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(saved.summary.id.directoryName)), oldBytes, "公开并发新建不改旧库")
        let redLayout = try FileWorksStore.decoder().decode(MosaicLayout.self, from: Data(contentsOf: dir.appendingPathComponent(one.summary.id.directoryName).appendingPathComponent("layout.json")))
        let blueLayout = try FileWorksStore.decoder().decode(MosaicLayout.self, from: Data(contentsOf: dir.appendingPathComponent(two.summary.id.directoryName).appendingPathComponent("layout.json")))
        XCTAssertEqual(redLayout.cellAssignments[1].fill, CellColor(r: 1, g: 0, b: 0))
        XCTAssertEqual(blueLayout.cellAssignments[1].fill, CellColor(r: 0, g: 0, b: 2))
        XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"))
    }

    func testForcedQueueCollisionDoesNotHandOverTheOtherResult() async throws {
        let (dir, _, store) = try await library()
        await store.armForcedFilledQueueKey("forced-same-key")
        let red = filled(["a", "", "c"], color: CellColor(r: 1, g: 0, b: 0))
        let blue = filled(["a", "", "c"], color: CellColor(r: 0, g: 0, b: 2))
        let first = try await store.save(WorkDraft(layout: red, target: nil, overlayAlpha: red.params.overlayAlpha, origin: .savedManually))
        let second = try await store.save(WorkDraft(layout: blue, target: nil, overlayAlpha: blue.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(first.outcome, .inserted)
        XCTAssertEqual(second.outcome, .inserted)
        XCTAssertNotEqual(first.summary.id, second.summary.id, "同一个粗队列键、内容不同，不能领走对方的新 ID")
        let again = try await store.save(WorkDraft(layout: red, target: nil, overlayAlpha: red.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.summary.id, first.summary.id, "完整比较仍认回自己的那一份，不是蓝的")
        XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"))
    }

    func testMeaningfulOverlayIsNotDeduped() async throws {
        let (dir, _, store) = try await library()
        let layout = filled(["a", "", "c"])
        let first = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let afterFirst = try snapshot(dir)
        let near = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0.15 + 1e-8, origin: .savedManually))
        XCTAssertEqual(near.outcome, .unchanged)
        XCTAssertEqual(near.summary.id, first.summary.id, "小于 sameOverlay 的 1e-6 仍是同一强度")
        XCTAssertEqual(try snapshot(dir), afterFirst, "产品强度语义内的差别不写盘")
        let moved = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0.15 + 2e-6, origin: .savedManually))
        XCTAssertEqual(moved.outcome, .inserted)
        XCTAssertNotEqual(moved.summary.id, first.summary.id, "量化键只筛选；超过 sameOverlay 的强度差要另存")
    }

    func testFallbackBooleanStaysRejected() async throws {
        let (dir, _, store) = try await library()
        var layout = filled(["a", "", "c"])
        layout.cellAssignments[1].fill = nil
        layout.cellAssignments[1].fallback = true
        let before = try snapshot(dir)
        do {
            _ = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually))
            XCTFail("fb 布尔不是已验证的兜底文件，不能公开新建")
        } catch WorksError.unsupportedFilledCells {}
        XCTAssertEqual(try snapshot(dir), before)
        XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"))
    }

    func testPublicRetryAfterLostReceiptReadsThePublishedID() async throws {
        let (dir, _, store) = try await library()
        let plain = sampleLayout(["a", "b", "c"])
        let saved = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        let oldBytes = try snapshot(dir.appendingPathComponent(saved.summary.id.directoryName))
        let layout = filled(["a", "", "c"])
        await store.armFilledPublishInterrupt(.afterRename)
        do {
            _ = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually))
            XCTFail("rename 之后仍把回执交回去了")
        } catch WorksError.publishResultUncertain {}
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") && $0 != saved.summary.id.directoryName }
        XCTAssertEqual(names.count, 1, "回执丢了，但正式目录已经在")
        let published = try XCTUnwrap(WorkID(directoryName: names[0]))
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(saved.summary.id.directoryName)), oldBytes)
        let fresh = FileWorksStore(directory: dir, images: FakeWorkImages(), now: FakeWallClock().provider)
        let stored = try FileWorksStore.decoder().decode(MosaicLayout.self, from: Data(contentsOf: dir.appendingPathComponent(published.directoryName).appendingPathComponent("layout.json")))
        let found = try await fresh.readPublishedFilledPhoto(id: published, expecting: stored)
        XCTAssertEqual(found.id, published, "新 store 只读认回，不走 load / open")
        let stable = try snapshot(dir)
        let retry = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: layout.params.overlayAlpha, origin: .savedManually))
        XCTAssertEqual(retry.outcome, .unchanged)
        XCTAssertEqual(retry.summary.id, published)
        XCTAssertEqual(try snapshot(dir), stable, "重试只读命中，不再写一份")
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(saved.summary.id.directoryName)), oldBytes)
    }

    func testFallbackChangeDropsTheSavedButton() async throws {
        let (dir, images, store) = try await library()
        let plain = sampleLayout(["a", "", "c"])
        let saved = try await store.save(WorkDraft(layout: plain, target: nil, overlayAlpha: plain.params.overlayAlpha, origin: .savedManually))
        let matched = filled(["a", "", "c"])
        try plant(matched, id: saved.summary.id, overlay: matched.params.overlayAlpha, in: dir)
        var shown = matched
        let controller = WorksController(store: store, existence: FakeExistence(), images: images,
                                        resultContext: { WorkResultContext(layout: shown, target: nil,
                                                                           overlayAlpha: shown.params.overlayAlpha, tier: nil, resultRevision: 1) })
        await controller.refreshFilledPhotoStatus()
        XCTAssertEqual(controller.state.saveStatus, .saved(saved.summary.id))
        shown.cellAssignments[1].fallback = true
        await controller.resultContextDidChange().value
        if case .saved = controller.state.saveStatus { XCTFail("只改 fb 仍沿用没有 fb 的已保存 \(controller.state.saveStatus)") }
    }

    func testRegisteredFallbackMigrationReportsBothSidesWithoutReading() async throws {
        let (dir, images, store) = try await library()
        let saved = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0, origin: .savedManually))
        let work = dir.appendingPathComponent(saved.summary.id.directoryName)
        let fallback = work.appendingPathComponent("fallback-kept.jpg")
        try Data("fb".utf8).write(to: fallback)
        let metaURL = work.appendingPathComponent("meta.json")
        var object = try json(metaURL)
        object["fallbackFile"] = "fallback-kept.jpg"
        try write(object, metaURL)
        let box = EvidenceBox()
        await store.armMigrationEvidence { point in
            switch point {
            case .beforeCommit(_, let fallbackURL):
                box.beforeExists = fallbackURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            case .afterCommit(_, let fallbackURL):
                box.afterExists = fallbackURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
            }
        }
        let controller = WorksController(store: store, existence: FakeExistence(), images: images)
        await controller.open(saved.summary.id)
        XCTAssertEqual(box.beforeExists, true, "提交前已登记兜底还在")
        XCTAssertEqual(box.afterExists, false, "提交后文件管理删掉了它。删文件不是读取记录")
        XCTAssertNil(controller.openedWork?.meta.fallbackFile)
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

/// 让先发起的纯读停在写缓存之前。进入和放行都由测试显式触发，不靠睡眠。
private final class EvidenceBox: @unchecked Sendable {
    var beforeExists = false
    var afterExists = true
}

private final class ResultBox: @unchecked Sendable {
    var value = 0
}

private final class RevisionBox: @unchecked Sendable {
    var value: Int
    init(_ value: Int) { self.value = value }
}

private final class ScanHold: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var enterWait: CheckedContinuation<Void, Never>?
    private var releaseWait: CheckedContinuation<Void, Never>?

    func markEntered() {
        lock.lock()
        entered = true
        let waiter = enterWait
        enterWait = nil
        lock.unlock()
        waiter?.resume()
    }

    func waitEntered() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered {
                lock.unlock()
                cont.resume()
            } else {
                enterWait = cont
                lock.unlock()
            }
        }
    }

    func waitRelease() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            releaseWait = cont
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let waiter = releaseWait
        releaseWait = nil
        lock.unlock()
        waiter?.resume()
    }
}
