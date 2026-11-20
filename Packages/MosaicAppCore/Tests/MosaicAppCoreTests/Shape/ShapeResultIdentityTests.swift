import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 形状结果的保存资格跟结果本身走。换目标、换素材、退回目标页可以把导航上的形状标记清掉，但不能让这张结果变成可保存，也不能让过期的保存回调写进去。
/// 照片拼图的原有未保存提示保持。同指纹改成形状或 fc 时，仍在写预览之前拒绝。
@MainActor
final class ShapeResultIdentityTests: XCTestCase {
    private func shapeResult() async throws -> (CoordinatorHarness, FakeResultSaver) {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let saver = FakeResultSaver()
        saver.coordinator = c
        c.resultSaver = saver
        c.start()
        await c.settle()
        c.beginShape()
        c.setDensity(.coarse)
        c.flowSend(.next)
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else {
            XCTFail("形状没有结果 \(c.state.flow.generation.phase)")
            return (h, saver)
        }
        XCTAssertNotNil(c.product?.shapeFrame)
        XCTAssertNil(c.target, "用形状拼不经过选目标图")
        XCTAssertTrue(c.canExport, "没有用户目标图时形状结果也要能导出")
        XCTAssertTrue(c.allowsWorkSave)
        return (h, saver)
    }

    func testQuickAgainSwitchTargetThenBackDoesNotOfferOrEnterSave() async throws {
        let (h, s) = try await shapeResult()
        let c = h.coordinator
        let seed = c.product?.generation.seed
        s.savedRevision = c.state.resultRevision
        c.startNewMosaicTapped()
        XCTAssertNil(c.state.unsavedPrompt, "已存的形状再拼不弹保存")
        XCTAssertEqual(s.saveCalls, 0)
        XCTAssertTrue(c.state.flow.isQuickAgain)
        c.setTarget(try CoordinatorHarness.target())
        XCTAssertNil(c.state.flow.shape, "选目标图会清掉 shape 标记")
        XCTAssertNotNil(c.product?.shapeFrame, "旧的形状结果还在")
        XCTAssertFalse(c.allowsWorkSave)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertEqual(c.product?.generation.seed, seed)
        XCTAssertNotNil(c.state.flow.shape, "回到形状结果要恢复选择")
        XCTAssertTrue(c.allowsWorkSave)
        s.savedRevision = c.state.resultRevision
        c.startNewMosaicTapped()
        XCTAssertNil(c.state.unsavedPrompt, "已存的形状再拼不弹保存")
        XCTAssertEqual(s.saveCalls, 0)
        _ = c.unsavedPromptSaveTapped()
        await Task.yield()
        XCTAssertEqual(s.saveCalls, 0, "旧确认保存入口不得进入 saveCurrentResult")
        c.leaveResultTapped()
        XCTAssertNil(c.state.unsavedPrompt, "已存的形状返回首页不弹保存")
        XCTAssertEqual(s.saveCalls, 0)
        c.stop()
    }

    func testQuickAgainChangeSourceThenBackDoesNotOfferSave() async throws {
        let (h, s) = try await shapeResult()
        let c = h.coordinator
        s.savedRevision = c.state.resultRevision
        c.startNewMosaicTapped()
        c.setTarget(try CoordinatorHarness.target())
        XCTAssertEqual(c.state.flow.step, .settings)
        c.flowSend(.changeSource)
        XCTAssertEqual(c.state.flow.step, .source)
        c.selectSource(.allPhotos)
        c.flowSend(.back)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertNotNil(c.product?.shapeFrame)
        XCTAssertTrue(c.allowsWorkSave)
        s.savedRevision = c.state.resultRevision
        c.startNewMosaicTapped()
        XCTAssertNil(c.state.unsavedPrompt, "已存的形状再拼不弹保存")
        c.leaveResultTapped()
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(s.saveCalls, 0)
        c.stop()
    }

    func testAdjustBackToTargetDoesNotOfferSave() async throws {
        let (h, s) = try await shapeResult()
        let c = h.coordinator
        let id = WorkID()
        c.send(.backToSettings)
        XCTAssertTrue(c.isAdjustingResult)
        XCTAssertTrue(c.allowsWorkSave)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .source)
        XCTAssertNotNil(c.state.flow.shape)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertNil(c.state.flow.shape)
        XCTAssertNotNil(c.product?.shapeFrame)
        XCTAssertFalse(c.allowsWorkSave, "人已经退回目标页，当前选择和这张形状结果对不上，不提供保存")
        c.startNewFromWorkTapped(workID: id)
        XCTAssertNil(c.state.unsavedPrompt, "再调一调退回目标页后再拼，不能弹 startNewFromAdjust")
        XCTAssertEqual(s.saveCalls, 0)
        _ = c.unsavedPromptSaveTapped()
        await Task.yield()
        XCTAssertEqual(s.saveCalls, 0)
        c.stop()
    }

    func testPhotoLeaveAndAdjustStillPrompt() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let s = FakeResultSaver()
        s.coordinator = c
        c.resultSaver = s
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("照片没有结果") }
        XCTAssertTrue(c.allowsWorkSave)
        XCTAssertNil(c.product?.shapeFrame)
        c.leaveResultTapped()
        XCTAssertEqual(c.state.unsavedPrompt, .leaveResult)
        c.unsavedPromptCancel()
        c.startNewMosaicTapped()
        XCTAssertEqual(c.state.unsavedPrompt, .startNew)
        XCTAssertEqual(c.state.unsavedPromptTitle, .quickUnsavedTitle)
        c.unsavedPromptCancel()
        c.send(.backToSettings)
        c.startNewFromWorkTapped(workID: WorkID())
        XCTAssertEqual(c.state.unsavedPrompt, .startNewFromAdjust)
        XCTAssertEqual(s.saveCalls, 0, "只弹提示，还没点保存")
        c.stop()
    }

    func testSameFingerprintShapeAndFillRejectBeforeWrite() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images)
        let photo = sampleLayout(["a", "b", "c"])
        let saved = try await store.save(WorkDraft(layout: photo, target: nil, overlayAlpha: 0.1, origin: .savedManually))
        let before = images.state.get()
        let preview = try Data(contentsOf: saved.summary.previewURL)
        var shaped = photo
        shaped.shapeFrame = ShapeFrame(background: .black,
                                       mask: try CellMask(columns: photo.cols, rows: photo.rows, allActive: false))
        XCTAssertEqual(WorkFingerprint.of(shaped), WorkFingerprint.of(photo))
        do {
            _ = try await store.save(WorkDraft(layout: shaped, target: nil, overlayAlpha: 0.3,
                                               origin: .savedManually, preferredWorkID: saved.summary.id))
            XCTFail("形状应在更新前拒绝")
        } catch let error as WorksError {
            XCTAssertEqual(error, .unsupportedShapeSave)
        }
        var filled = photo
        filled.cellAssignments[1].fill = CellColor(r: 1, g: 2, b: 3)
        let made = try await store.save(WorkDraft(layout: filled, target: nil, overlayAlpha: 0.3,
                                                  origin: .savedManually, preferredWorkID: saved.summary.id))
        XCTAssertEqual(made.outcome, .inserted)
        XCTAssertNotEqual(made.summary.id, saved.summary.id, "preferred 不是点名更新；不同 fc 新存，不改旧作")
        let after = images.state.get()
        XCTAssertEqual(after.previews, before.previews + 1)
        XCTAssertEqual(after.targets, before.targets)
        XCTAssertEqual(after.fallbackWrites, before.fallbackWrites)
        let again = try await store.load(saved.summary.id)
        XCTAssertEqual(again.meta.overlayAlpha, 0.1, accuracy: 1e-9)
        XCTAssertEqual(again.layout.formatVersion, 1)
        XCTAssertNil(again.layout.shapeFrame)
        XCTAssertNil(again.layout.cellAssignments[1].fill)
        XCTAssertEqual(try Data(contentsOf: saved.summary.previewURL), preview)
    }
}
