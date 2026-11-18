import XCTest
import MosaicAppCore
@testable import PhotoMosaic

/// CoreText 文字轮廓的 iOS 验收（设计 §1、§3、§10）。
///
/// 设计 v0.1.1（`e2a3755` / `72371fc`，`design/shape-mosaic-v0.1.md` §10）写的是「四组验收文字……以需求 1c 为准」，
/// **没有列出那四组字符串**。仓库里也没有 `product/shape-mosaic-req-v1.0.md`（全部分支都查过）。
/// 下面只跑设计正文里写明的样本：「520」「LOVE」、manifest 示例「生日快乐」「宝贝」，以及 §10 的带孔字「口」「回」。
/// 这不是需求 1c 的具名四组。没有 Apple SDK 的环境跑不到本文件，不能把结果说成已经通过。
final class CoreTextOutlineTests: XCTestCase {
    /// 设计正文里出现的具体文字。不是需求 1c 列出的四组（设计没写那四组）。
    private static let designSamples: [(name: String, lines: [String])] = [
        ("520", ["520"]),
        ("LOVE", ["LOVE"]),
        ("生日快乐", ["生日快乐"]),
        ("宝贝", ["宝贝"]),
        ("生日快乐/宝贝", ["生日快乐", "宝贝"]),
    ]

    private let provider = CoreTextOutline()

    func testEmptyLinesHaveNoOutline() {
        XCTAssertNil(provider.outline(lines: []))
        XCTAssertNil(provider.outline(lines: ["", ""]))
    }

    /// 设计样本在固定细档下每 em ≥ 24 格，边上一圈不点亮，掩码不空。断笔只记日志并断言块数没有变多。
    func testDesignSamplesMeetCellsPerEmOnFineGrid() throws {
        for sample in Self.designSamples {
            let outline = try XCTUnwrap(provider.outline(lines: sample.lines), sample.name)
            let perEm = try ShapeLayoutRules.cellsPerEm(outline)
            print("TEXT-CELLS-PER-EM \(sample.name) \(perEm) widthEm=\(outline.widthEm) heightEm=\(outline.heightEm)")
            XCTAssertGreaterThanOrEqual(perEm, ShapeLayoutRules.minimumCellsPerEm, sample.name)
            XCTAssertTrue(try ShapeLayoutRules.meetsMinimumCellsPerEm(outline), sample.name)
            XCTAssertEqual(outline.path.aspect, outline.widthEm / outline.heightEm, accuracy: 1e-6, sample.name)
            let grid = try ShapeLayoutRules.text(outline)
            XCTAssertEqual(grid.density, .fine, sample.name)
            XCTAssertEqual(max(grid.layout.columns, grid.layout.rows), 120, sample.name)
            XCTAssertGreaterThan(grid.mask.activeCount, 0, sample.name)
            assertBorderUncovered(grid, sample.name)
            let outlineCount = TextMaskDiagnostics.outlineComponentCount(outline.path)
            let rasterCount = TextMaskDiagnostics.rasterComponentCount(grid.mask)
            print("TEXT-COMPONENTS \(sample.name) outline=\(outlineCount) raster=\(rasterCount) holes=\(TextMaskDiagnostics.interiorHoleCount(grid.mask))")
            if let note = TextMaskDiagnostics.brokenStrokeNote(rasterComponents: rasterCount, outlineComponents: outlineCount) {
                print("TEXT-STROKE \(sample.name) \(note)")
            }
            XCTAssertLessThanOrEqual(rasterCount, outlineCount, "\(sample.name) 笔画被栅格断开")
        }
    }

    /// 带孔字形（设计 §10「口」「回」）。用系统粗体，不只用测试里的矩形。
    func testKouAndHuiKeepHoles() throws {
        let kou = try XCTUnwrap(provider.outline(lines: ["口"]))
        let kouGrid = try ShapeLayoutRules.text(kou)
        print("TEXT-CELLS-PER-EM 口 \(try ShapeLayoutRules.cellsPerEm(kou))")
        XCTAssertGreaterThanOrEqual(try ShapeLayoutRules.cellsPerEm(kou), 24)
        XCTAssertEqual(TextMaskDiagnostics.rasterComponentCount(kouGrid.mask), 1, "「口」应是一整圈")
        XCTAssertGreaterThanOrEqual(TextMaskDiagnostics.interiorHoleCount(kouGrid.mask), 1, "「口」中间是孔")
        assertBorderUncovered(kouGrid, "口")

        let hui = try XCTUnwrap(provider.outline(lines: ["回"]))
        let huiGrid = try ShapeLayoutRules.text(hui)
        let huiRaster = TextMaskDiagnostics.rasterComponentCount(huiGrid.mask)
        let huiOutline = TextMaskDiagnostics.outlineComponentCount(hui.path)
        print("TEXT-CELLS-PER-EM 回 \(try ShapeLayoutRules.cellsPerEm(hui)) components outline=\(huiOutline) raster=\(huiRaster) holes=\(TextMaskDiagnostics.interiorHoleCount(huiGrid.mask))")
        XCTAssertGreaterThanOrEqual(try ShapeLayoutRules.cellsPerEm(hui), 24)
        XCTAssertGreaterThanOrEqual(TextMaskDiagnostics.interiorHoleCount(huiGrid.mask), 1, "「回」至少有一个孔")
        XCTAssertLessThanOrEqual(huiRaster, huiOutline, "「回」笔画被栅格断开")
        assertBorderUncovered(huiGrid, "回")
    }

    /// 「宝贝」比「生日快乐」短，第二行应在中间，而不是贴左。
    func testShorterSecondLineIsCentered() throws {
        let outline = try XCTUnwrap(provider.outline(lines: ["生日快乐", "宝贝"]))
        let mask = try ShapeLayoutRules.text(outline).mask
        var minC = mask.columns, maxC = -1, count = 0
        for row in (mask.rows * 2 / 3)..<mask.rows {
            for column in 0..<mask.columns where mask.isActive(column: column, row: row) {
                minC = min(minC, column)
                maxC = max(maxC, column)
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0, "第二行有墨水")
        let mid = Double(minC + maxC) / 2
        // 居中按行宽（advance），不是按墨水外接框。侧向留白会让墨水中心偏出大约一两个字宽的零头，允许约 0.25 em。
        XCTAssertEqual(mid, Double(mask.columns - 1) / 2, accuracy: 8, "第二行居中")
    }

    private func assertBorderUncovered(_ grid: ShapeLayoutRules.ShapeGrid, _ name: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let columns = grid.layout.columns, rows = grid.layout.rows
        for column in 0..<columns {
            XCTAssertEqual(Int(grid.raster.coverage[column]), 0, name, file: file, line: line)
            XCTAssertEqual(Int(grid.raster.coverage[(rows - 1) * columns + column]), 0, name, file: file, line: line)
        }
        for row in 0..<rows {
            XCTAssertEqual(Int(grid.raster.coverage[row * columns]), 0, name, file: file, line: line)
            XCTAssertEqual(Int(grid.raster.coverage[row * columns + columns - 1]), 0, name, file: file, line: line)
        }
    }
}
