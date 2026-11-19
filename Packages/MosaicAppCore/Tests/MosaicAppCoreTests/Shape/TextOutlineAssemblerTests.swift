import XCTest
@testable import MosaicAppCore
import MosaicCore

/// 文字轮廓排版（设计 §1、§2）。不依赖 CoreText：字形轮廓用矩形代替，验证行距 1.15 em、居中、y 向下、
/// em 外接框和每 em 格数。真正的系统字体在 AppTests/`CoreTextOutlineTests`（只有 Apple SDK 能跑）。
final class TextOutlineAssemblerTests: XCTestCase {
    private let em = TextOutlineAssembler.fontSizePoints

    func testConstantsMatchDesign() {
        XCTAssertEqual(TextOutlineAssembler.fontSizePoints, 100, "UIFont 字号 100，1 em = 100 点")
        XCTAssertEqual(TextOutlineAssembler.lineSpacingEm, 1.15, accuracy: 1e-12)
    }

    func testEmptyAndDegenerateReturnNil() {
        XCTAssertNil(TextOutlineAssembler.assemble(lines: []))
        XCTAssertNil(TextOutlineAssembler.assemble(lines: [TextLinePlacement(glyphs: [], advance: 0)]))
        XCTAssertNil(TextOutlineAssembler.assemble(lines: [line(square(0, 0, em), advance: em)], fontSize: 0))
        XCTAssertNil(TextOutlineAssembler.assemble(lines: [line(square(0, 0, em), advance: em)], lineSpacingEm: 0))
    }

    func testGlyphBoxesKeepEachSquareInsteadOfSplittingTheLine() throws {
        let wide = TextGlyphPlacement(elements: square(0, 0, em, em).elements, originX: 0, originY: 0, text: "大")
        let narrow = TextGlyphPlacement(elements: square(1.2 * em, 0, 0.4 * em, em).elements, originX: 0, originY: 0, text: "小")
        let outline = try XCTUnwrap(TextOutlineAssembler.assemble(lines: [
            TextLinePlacement(glyphs: [wide, narrow], advance: 1.6 * em),
        ]))
        XCTAssertEqual(outline.glyphs.map(\.text), ["大", "小"])
        let boxes = try ShapeLayoutRules.glyphCellBoxes(outline)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertGreaterThan(boxes[0].width, boxes[1].width * 1.5, "宽字和窄字不能被整行均分")
        XCTAssertGreaterThanOrEqual(boxes[0].width, 24)
        XCTAssertGreaterThanOrEqual(boxes[0].height, 24)
        XCTAssertLessThan(boxes[1].width, boxes[0].width)
    }

    /// 归一化外接框和 path.aspect 是同一套数；一个 em 见方的字，细档每 em 就是内框格数。
    func testSingleEmSquareReportsMatchingBounds() throws {
        let outline = try XCTUnwrap(TextOutlineAssembler.assemble(lines: [line(square(0, 0, em), advance: em)]))
        XCTAssertEqual(outline.widthEm, 1, accuracy: 1e-9)
        XCTAssertEqual(outline.heightEm, 1, accuracy: 1e-9)
        XCTAssertEqual(outline.path.aspect, outline.widthEm / outline.heightEm, accuracy: 1e-9)
        let grid = try ShapeLayoutRules.text(outline)
        XCTAssertEqual(grid.density, .fine)
        XCTAssertEqual(grid.layout.columns, 120)
        XCTAssertEqual(grid.layout.rows, 120)
        XCTAssertEqual(try ShapeLayoutRules.cellsPerEm(outline), ShapeLayoutRules.nominalTextCellsPerEm, accuracy: 1e-6)
        XCTAssertTrue(try ShapeLayoutRules.meetsMinimumCellsPerEm(outline))
        assertBorderClear(grid)
        assertPolygonsInsideUnitBox(outline.path)
    }

    /// 设计 §3 的估计：一行约 4.3 em 宽 → 每 em ≥ 24（118 / 4.3）。两行行距 1.15 em，墨水高 2.15 em，仍由宽度卡住。
    func testDesignEstimateOfFourEmAndTwoLines() throws {
        let row = fourEmRow()
        let one = try XCTUnwrap(TextOutlineAssembler.assemble(lines: [row]))
        XCTAssertEqual(one.widthEm, 4.3, accuracy: 1e-9)
        XCTAssertEqual(one.heightEm, 1, accuracy: 1e-9)
        XCTAssertEqual(try ShapeLayoutRules.cellsPerEm(one), 118 / 4.3, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(try ShapeLayoutRules.cellsPerEm(one), 24)

        let two = try XCTUnwrap(TextOutlineAssembler.assemble(lines: [row, row]))
        XCTAssertEqual(two.widthEm, 4.3, accuracy: 1e-9)
        XCTAssertEqual(two.heightEm, 2.15, accuracy: 1e-9, "两行：1 em 墨水 + 1.15 em 行距")
        XCTAssertEqual(try ShapeLayoutRules.cellsPerEm(two), 118 / 4.3, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(try ShapeLayoutRules.cellsPerEm(two), 24)
        let grid = try ShapeLayoutRules.text(two)
        XCTAssertEqual(max(grid.layout.columns, grid.layout.rows), 120)
        assertBorderClear(grid)
    }

    /// 短的第二行按行宽居中，不贴左。
    func testShorterSecondLineIsCentered() throws {
        let wide = line(square(0, 0, 2 * em, em), advance: 2 * em)
        let narrow = line(square(0, 0, em, em), advance: em)
        let outline = try XCTUnwrap(TextOutlineAssembler.assemble(lines: [wide, narrow]))
        let grid = try ShapeLayoutRules.text(outline)
        let mask = grid.mask
        // 第二行在外接框的下半（y 向下，基线在 1.15 / 2.15 处）。取最下面若干行的形状内格子。
        var minC = mask.columns, maxC = -1, count = 0
        for r in (mask.rows * 2 / 3)..<mask.rows {
            for c in 0..<mask.columns where mask.isActive(column: c, row: r) {
                minC = min(minC, c); maxC = max(maxC, c); count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        let mid = Double(minC + maxC) / 2
        XCTAssertEqual(mid, Double(mask.columns - 1) / 2, accuracy: 1.5, "第二行墨水在网格中间")
    }

    /// y 向上的尖角翻到图的上方（行号小的一侧更窄）。
    func testYUpApexLandsAtTheTop() throws {
        let apex = TextGlyphPlacement(elements: [
            .move(ShapePoint(0, 0)),
            .line(ShapePoint(em, 0)),
            .line(ShapePoint(em / 2, em)),
            .close,
        ], originX: 0, originY: 0)
        let outline = try XCTUnwrap(TextOutlineAssembler.assemble(lines: [line(apex, advance: em)]))
        let mask = try ShapeLayoutRules.text(outline).mask
        var inkRows: [Int] = []
        for row in 0..<mask.rows {
            if (0..<mask.columns).contains(where: { mask.isActive(column: $0, row: row) }) { inkRows.append(row) }
        }
        let span = inkRows.count
        XCTAssertGreaterThan(span, 8, "短字仍有可读高度，但不再铺满 120 行")
        XCTAssertLessThan(span, mask.rows / 2)
        func active(in rows: ArraySlice<Int>) -> Int {
            var n = 0
            for r in rows {
                for c in 0..<mask.columns where mask.isActive(column: c, row: r) { n += 1 }
            }
            return n
        }
        let third = max(1, span / 3)
        let top = active(in: inkRows.prefix(third))
        let bottom = active(in: inkRows.suffix(third))
        XCTAssertGreaterThan(bottom, top * 2, "尖角在上，底下更宽")
    }

    /// 「口」：1 个轮廓连通块、1 个孔，光栅化不把笔画拆开。边框一圈覆盖为 0。
    func testSquareRingStaysOneComponentWithAHole() throws {
        let outline = try XCTUnwrap(TextOutlineAssembler.assemble(lines: [line(ring(outer: em, hole: 0.5 * em), advance: em)]))
        XCTAssertEqual(TextMaskDiagnostics.outlineComponentCount(outline.path), 1)
        let grid = try ShapeLayoutRules.text(outline)
        XCTAssertEqual(TextMaskDiagnostics.rasterComponentCount(grid.mask), 1)
        XCTAssertEqual(TextMaskDiagnostics.interiorHoleCount(grid.mask), 1)
        XCTAssertNil(TextMaskDiagnostics.brokenStrokeNote(rasterComponents: 1, outlineComponents: 1))
        assertBorderClear(grid)
        XCTAssertGreaterThanOrEqual(try ShapeLayoutRules.cellsPerEm(outline), 24)
    }

    /// 「回」：外框和内框是两块，各自有孔。
    func testDoubleRingCountsTwoComponents() throws {
        let outline = try XCTUnwrap(TextOutlineAssembler.assemble(lines: [line(doubleRing(em), advance: em)]))
        let outlineCount = TextMaskDiagnostics.outlineComponentCount(outline.path)
        XCTAssertEqual(outlineCount, 2)
        let grid = try ShapeLayoutRules.text(outline)
        let rasterCount = TextMaskDiagnostics.rasterComponentCount(grid.mask)
        XCTAssertEqual(rasterCount, 2)
        XCTAssertGreaterThanOrEqual(TextMaskDiagnostics.interiorHoleCount(grid.mask), 1)
        XCTAssertNil(TextMaskDiagnostics.brokenStrokeNote(rasterComponents: rasterCount, outlineComponents: outlineCount))
    }

    /// 细到过不了 50% 的连笔：轮廓仍是 1 块，格子上拆成 2 块，说明里记一笔。P0 不修补。
    func testThinBridgeIsReportedAsBrokenStroke() throws {
        let outline = try XCTUnwrap(TextOutlineAssembler.assemble(lines: [line(dumbbell(em), advance: 2.2 * em)]))
        XCTAssertEqual(TextMaskDiagnostics.outlineComponentCount(outline.path), 1)
        let rasterCount = TextMaskDiagnostics.rasterComponentCount(try ShapeLayoutRules.text(outline).mask)
        XCTAssertEqual(rasterCount, 2)
        let note = TextMaskDiagnostics.brokenStrokeNote(rasterComponents: rasterCount, outlineComponents: 1)
        XCTAssertEqual(note, "text mask split strokes: raster components 2 > outline 1")
    }

    func testAssembleIsDeterministic() {
        let lines = [fourEmRow(), fourEmRow()]
        XCTAssertEqual(TextOutlineAssembler.assemble(lines: lines), TextOutlineAssembler.assemble(lines: lines))
    }

    /// `normalized` 仍是原来的路径；外接框和 aspect 一致。
    func testNormalizedReportingBoundsAgreesWithNormalized() {
        let raw: [ShapePath.Element] = [
            .move(ShapePoint(2, 5)), .line(ShapePoint(6, 5)), .line(ShapePoint(6, 9)), .line(ShapePoint(2, 9)), .close,
        ]
        let box = ShapePath.normalizedReportingBounds(raw)
        XCTAssertEqual(box?.path, ShapePath.normalized(raw))
        XCTAssertEqual(box?.width ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(box?.height ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(box?.path.aspect ?? 0, 1, accuracy: 1e-9)
        XCTAssertNil(ShapePath.normalizedReportingBounds([]))
    }

    // MARK: - 字形

    private func line(_ glyph: TextGlyphPlacement, advance: Double) -> TextLinePlacement {
        TextLinePlacement(glyphs: [glyph], advance: advance)
    }

    /// y 向上的实心矩形，左下 (x, y)，宽 w 高 h。
    private func square(_ x: Double, _ y: Double, _ w: Double, _ h: Double? = nil) -> TextGlyphPlacement {
        let hh = h ?? w
        return TextGlyphPlacement(elements: [
            .move(ShapePoint(x, y)),
            .line(ShapePoint(x + w, y)),
            .line(ShapePoint(x + w, y + hh)),
            .line(ShapePoint(x, y + hh)),
            .close,
        ], originX: 0, originY: 0)
    }

    /// 四个 1 em 方块，总墨水宽 4.3 em（设计 §3 的一行四字估计）。
    private func fourEmRow() -> TextLinePlacement {
        let gap = 0.1 * em
        var glyphs: [TextGlyphPlacement] = []
        for i in 0..<4 {
            let x = Double(i) * (em + gap)
            glyphs.append(TextGlyphPlacement(elements: square(x, 0, em).elements, originX: 0, originY: 0))
        }
        return TextLinePlacement(glyphs: glyphs, advance: 4.3 * em)
    }

    /// 方环。「口」。外轮廓逆时针（y 向上），孔顺时针，方向相反。
    private func ring(outer: Double, hole: Double) -> TextGlyphPlacement {
        let inset = (outer - hole) / 2
        return TextGlyphPlacement(elements: [
            .move(ShapePoint(0, 0)), .line(ShapePoint(outer, 0)), .line(ShapePoint(outer, outer)), .line(ShapePoint(0, outer)), .close,
            .move(ShapePoint(inset, inset)),
            .line(ShapePoint(inset, inset + hole)),
            .line(ShapePoint(inset + hole, inset + hole)),
            .line(ShapePoint(inset + hole, inset)),
            .close,
        ], originX: 0, originY: 0)
    }

    /// 两层方环。「回」。
    private func doubleRing(_ outer: Double) -> TextGlyphPlacement {
        let a = ring(outer: outer, hole: 0.6 * outer)
        let inner = ring(outer: 0.3 * outer, hole: 0.1 * outer)
        let shift = 0.35 * outer
        let moved = inner.elements.map { e -> ShapePath.Element in
            switch e {
            case .move(let p): return .move(ShapePoint(p.x + shift, p.y + shift))
            case .line(let p): return .line(ShapePoint(p.x + shift, p.y + shift))
            case .quad(let c, let p): return .quad(ShapePoint(c.x + shift, c.y + shift), ShapePoint(p.x + shift, p.y + shift))
            case .cubic(let c1, let c2, let p):
                return .cubic(ShapePoint(c1.x + shift, c1.y + shift), ShapePoint(c2.x + shift, c2.y + shift),
                              ShapePoint(p.x + shift, p.y + shift))
            case .close: return .close
            }
        }
        return TextGlyphPlacement(elements: a.elements + moved, originX: 0, originY: 0)
    }

    /// 两个方块用一条极细的桥连成一个轮廓。桥高 0.002 em，细档盖不住半格。
    private func dumbbell(_ side: Double) -> TextGlyphPlacement {
        let gap = 0.2 * side
        let bridge = 0.002 * side
        let y0 = (side - bridge) / 2
        let y1 = y0 + bridge
        let right = side + gap
        return TextGlyphPlacement(elements: [
            .move(ShapePoint(0, 0)),
            .line(ShapePoint(side, 0)),
            .line(ShapePoint(side, y0)),
            .line(ShapePoint(right, y0)),
            .line(ShapePoint(right, 0)),
            .line(ShapePoint(right + side, 0)),
            .line(ShapePoint(right + side, side)),
            .line(ShapePoint(right, side)),
            .line(ShapePoint(right, y1)),
            .line(ShapePoint(side, y1)),
            .line(ShapePoint(side, side)),
            .line(ShapePoint(0, side)),
            .close,
        ], originX: 0, originY: 0)
    }

    private func assertBorderClear(_ grid: ShapeLayoutRules.ShapeGrid, file: StaticString = #filePath, line: UInt = #line) {
        let c = grid.layout.columns, r = grid.layout.rows
        for i in 0..<c {
            XCTAssertEqual(Int(grid.raster.coverage[i]), 0, file: file, line: line)
            XCTAssertEqual(Int(grid.raster.coverage[(r - 1) * c + i]), 0, file: file, line: line)
        }
        for row in 0..<r {
            XCTAssertEqual(Int(grid.raster.coverage[row * c]), 0, file: file, line: line)
            XCTAssertEqual(Int(grid.raster.coverage[row * c + c - 1]), 0, file: file, line: line)
        }
    }

    private func assertPolygonsInsideUnitBox(_ path: ShapePath, file: StaticString = #filePath, line: UInt = #line) {
        for poly in path.polygons(transform: { $0 }, tolerance: 1e-3) {
            for p in poly {
                XCTAssertGreaterThanOrEqual(p.x, -1e-6, file: file, line: line)
                XCTAssertLessThanOrEqual(p.x, 1 + 1e-6, file: file, line: line)
                XCTAssertGreaterThanOrEqual(p.y, -1e-6, file: file, line: line)
                XCTAssertLessThanOrEqual(p.y, 1 + 1e-6, file: file, line: line)
            }
        }
    }
}
