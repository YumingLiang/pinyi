import XCTest
@testable import MosaicAppCore

/// 形状结果不能存。离开、返回、再拼、取消都不能弹出带保存的 `quick.unsaved`，也不能把保存错误吞掉。
@MainActor
final class ShapeLeaveTests: XCTestCase {
    private func shapeResult(background: ShapeBackground = .white) async throws -> (CoordinatorHarness, FakeResultSaver) {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let saver = FakeResultSaver()
        saver.coordinator = c
        c.resultSaver = saver
        c.start()
        await c.settle()
        c.beginShape()
        if background != .white { c.setShapeBackground(background) }
        XCTAssertEqual(c.state.flow.step, .source)
        XCTAssertFalse(c.allowsWorkSave)
        c.flowSend(.next)
        XCTAssertEqual(c.state.flow.step, .settings)
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else {
            XCTFail("形状没有生成到结果页：\(c.state.flow.generation.phase)")
            return (h, saver)
        }
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertNotNil(c.product?.shapeFrame)
        XCTAssertEqual(c.product?.shapeBackground, background)
        XCTAssertFalse(c.allowsWorkSave)
        return (h, saver)
    }

    func testShapeAgainDoesNotOfferSaveAndBackKeepsResult() async throws {
        let (h, s) = try await shapeResult()
        let c = h.coordinator
        let product = c.product
        c.startNewMosaicTapped()
        XCTAssertNil(c.state.unsavedPrompt, "再拼一张不弹带保存的提示")
        XCTAssertFalse(c.state.unsavedPromptIsUpdate)
        XCTAssertEqual(s.saveCalls, 0)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertTrue(c.state.flow.isQuickAgain)
        XCTAssertEqual(c.product?.generation.seed, product?.generation.seed)
        c.unsavedPromptSaveTapped()
        c.unsavedPromptDiscard()
        c.unsavedPromptCancel()
        XCTAssertEqual(s.saveCalls, 0, "没有提示时保存 / 不保存 / 取消都不调用保存")
        XCTAssertEqual(c.state.flow.step, .target)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertFalse(c.allowsWorkSave)
        XCTAssertNotNil(c.product?.shapeFrame)
        c.stop()
    }

    func testShapeLeaveReturnsHomeWithoutPrompt() async throws {
        let (h, s) = try await shapeResult(background: .black)
        let c = h.coordinator
        c.leaveResultTapped()
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(s.saveCalls, 0)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertNil(c.product)
        XCTAssertNil(c.state.flow.shape)
        XCTAssertFalse(c.state.hasResult)
        c.stop()
    }

    func testShapeWorkEntryAndAdjustSkipSavePrompt() async throws {
        let (h, s) = try await shapeResult()
        let c = h.coordinator
        let id = WorkID()
        c.startNewFromWorkTapped(workID: id)
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(s.saveCalls, 0)
        XCTAssertTrue(c.state.flow.isQuickAgain)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)

        c.send(.backToSettings)
        XCTAssertTrue(c.isAdjustingResult)
        XCTAssertNil(c.state.unsavedPrompt, "再调一调本身不弹保存")
        c.startNewFromWorkTapped(workID: id)
        XCTAssertNil(c.state.unsavedPrompt, "再调一调途中再拼一张也不弹保存")
        XCTAssertEqual(s.saveCalls, 0)
        XCTAssertTrue(c.state.flow.isFreshQuickStart)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertNotNil(c.product, "还没开始生成，原形状结果还在")
        c.stop()
    }

    func testGeneratedShapeLayoutStillRejectsSaveBeforeWrite() async throws {
        let (h, _) = try await shapeResult()
        let c = h.coordinator
        let product = try XCTUnwrap(c.product)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shape-leave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images)
        let layout = MosaicLayout(product: product, overlayAlpha: 0.25)
        do {
            _ = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0, origin: .savedManually))
            XCTFail("生成出来的形状结果仍应在写盘前拒绝")
        } catch let error as WorksError {
            XCTAssertEqual(error, .unsupportedShapeSave)
        }
        XCTAssertEqual(images.state.get().previews, 0)
        XCTAssertEqual(images.state.get().imageReads, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        c.stop()
    }

    func testPhotoResultStillPromptsToSave() async throws {
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
        guard case .result = c.state.flow.generation.phase else { return XCTFail("照片拼图没有结果") }
        XCTAssertTrue(c.allowsWorkSave)
        XCTAssertNil(c.product?.shapeFrame)
        c.startNewMosaicTapped()
        XCTAssertEqual(c.state.unsavedPrompt, .startNew)
        XCTAssertEqual(c.state.unsavedPromptTitle, .quickUnsavedTitle)
        c.unsavedPromptCancel()
        XCTAssertEqual(c.state.flow.step, .result)
        c.stop()
    }
}
