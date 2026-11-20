import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 入口选定类型之后，这次会话保持到结束。
/// `3bd9732` 上 `testSelectedPhotoRejectsShapeEntry` 为红：选中照片后 `beginShape` 仍写成默认爱心并离开目标页。
/// 协调器测试，不是可见点击，也不是键盘。
@MainActor
final class EntryModeTests: XCTestCase {
    func testSelectedPhotoRejectsShapeEntry() async throws {
        let h = CoordinatorHarness(assets: 40)
        let c = h.coordinator
        c.start()
        await c.settle()
        XCTAssertTrue(c.state.flow.offersShapeEntry)
        c.setTarget(try CoordinatorHarness.target())
        XCTAssertFalse(c.state.flow.offersShapeEntry, "照片选上之后目标页不再提供图形入口")
        c.beginShape()
        XCTAssertNil(c.state.flow.shape, "照片已选上之后不能再写入图形")
        XCTAssertEqual(c.state.flow.step, .target)
        c.stop()
    }

    func testPhotoSessionReachesConfirmWithoutShapeAndGeneratesThatPhoto() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        c.start()
        await c.settle()
        let photo = try CoordinatorHarness.target()
        c.setTarget(photo)
        c.beginShape()
        c.flowSend(.next)
        XCTAssertEqual(c.state.flow.step, .source)
        XCTAssertNil(c.state.flow.shape)
        c.flowSend(.next)
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertNil(c.state.flow.shape, "照片确认页没有形状、预设、文字、配色或背景")
        XCTAssertNotNil(c.target)
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else {
            return XCTFail("照片没有生成 \(c.state.flow.generation.phase)")
        }
        XCTAssertNil(c.product?.shapeFrame, "生成目标不是爱心或其他图形")
        let seen = try XCTUnwrap(h.generator.seenTargets.get().last)
        XCTAssertFalse(seen.shapeMask)
        XCTAssertEqual(seen.width, photo.width)
        XCTAssertEqual(seen.height, photo.height)
        XCTAssertEqual(seen.leading, Array(photo.bytes.prefix(12)))
        c.stop()
    }

    func testShapeEntryNeedsNoTargetPhoto() async throws {
        let h = CoordinatorHarness(assets: 40)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.beginShape()
        XCTAssertNil(c.target)
        XCTAssertEqual(c.state.flow.step, .source)
        XCTAssertEqual(c.state.flow.shape, ShapeChoice())
        XCTAssertFalse(c.state.flow.offersShapeEntry)
        c.flowSend(.next)
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertEqual(c.state.flow.shape?.preset, .heart)
        XCTAssertEqual(c.state.flow.shape?.palette, .auto)
        XCTAssertEqual(c.state.flow.shape?.background, .white)
        XCTAssertNil(c.target, "图形确认不要求目标照片")
        c.stop()
    }

    func testShapeMaterialBackThenPhotoLeavesNoShape() async throws {
        let h = CoordinatorHarness(assets: 40)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.beginShape()
        c.setShapePreset(.star)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertNil(c.state.flow.shape)
        XCTAssertTrue(c.state.flow.offersShapeEntry, "回到首页要重新选类型")
        c.setTarget(try CoordinatorHarness.target())
        XCTAssertNil(c.state.flow.shape)
        XCTAssertFalse(c.state.flow.offersShapeEntry)
        c.beginShape()
        c.flowSend(.next)
        c.flowSend(.next)
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertNil(c.state.flow.shape)
        c.stop()
    }

    func testPhotoAgainHidesShapeEntryAndConfirmStaysPhoto() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let saver = FakeResultSaver()
        saver.coordinator = c
        c.resultSaver = saver
        c.start()
        await c.settle()
        c.setTarget(try CoordinatorHarness.target())
        c.flowSend(.next)
        c.flowSend(.next)
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("没有照片结果") }
        saver.savedRevision = c.state.resultRevision
        c.startNewMosaicTapped()
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertTrue(c.state.flow.isQuickAgain)
        XCTAssertFalse(c.state.flow.offersShapeEntry)
        c.beginShape()
        XCTAssertNil(c.state.flow.shape)
        XCTAssertEqual(c.state.flow.step, .target)
        c.setTarget(try CoordinatorHarness.target())
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertNil(c.state.flow.shape, "照片再拼的确认页没有形状")
        c.stop()
    }

    func testShapeAgainOpensShapeConfigWithoutPhotoPicker() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.beginShape()
        c.setShapePreset(.star)
        c.setShapePalette(.blue)
        c.setShapeBackground(.black)
        c.setDensity(.coarse)
        c.flowSend(.next)
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("没有图形结果") }
        XCTAssertNil(c.target)
        c.startNewMosaicTapped()
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertFalse(c.state.flow.offersShapeEntry)
        XCTAssertNotEqual(c.state.flow.step, .target, "图形再拼不打开选照片")
        XCTAssertEqual(c.state.flow.shape?.preset, .star)
        XCTAssertEqual(c.state.flow.shape?.palette, .blue)
        XCTAssertEqual(c.state.flow.shape?.background, .black)
        XCTAssertNil(c.target)
        c.stop()
    }

    func testAdjustAndCancelledRemakeStayOnTheResultType() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let saver = FakeResultSaver()
        saver.coordinator = c
        c.resultSaver = saver
        c.start()
        await c.settle()
        c.setTarget(try CoordinatorHarness.target())
        c.flowSend(.next)
        c.flowSend(.next)
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("没有照片结果") }
        c.send(.backToSettings)
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertNil(c.state.flow.shape, "调整照片结果不带出图形")
        await c.adjustDoneTapped()
        await c.settle()
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertNil(c.product?.shapeFrame)

        saver.savedRevision = c.state.resultRevision
        c.startNewMosaicTapped()
        c.setTarget(try CoordinatorHarness.target())
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertNil(c.state.flow.shape)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertNil(c.state.flow.shape)
        XCTAssertNil(c.product?.shapeFrame, "取消再拼仍是原来的照片结果")
        c.stop()
    }

    func testBackBeforeGenerationKeepsTheChosenType() async throws {
        let h = CoordinatorHarness(assets: 40)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.setTarget(try CoordinatorHarness.target())
        c.flowSend(.next)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .target)
        XCTAssertTrue(c.state.flow.hasTarget)
        XCTAssertFalse(c.state.flow.offersShapeEntry)
        c.beginShape()
        XCTAssertNil(c.state.flow.shape)

        let shape = CoordinatorHarness(assets: 40)
        let s = shape.coordinator
        s.start()
        await s.settle()
        s.beginShape()
        s.setShapeUsesText(true)
        s.setShapeTextLine(0, proposed: "生日快乐")
        s.flowSend(.next)
        XCTAssertEqual(s.state.flow.step, .settings)
        s.flowSend(.back)
        XCTAssertEqual(s.state.flow.step, .source)
        XCTAssertEqual(s.state.flow.shape?.textLines.first, "生日快乐", "确认页返回素材，文字还在")
        XCTAssertNil(s.target)
        s.stop()
        c.stop()
    }
}
