import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 文字输入规则。不生成，也不表示界面已经点过。
final class TextDraftEditorTests: XCTestCase {
    func testOfficialSamplesAndEnglishWidthStay() {
        let samples = ["520", "满月快乐", "LOVE", "生日快乐\n宝贝"]
        for sample in samples {
            let result = TextDraftEditor.apply(lines: ["", ""], index: 0, proposed: sample)
            XCTAssertNil(result.notice, sample)
            XCTAssertEqual(ShapeTextRules.validate(lines: result.lines), .ok, sample)
        }
        XCTAssertEqual(TextDraftEditor.apply(lines: ["", ""], index: 0, proposed: "生日快乐\n宝贝").lines,
                       ["生日快乐", "宝贝"])
        let eight = TextDraftEditor.apply(lines: ["", ""], index: 0, proposed: "ABCDEFGH")
        XCTAssertNil(eight.notice)
        XCTAssertEqual(eight.lines[0], "ABCDEFGH")
        XCTAssertEqual(ShapeTextRules.units("ABCDEFGH"), 4)
    }

    func testOverLimitEmojiAndExtraLineAreRejectedWhole() {
        let tooLong = TextDraftEditor.apply(lines: ["满月快乐", ""], index: 0, proposed: "满月快乐呀")
        XCTAssertEqual(tooLong.lines, ["满月快乐", ""])
        XCTAssertEqual(tooLong.notice, .lineTooLong(line: 0))

        let emoji = TextDraftEditor.apply(lines: ["LOVE", ""], index: 0, proposed: "LOVE😀")
        XCTAssertEqual(emoji.lines, ["LOVE", ""])
        XCTAssertEqual(emoji.notice, .unsupported)

        let nine = TextDraftEditor.apply(lines: ["", ""], index: 1, proposed: "ABCDEFGHI")
        XCTAssertEqual(nine.lines, ["", ""])
        XCTAssertEqual(nine.notice, .lineTooLong(line: 1))

        let third = TextDraftEditor.apply(lines: ["生日快乐", "宝贝"], index: 0, proposed: "生日快乐\n宝贝\n呀")
        XCTAssertEqual(third.lines, ["生日快乐", "宝贝"])
        XCTAssertEqual(third.notice, .tooManyLines)

        let fromSecond = TextDraftEditor.apply(lines: ["生日快乐", "宝贝"], index: 1, proposed: "宝贝\n呀")
        XCTAssertEqual(fromSecond.lines, ["生日快乐", "宝贝"])
        XCTAssertEqual(fromSecond.notice, .tooManyLines)
    }
}

/// 图形配置里的文字会话。协调器 API，不是 SwiftUI 点击，也不是 XCUITest。
@MainActor
final class TextSessionTests: XCTestCase {
    private func outline(_ name: String) -> TextOutline {
        TextOutline(path: ShapePath(elements: [
            .move(ShapePoint(0, 0)), .line(ShapePoint(1, 0)), .line(ShapePoint(1, 1)), .line(ShapePoint(0, 1)), .close,
        ], aspect: 1), widthEm: 1, heightEm: 1, glyphs: [
            TextGlyphBox(text: name, x: 0, y: 0, width: 1, height: 1),
        ])
    }

    private func prepare(_ c: AppCoordinator, _ lines: [String]) {
        c.prepareText(lines: lines, outline: outline(lines.joined()), palette: c.state.flow.shape?.palette ?? .auto,
                      background: c.state.flow.shape?.background ?? .white)
    }

    func testEmptyOverLimitAndEmojiDoNotStartGeneration() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.beginShape()
        c.setShapeUsesText(true)
        XCTAssertFalse(c.shapeTextCanGenerate)
        await c.generateTapped()
        await c.settle()
        XCTAssertNil(c.product)
        if case .idle = c.state.flow.generation.phase {} else {
            XCTFail("空正文不能开始生成 \(c.state.flow.generation.phase)")
        }

        c.setShapeTextLine(0, proposed: "满月快乐呀")
        XCTAssertEqual(c.state.flow.shape?.textLines, ["", ""])
        XCTAssertEqual(c.state.shapeTextNotice, .lineTooLong(line: 0))
        c.setShapeTextLine(0, proposed: "😀")
        XCTAssertEqual(c.state.flow.shape?.textLines, ["", ""])
        XCTAssertEqual(c.state.shapeTextNotice, .unsupported)
        await c.generateTapped()
        await c.settle()
        XCTAssertNil(c.product)
        c.stop()
    }

    func testTextSessionKeepsBodyThroughGenerateAdjustAndRemake() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.beginShape()
        c.setDensity(.coarse)
        let source = c.state.flow.source.selection
        c.setShapeUsesText(true)
        XCTAssertEqual(c.state.flow.settings.density, .fine)
        c.setDensity(.coarse)
        XCTAssertEqual(c.state.flow.settings.density, .fine, "文字没有密度控件，调用也不改档")
        c.setShapePreset(.star)
        XCTAssertEqual(c.state.flow.shape?.preset, .heart, "文字模式下不改预设")
        c.setShapeTextLine(0, proposed: "满月快乐")
        c.flowSend(.next)
        prepare(c, ["满月快乐"])
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else {
            return XCTFail("文字没有结果 \(c.state.flow.generation.phase)")
        }
        XCTAssertEqual(c.state.flow.settings.density, .fine)
        XCTAssertEqual(c.state.flow.settings.overlayAlpha, 0)
        XCTAssertEqual(c.state.flow.shape?.usesText, true)
        XCTAssertEqual(TextDraftEditor.committedLines(c.state.flow.shape?.textLines ?? []), ["满月快乐"])
        XCTAssertEqual(c.state.flow.source.selection, source)
        XCTAssertTrue(c.canExport)
        XCTAssertFalse(c.allowsWorkSave)
        XCTAssertNotNil(c.product?.shapeFrame)

        c.send(.backToSettings)
        XCTAssertEqual(TextDraftEditor.committedLines(c.state.flow.shape?.textLines ?? []), ["满月快乐"])
        c.setShapeTextLine(0, proposed: "520")
        XCTAssertFalse(c.canExport, "换了正文不能导出旧结果")
        c.setShapeTextLine(0, proposed: "满月快乐")
        XCTAssertEqual(c.settingsPrimaryAction, .done)
        await c.adjustDoneTapped()
        await c.settle()
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertTrue(c.canExport)

        c.startNewMosaicTapped()
        XCTAssertNil(c.state.unsavedPrompt)
        XCTAssertEqual(c.state.flow.step, .settings)
        XCTAssertEqual(c.state.flow.shape?.usesText, true)
        XCTAssertEqual(TextDraftEditor.committedLines(c.state.flow.shape?.textLines ?? []), ["满月快乐"])
        XCTAssertEqual(c.state.flow.source.selection, source)
        c.flowSend(.back)
        XCTAssertEqual(c.state.flow.step, .result)
        XCTAssertTrue(c.canExport)
        XCTAssertFalse(c.allowsWorkSave)
        c.stop()
    }

    func testSwitchingPresetTextAndPhotoDoesNotCrossExport() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        c.start()
        await c.settle()
        c.beginShape()
        c.setDensity(.coarse)
        c.setShapeUsesText(true)
        c.setShapeTextLine(0, proposed: "LOVE")
        c.setShapeUsesText(false)
        XCTAssertEqual(c.state.flow.settings.density, .coarse, "切回预设后密度还是切走之前的")
        XCTAssertEqual(c.state.flow.shape?.textLines.first, "LOVE", "草稿还在，但当前不是文字")
        XCTAssertEqual(c.state.flow.shape?.usesText, false)
        c.setShapePreset(.star)
        XCTAssertEqual(c.state.flow.shape?.preset, .star)
        c.flowSend(.next)
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else {
            return XCTFail("预设没有结果 \(c.state.flow.generation.phase)")
        }
        XCTAssertTrue(c.canExport)
        c.setShapeUsesText(true)
        XCTAssertFalse(c.canExport, "切到文字后不能把星星结果导出成文字")
        XCTAssertFalse(c.allowsWorkSave)
        c.setShapeUsesText(false)
        XCTAssertEqual(c.state.flow.shape?.preset, .star)
        XCTAssertTrue(c.canExport)

        c.send(.backToSettings)
        prepare(c, ["LOVE"])
        await c.generateTapped()
        await c.settle()
        guard case .result = c.state.flow.generation.phase else {
            return XCTFail("文字没有结果 \(c.state.flow.generation.phase)")
        }
        XCTAssertEqual(c.state.flow.shape?.usesText, true)
        XCTAssertTrue(c.canExport)
        c.setShapeUsesText(false)
        XCTAssertFalse(c.canExport, "切回预设后不能把文字结果导出成预设")
        c.setTarget(try CoordinatorHarness.target())
        XCTAssertNil(c.state.flow.shape)
        XCTAssertNil(c.preparedText)
        XCTAssertNotNil(c.target)
        XCTAssertFalse(c.canExport)
        c.shareTapped()
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(h.exporter.state.get().exports, 0)
        c.stop()
    }
}
