import XCTest
@testable import MosaicAppCore
import MosaicCore

/// 预设形状首版入口：10 个形状、自动多色和固定配色、白底黑底。不测文字，也不保存作品。
final class ShapeLoopTests: XCTestCase {
    func testBeginShapeSkipsTargetAndBackClearsIt() {
        var flow = MainFlow(initialSeed: 1)
        XCTAssertNil(flow.shape)
        flow.send(.beginShape)
        XCTAssertEqual(flow.step, .source)
        XCTAssertEqual(flow.shape, ShapeChoice())
        flow.send(.back)
        XCTAssertEqual(flow.step, .target)
        XCTAssertNil(flow.shape)
        flow.send(.beginShape)
        flow.send(.targetLoaded)
        XCTAssertNil(flow.shape)
        flow.send(.beginShape)
        flow.returnToStart()
        XCTAssertNil(flow.shape)
        XCTAssertEqual(flow.step, .target)
    }

    func testBeginShapeIgnoredDuringQuickAgain() {
        var flow = MainFlow(initialSeed: 1)
        flow.send(.targetLoaded)
        flow.send(.next)
        flow.send(.next)
        let effects = flow.generation.send(.startTapped(available: 300))
        guard let run = effects.first(where: { if case .run = $0 { return true }; return false }),
              case .run(let id, let seed) = run else { return XCTFail("没有开始生成") }
        _ = flow.generation.send(.succeeded(runID: id, GenerationOutcome(seed: seed, shouldShowShortageNotice: false, cellCount: 10)))
        flow.syncWithGeneration()
        XCTAssertEqual(flow.step, .result)
        flow.send(.quickAgainStarted)
        XCTAssertTrue(flow.isQuickAgain)
        flow.send(.beginShape)
        XCTAssertNil(flow.shape)
        XCTAssertEqual(flow.step, .target)
    }

    func testTenPresetsAreSelectableAndUnknownIsRejected() throws {
        XCTAssertEqual(PresetShapes.registry.count, 10)
        let locked = ["heart", "star", "circle", "birthdayCake", "flower", "moon",
                      "fourLeafClover", "house", "speechBubble", "roundedSquare"]
        XCTAssertEqual(PresetShapes.registry.map(\.id.rawValue), locked)
        for id in locked {
            let choice = try XCTUnwrap(ShapeChoice.make(preset: id, palette: .gold, background: .black))
            let grid = try ShapeGenerationPlan.grid(choice, density: .coarse)
            XCTAssertGreaterThan(grid.mask.activeCount, 0)
            XCTAssertLessThan(grid.mask.activeCount, grid.mask.columns * grid.mask.rows)
        }
        XCTAssertNil(ShapeChoice.make(preset: "clover"))
        XCTAssertFalse(ShapePresetID(rawValue: "clover").isKnown)
    }

    func testAutoGradientUsesSeveralHuesAndFixedPaletteStaysSingleHue() throws {
        let reds = (0..<40).map { _ in OKLab(L: 0.55, a: 0.12, b: 0.04) }
        let blues = (0..<40).map { _ in OKLab(L: 0.55, a: -0.02, b: -0.14) }
        let colors = reds + blues
        let auto = ShapePaletteBuilder.auto(photoColors: colors)
        let warm = ShapePaletteBuilder.gradient(for: .warmRed, photoColors: colors)
        XCTAssertEqual(auto.kind, .multiHue(count: 2))
        XCTAssertEqual(warm.stops.count, 2)
        XCTAssertNotEqual(auto.gradient.stops, warm.stops)
        let choice = ShapeChoice(preset: .circle, palette: .auto, background: .white)
        let grid = try ShapeGenerationPlan.grid(choice, density: .coarse)
        let autoPixels = try ShapeGenerationPlan.target(choice, grid: grid, photoColors: colors)
        var fixed = choice
        fixed.palette = .warmRed
        fixed.background = .black
        let warmPixels = try ShapeGenerationPlan.target(fixed, grid: grid, photoColors: colors)
        XCTAssertNotEqual(autoPixels.bytes, warmPixels.bytes)
        let again = try ShapeGenerationPlan.grid(fixed, density: .coarse)
        XCTAssertEqual(again.mask, grid.mask)
    }

    func testShapeChoiceKeysExistForEveryPresetAndPalette() {
        for entry in PresetShapes.registry {
            XCTAssertTrue(L10nKey.allUsed.contains(entry.id.titleKey))
        }
        for palette in ShapePalette.allCases {
            XCTAssertTrue(L10nKey.allUsed.contains(palette.titleKey))
        }
        XCTAssertTrue(L10nKey.allUsed.contains(.shapeEntry))
        XCTAssertTrue(L10nKey.allUsed.contains(.shapeBackgroundBlack))
    }
}
