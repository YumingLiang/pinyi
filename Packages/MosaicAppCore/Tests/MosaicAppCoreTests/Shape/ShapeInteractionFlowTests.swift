import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 形状交互：再拼回到形状配置并保留素材；没开始新生成就返回时原结果还在；
/// 配色或密度改了还没重生成时不能导出旧图；取消和失败不进入成功预览。
/// 照片的未保存提示仍按 B10。这是协调器测试，不是可见界面，也不是 XCUITest。
@MainActor
final class ShapeInteractionFlowTests: XCTestCase {
    private func shapeResult() async throws -> AppCoordinator {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.beginShape()
        c.setDensity(.coarse)
        c.flowSend(.next)
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else {
            XCTFail("形状没有结果 \(c.state.flow.generation.phase)")
            return c
        }
        return c
    }

    func testShapeAgainKeepsSourceAndRestoresResultWithoutNewGeneration() async throws {
        let c = try await shapeResult()
        defer { c.stop() }
        let source = c.state.flow.source.selection
        let seed = c.product?.generation.seed
        c.startNewMosaicTapped()
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(c.state.flow.shape, ShapeChoice())
        XCTAssertEqual(c.state.flow.source.selection, source)
        c.setDensity(.fine)
        c.setShapePalette(.blue)
        c.setShapePreset(.star)
        c.setShapeBackground(.black)
        XCTAssertFalse(c.canExport, "新参数还没生成，不能导出原来的爱心")
        XCTAssertTrue(c.shapeEditsNeedRegeneration)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertEqual(c.state.flow.settings.density, .coarse)
        XCTAssertEqual(c.state.flow.shape, ShapeChoice())
        XCTAssertEqual(c.state.flow.source.selection, source)
        XCTAssertEqual(c.product?.generation.seed, seed)
        XCTAssertEqual(c.product?.shapeBackground, .white)
        XCTAssertTrue(c.canExport)
        XCTAssertFalse(c.shapeEditsNeedRegeneration)
        XCTAssertFalse(c.allowsWorkSave)
    }

    func testAdjustingShapePaletteCannotExportUntilRegeneratedOrReverted() async throws {
        let c = try await shapeResult()
        defer { c.stop() }
        c.send(.backToSettings)
        c.setShapePalette(.gold)
        c.setDensity(.medium)
        XCTAssertEqual(c.settingsPrimaryAction, .generate)
        XCTAssertTrue(c.shapeEditsNeedRegeneration)
        XCTAssertFalse(c.canExport)
        XCTAssertNotNil(c.product?.shapeFrame, "旧结果还留着，但不能当成新参数的成品")
        c.setShapePalette(.auto)
        c.setDensity(.coarse)
        XCTAssertEqual(c.settingsPrimaryAction, .done)
        XCTAssertFalse(c.shapeEditsNeedRegeneration)
        await c.adjustDoneTapped()
        await c.settle()
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertTrue(c.canExport)
        XCTAssertNil(c.state.unsavedPrompt)
    }

    func testCancelAndFailureStayOffSuccessfulPreview() async throws {
        let gate = GatePoint()
        let gen = GatedGenerator(gate: gate)
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.beginShape()
        let source = c.state.flow.source.selection
        c.flowSend(.next)
        Task { await c.generateTapped() }
        await gate.reached.wait()
        XCTAssertNotEqual(c.state.flow.step, .result)
        XCTAssertFalse(c.canExport)
        c.send(.cancelTapped)
        c.send(.cancelConfirmed)
        await gate.release.open()
        await c.settle()
        XCTAssertEqual(c.state.flow.generation.phase, .idle)
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertEqual(c.state.flow.shape, ShapeChoice())
        XCTAssertEqual(c.state.flow.source.selection, source)
        XCTAssertNil(c.product)
        XCTAssertFalse(c.canExport)

        gen.failFromCall.set(2)
        await c.generateTapped()
        await c.settle()
        guard case .failed = c.state.flow.generation.phase else {
            return XCTFail("失败没有停在失败态 \(c.state.flow.generation.phase)")
        }
        XCTAssertNotEqual(c.state.flow.step, .result, "失败不能落到成功预览")
        XCTAssertEqual(c.state.flow.shape?.preset, .heart)
        XCTAssertEqual(c.state.flow.source.selection, source)
        XCTAssertFalse(c.canExport)
        XCTAssertNil(c.state.unsavedPrompt)
        c.stop()
    }

    func testPhotoAgainStillAsksToSave() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let saver = FakeResultSaver()
        saver.coordinator = c
        c.resultSaver = saver
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else { return XCTFail("照片没有结果") }
        c.startNewMosaicTapped()
        XCTAssertEqual(c.state.unsavedPrompt, .startNew)
        XCTAssertEqual(c.state.flow.step, .result, "还没确认离开，停在预览")
        c.unsavedPromptCancel()
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertTrue(c.allowsWorkSave)
        c.stop()
    }
}
