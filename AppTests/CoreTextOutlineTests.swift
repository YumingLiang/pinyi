import UIKit
import XCTest
import MosaicCore
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

    /// 需求 1c 的正式四组。第四组是真实换行，不是斜杠，也不是两个字符「\」「n」。
    /// design/shape-mosaic-v0.1.md:39、:56–57 与 qa/shape-mosaic-test-checklist.md:27：
    /// 硬门是光栅 `cellsPerEm` ≥ 24，四字一行约 27–28。逐字曲线只打印，不用墨水宽高拒绝。
    /// 一组失败不截断后面的日志。`cellsPerEm` 通过也不等于肉眼可读。
    func testOfficialFourGroupsUseRealGlyphBoundsOnFineGrid() throws {
        let groups: [(name: String, lines: [String])] = [
            ("520", TextComposition.lines(from: "520")),
            ("满月快乐", TextComposition.lines(from: "满月快乐")),
            ("LOVE", TextComposition.lines(from: "LOVE")),
            ("生日快乐/宝贝", TextComposition.lines(from: "生日快乐\n宝贝")),
        ]
        XCTAssertEqual(groups[3].lines, ["生日快乐", "宝贝"])
        XCTAssertFalse("生日快乐\n宝贝".contains("\\"))
        for group in groups {
            do {
                let outline = try XCTUnwrap(provider.outline(lines: group.lines), group.name)
                let grid = try ShapeLayoutRules.text(outline)
                let byWidth = grid.raster.fitWidth / outline.widthEm
                let byHeight = grid.raster.fitHeight / outline.heightEm
                let perEm = try ShapeLayoutRules.cellsPerEm(outline)
                let boxes = try ShapeLayoutRules.glyphCellBoxes(outline)
                let hanzi = boxes.filter { ShapeTextRules.units($0.text) >= 1 }
                let glyphLog = boxes.map { String(format: "%@:x=%.4f,y=%.4f,w=%.4f,h=%.4f", $0.text, $0.x, $0.y, $0.width, $0.height) }.joined(separator: ",")
                print(String(format: "TEXT-GROUP %@ cellsPerEm=%.6f byW=%.6f byH=%.6f widthEm=%.6f heightEm=%.6f grid=%dx%d glyphs=%@",
                             group.name, perEm, byWidth, byHeight, outline.widthEm, outline.heightEm, grid.layout.columns, grid.layout.rows, glyphLog))
                XCTAssertEqual(grid.density, .fine, group.name)
                XCTAssertEqual(max(grid.layout.columns, grid.layout.rows), 120, group.name)
                XCTAssertEqual(boxes.map(\.text).joined(), group.lines.joined(), group.name)
                XCTAssertEqual(perEm, min(byWidth, byHeight), accuracy: 1e-6, group.name)
                XCTAssertGreaterThanOrEqual(perEm, 24, group.name)
                if group.lines.contains(where: { ShapeTextRules.units($0) >= 4 }) {
                    XCTAssertGreaterThanOrEqual(perEm, 27, "\(group.name) 四字一行应在约 27–28 格")
                    XCTAssertLessThanOrEqual(perEm, 28, "\(group.name) 四字一行应在约 27–28 格")
                }
                if group.name == "520" || group.name == "LOVE" {
                    XCTAssertTrue(hanzi.isEmpty, group.name)
                    XCTAssertEqual(boxes.count, group.lines[0].count, group.name)
                    XCTAssertGreaterThan(outline.widthEm, 0, group.name)
                }
                try TextComposition.requireReadableHanzi(outline)
                attachMask(grid.mask, name: group.name)
            } catch {
                XCTFail("\(group.name) \(error)")
            }
        }
        let short = try XCTUnwrap(provider.outline(lines: ["宝"]))
        let shortPerEm = try ShapeLayoutRules.cellsPerEm(short)
        print(String(format: "TEXT-GROUP-SCALE 单字宝 cellsPerEm=%.6f 不是正式四组，固定比例 %.6f，不放大铺满 120",
                     shortPerEm, ShapeLayoutRules.nominalTextCellsPerEm))
        XCTAssertEqual(shortPerEm, ShapeLayoutRules.nominalTextCellsPerEm, accuracy: 1e-4)
        XCTAssertLessThan(shortPerEm, 40, "单字若被放大到铺满长边，每 em 会远大于 30")
    }

    /// 第二行墨水中心相对整张掩码中线，容差 8 格。这只看下三分之一的墨水块，不是逐字居中。
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

    /// 测试光栅出的掩码，不是界面截图，也不证明肉眼可读。
    private func attachMask(_ mask: CellMask, name: String) {
        let w = mask.columns, h = mask.rows
        guard w > 0, h > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for index in 0..<mask.cellCount where mask.isActive(index) {
            let column = index % w
            let row = index / w
            ctx.fill(CGRect(x: column, y: h - 1 - row, width: 1, height: 1))
        }
        guard let image = ctx.makeImage() else { return }
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "coretext-mask-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
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
