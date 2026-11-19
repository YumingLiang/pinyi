import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 文字没有界面。这里测的是 `prepareText` / `generateText` 这条 API：
/// 生成途中换正文、取消后换正文、再切到形状或照片时，旧完成回调不能盖掉新选择，也不能把旧正文导出或分享。
/// 不表示用户已经能在界面上触发。
@MainActor
final class TextReentryTests: XCTestCase {
    private func outline(_ name: String) -> TextOutline {
        TextOutline(path: ShapePath(elements: [
            .move(ShapePoint(0, 0)), .line(ShapePoint(1, 0)), .line(ShapePoint(1, 1)), .line(ShapePoint(0, 1)), .close,
        ], aspect: 1), widthEm: 1, heightEm: 1, glyphs: [
            TextGlyphBox(text: name, x: 0, y: 0, width: 1, height: 1),
        ])
    }

    private func prepare(_ c: AppCoordinator, _ lines: [String]) {
        c.prepareText(lines: lines, outline: outline(lines.joined()), palette: .auto, background: .white)
    }

    func testSwitchingTextDuringGenerationDoesNotExportOldBody() async throws {
        let gate = GatePoint()
        let gen = GatedGenerator(gate: gate)
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.start()
        await c.settle()
        prepare(c, ["520"])
        let started = Task { await c.generateTapped() }
        await gate.reached.wait()
        XCTAssertTrue(c.state.isGenerating)
        prepare(c, ["LOVE"])
        let ignored = Task { await c.generateTapped() }
        await ignored.value
        XCTAssertEqual(c.preparedText?.lines, ["LOVE"])
        await gate.release.open()
        await started.value
        await c.settle()
        XCTAssertEqual(c.preparedText?.lines, ["LOVE"], "完成回调不能把正文盖回 520")
        XCTAssertFalse(c.canExport, "旧正文结果不能按新正文导出")
        XCTAssertFalse(c.allowsWorkSave)
        if case .result = c.state.flow.generation.phase {
            XCTFail("旧正文完成不能进入结果页冒充 LOVE")
        }
        c.shareTapped()
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(h.exporter.state.get().exports, 0)
        c.stop()
    }

    func testCancelThenNewTextIgnoresLateCompletion() async throws {
        let gate = GatePoint()
        let gen = GatedGenerator(gate: gate)
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.start()
        await c.settle()
        prepare(c, ["520"])
        let started = Task { await c.generateTapped() }
        await gate.reached.wait()
        c.send(.cancelTapped)
        c.send(.cancelConfirmed)
        prepare(c, ["满月快乐"])
        await gate.release.open()
        await started.value
        await c.settle()
        XCTAssertEqual(c.preparedText?.lines, ["满月快乐"])
        XCTAssertFalse(c.canExport)
        XCTAssertFalse(c.allowsWorkSave)
        if case .result = c.state.flow.generation.phase {
            XCTFail("取消后的迟到完成不能变成结果")
        }
        c.shareTapped()
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(h.exporter.state.get().exports, 0)
        c.stop()
    }

    func testShapeOrPhotoSelectionSurvivesStaleTextCompletion() async throws {
        let gate = GatePoint()
        let gen = GatedGenerator(gate: gate)
        let h = CoordinatorHarness(assets: 300, generator: gen)
        let c = h.coordinator
        c.start()
        await c.settle()
        prepare(c, ["520"])
        let started = Task { await c.generateTapped() }
        await gate.reached.wait()
        c.beginShape()
        XCTAssertEqual(c.state.flow.shape?.preset, .heart)
        XCTAssertNil(c.preparedText)
        await gate.release.open()
        await started.value
        await c.settle()
        XCTAssertEqual(c.state.flow.shape?.preset, .heart)
        XCTAssertNil(c.preparedText)
        XCTAssertFalse(c.canExport)
        if case .result = c.state.flow.generation.phase {
            XCTFail("切到形状后，旧文字回调不能进入结果页")
        }
        c.stop()

        let gate2 = GatePoint()
        let gen2 = GatedGenerator(gate: gate2)
        let h2 = CoordinatorHarness(assets: 300, generator: gen2)
        let c2 = h2.coordinator
        c2.start()
        await c2.settle()
        prepare(c2, ["LOVE"])
        let started2 = Task { await c2.generateTapped() }
        await gate2.reached.wait()
        c2.setTarget(try CoordinatorHarness.target())
        XCTAssertNil(c2.preparedText)
        XCTAssertNotNil(c2.target)
        await gate2.release.open()
        await started2.value
        await c2.settle()
        XCTAssertNotNil(c2.target)
        XCTAssertNil(c2.preparedText)
        XCTAssertFalse(c2.canExport)
        if case .result = c2.state.flow.generation.phase {
            XCTFail("切到照片后，旧文字回调不能进入结果页")
        }
        c2.shareTapped()
        await c2.saveTapped()
        await c2.settle()
        XCTAssertEqual(h2.exporter.state.get().exports, 0)
        c2.stop()
    }

    func testCompletedTextStopsExportingWhenBodyChanges() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        c.start()
        await c.settle()
        prepare(c, ["520"])
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else {
            return XCTFail("文字没有结果 \(c.state.flow.generation.phase)")
        }
        XCTAssertTrue(c.canExport)
        XCTAssertFalse(c.allowsWorkSave)
        prepare(c, ["LOVE"])
        XCTAssertEqual(c.preparedText?.lines, ["LOVE"])
        XCTAssertFalse(c.canExport, "换了正文，旧的 520 结果不能继续导出")
        c.shareTapped()
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(h.exporter.state.get().exports, 0)
        c.stop()
    }
}
