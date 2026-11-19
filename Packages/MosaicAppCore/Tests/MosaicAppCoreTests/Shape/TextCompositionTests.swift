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

    func testTinyHanziBoxFailsInsteadOfShrinkingTheGrid() throws {
        let outline = TextOutline(path: ShapePath(elements: [
            .move(ShapePoint(0, 0)), .line(ShapePoint(1, 0)), .line(ShapePoint(1, 1)), .line(ShapePoint(0, 1)), .close,
        ], aspect: 4), widthEm: 4, heightEm: 1, glyphs: [
            TextGlyphBox(text: "小", x: 0, y: 0, width: 0.02, height: 0.02),
        ])
        XCTAssertThrowsError(try TextComposition.requireReadableHanzi(outline)) { error in
            guard case .glyphTooSmall(let text, _, _) = error as? TextComposeFailure else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(text, "小")
        }
    }
}
