import XCTest
@testable import MosaicAppCore

/// 文字入参的明确失败。不跑 CoreText，也不把 Linux 矩形当成系统字体。
final class TextCompositionTests: XCTestCase {
    func testRealNewlineSplitsTheFourthGroup() throws {
        let lines = TextComposition.lines(from: "生日快乐\n宝贝")
        XCTAssertEqual(lines, ["生日快乐", "宝贝"])
        XCTAssertFalse(lines.joined().contains("\\"))
        XCTAssertEqual(try TextComposition.prepare(lines), ["生日快乐", "宝贝"])
    }

    func testLiteralBackslashNIsNotALineBreak() {
        let lines = TextComposition.lines(from: "生日快乐\\n宝贝")
        XCTAssertEqual(lines, ["生日快乐\\n宝贝"])
        XCTAssertThrowsError(try TextComposition.prepare(lines)) { error in
            XCTAssertEqual(error as? TextComposeFailure, .unsupported)
        }
    }

    func testEmptyTooLongAndEmojiFailWithoutChangingTheText() {
        XCTAssertThrowsError(try TextComposition.prepare([])) { error in
            XCTAssertEqual(error as? TextComposeFailure, .empty)
        }
        XCTAssertThrowsError(try TextComposition.prepare(["", " "])) { error in
            XCTAssertEqual(error as? TextComposeFailure, .empty)
        }
        XCTAssertThrowsError(try TextComposition.prepare(["生日快乐", "宝贝", "再一行"])) { error in
            XCTAssertEqual(error as? TextComposeFailure, .tooManyLines)
        }
        XCTAssertThrowsError(try TextComposition.prepare(["生日快乐呀"])) { error in
            XCTAssertEqual(error as? TextComposeFailure, .lineTooLong(line: 0))
        }
        XCTAssertThrowsError(try TextComposition.prepare(["满月😀"])) { error in
            XCTAssertEqual(error as? TextComposeFailure, .unsupported)
        }
        XCTAssertEqual(try TextComposition.prepare(["520"]), ["520"])
        XCTAssertEqual(try TextComposition.prepare(["LOVE"]), ["LOVE"])
        XCTAssertEqual(try TextComposition.prepare(["满月快乐"]), ["满月快乐"])
        XCTAssertThrowsError(try TextComposition.prepare(["ABCDEFGHI"])) { error in
            XCTAssertEqual(error as? TextComposeFailure, .lineTooLong(line: 0))
        }
        XCTAssertEqual(try TextComposition.prepare(["ABCDEFGH"]), ["ABCDEFGH"])
    }

    /// design/shape-mosaic-v0.1.md:39 与 qa/shape-mosaic-test-checklist.md:27。
    /// 门是光栅 `cellsPerEm`，不是单字墨水宽高。窄墨水不能把「月」拒掉。
    func testNarrowInkDoesNotRejectWhenRasterCellsPerEmMeets24() throws {
        let outline = TextOutline(path: ShapePath(elements: [
            .move(ShapePoint(0, 0)), .line(ShapePoint(1, 0)), .line(ShapePoint(1, 1)), .line(ShapePoint(0, 1)), .close,
        ], aspect: 4), widthEm: 4, heightEm: 1, glyphs: [
            TextGlyphBox(text: "月", x: 0.2, y: 0.05, width: 0.19, height: 0.9),
        ])
        let grid = try ShapeLayoutRules.text(outline)
        let byWidth = grid.raster.fitWidth / outline.widthEm
        let byHeight = grid.raster.fitHeight / outline.heightEm
        let perEm = try ShapeLayoutRules.cellsPerEm(outline)
        XCTAssertEqual(perEm, min(byWidth, byHeight), accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(perEm, 24)
        let ink = try ShapeLayoutRules.glyphCellBoxes(outline)
        XCTAssertLessThan(ink[0].width, 24, "月的墨水宽可以小于 24 格")
        XCTAssertNoThrow(try TextComposition.requireReadableHanzi(outline))
    }

    func testCellsPerEmUsesTheSmallerRasterAxisNotNominalWidth() {
        let value = ShapeLayoutRules.cellsPerEm(fitWidth: 118, widthEm: 4.3, fitHeight: 40, heightEm: 2)
        XCTAssertEqual(value, 20, accuracy: 1e-9, "高度更紧时必须用 fitH/heightEm")
        XCTAssertGreaterThan(118 / 4.3, 27, "只取宽度会得到约 27.4，不能拿来代替 min")
        XCTAssertLessThan(value, ShapeLayoutRules.minimumCellsPerEm)
    }

    func testOutlineThatCannotHoldTheFixedEmScaleFailsInsteadOfShrinking() {
        let outline = TextOutline(path: ShapePath(elements: [
            .move(ShapePoint(0, 0)), .line(ShapePoint(1, 0)), .line(ShapePoint(1, 1)), .line(ShapePoint(0, 1)), .close,
        ], aspect: 6), widthEm: 6, heightEm: 1, glyphs: [
            TextGlyphBox(text: "宽", x: 0, y: 0, width: 1, height: 1),
        ])
        XCTAssertThrowsError(try TextComposition.requireReadableHanzi(outline))
    }
}
