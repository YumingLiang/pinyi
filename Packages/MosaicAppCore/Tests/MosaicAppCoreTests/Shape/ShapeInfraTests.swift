import Foundation
import XCTest
@testable import MosaicAppCore
import MosaicCore

/// 形状基础设施：光栅化、网格规则、文字规则（固定细档）、Codable、配色、合成目标图、素材不足检测。
final class ShapeInfraTests: XCTestCase {
    typealias S = ShapeTestSupport

    // MARK: - 光栅化

    func testSquareFillsInnerAreaExactly() throws {
        let r = try PathRasterizer.rasterize(S.square, columns: 10, rows: 10, marginCells: 1)
        XCTAssertEqual(r.mask.activeCount, 64)
        for row in 0..<10 {
            for col in 0..<10 {
                let inside = (1...8).contains(row) && (1...8).contains(col)
                XCTAssertEqual(r.mask.isActive(column: col, row: row), inside)
                XCTAssertEqual(Int(r.coverage[row * 10 + col]), inside ? 64 : 0)
            }
        }
    }

    /// 半格边界：外接框边缘落在格子正中 → 覆盖恰好 32/64，算形状内（≥ 50%）。
    func testHalfCoveredCellCountsAsInside() throws {
        let r = try PathRasterizer.rasterize(S.square, columns: 10, rows: 10, marginCells: 0.5)
        XCTAssertEqual(Int(r.coverage[0]), 16, "角格只覆盖 1/4")
        XCTAssertEqual(Int(r.coverage[5]), 32, "边格覆盖一半")
        XCTAssertFalse(r.mask.isActive(column: 0, row: 0))
        XCTAssertTrue(r.mask.isActive(column: 5, row: 0))
    }

    func testCircleAreaCloseToPiOverFourAcrossGridSizes() throws {
        for n in [40, 41, 80, 120] {
            let r = try PathRasterizer.rasterize(S.circle, columns: n, rows: n, marginCells: 0.5)
            let ratio = Double(r.mask.activeCount) / (r.fitWidth * r.fitHeight)
            XCTAssertEqual(ratio, Double.pi / 4, accuracy: 0.03, "n = \(n)")
            XCTAssertEqual(S.mirrorXMismatch(r.mask), 0, "n = \(n)")
            XCTAssertEqual(S.mirrorYMismatch(r.mask), 0, "n = \(n)")
            XCTAssertEqual(S.foregroundComponents(r.mask), 1)
        }
    }

    /// 非零环绕：反向内框挖出孔（「回」字）。
    func testNonZeroWindingCutsReversedHole() throws {
        let r = try PathRasterizer.rasterize(S.ringSquare, columns: 20, rows: 20, marginCells: 0)
        XCTAssertFalse(r.mask.isActive(column: 10, row: 10), "中心是孔")
        XCTAssertTrue(r.mask.isActive(column: 2, row: 10))
        XCTAssertEqual(S.interiorHoles(r.mask), [64], "孔 = 8 × 8 格")
    }

    func testRasterIsDeterministic() throws {
        let a = try PathRasterizer.rasterize(S.circle, columns: 57, rows: 33, marginCells: 0.5)
        let b = try PathRasterizer.rasterize(S.circle, columns: 57, rows: 33, marginCells: 0.5)
        XCTAssertEqual(a, b)
    }

    func testRasterRejectsBadGrid() {
        XCTAssertThrowsError(try PathRasterizer.rasterize(S.square, columns: 0, rows: 5, marginCells: 0))
        XCTAssertThrowsError(try PathRasterizer.rasterize(S.square, columns: 2, rows: 2, marginCells: 1))
    }

    // MARK: - 网格规则

    func testPresetGridFollowsDensityAndAspect() throws {
        for (density, n) in [(Density.coarse, 40), (.medium, 80), (.fine, 120)] {
            let sq = try ShapeLayoutRules.preset(path: S.square, density: density)
            XCTAssertEqual(sq.layout.columns, n)
            XCTAssertEqual(sq.layout.rows, n)
            XCTAssertEqual(sq.density, density)
            XCTAssertTrue(sq.mask.matches(sq.layout.grid))
        }
        // 宽 2 : 高 1：长边 80，短边 = ceil(79 / 2 + 1) = 41。
        let wide = ShapePath(elements: S.square.elements, aspect: 2)
        let g = try ShapeLayoutRules.preset(path: wide, density: .medium)
        XCTAssertEqual(g.layout.columns, 80)
        XCTAssertEqual(g.layout.rows, 41)
        // 竖图：行列互换。
        let tall = ShapePath(elements: S.square.elements, aspect: 0.5)
        let t = try ShapeLayoutRules.preset(path: tall, density: .medium)
        XCTAssertEqual(t.layout.columns, 41)
        XCTAssertEqual(t.layout.rows, 80)
    }

    /// 合成目标图尺寸经 `Layout.grid` 得到同一个网格（掩码可直接作 activeCells）。
    func testTargetImageSizeMapsBackToSameGrid() throws {
        for aspect in [0.37, 0.8, 1, 1.15, 2.6] {
            let p = ShapePath(elements: S.square.elements, aspect: aspect)
            for d in [Density.coarse, .medium, .fine] {
                let g = try ShapeLayoutRules.preset(path: p, density: d)
                let back = try Layout.grid(width: g.layout.columns * 16, height: g.layout.rows * 16, density: d)
                XCTAssertEqual(back.grid, g.layout.grid, "aspect \(aspect) \(d)")
                XCTAssertEqual(back.cropRect.width, Double(g.layout.columns * 16), accuracy: 1e-9)
            }
        }
    }

    // MARK: - 文字：固定细档（需求 1c；架构师 S2 接口 4）

    func testTextModeIsAlwaysFineDensity() throws {
        XCTAssertEqual(ShapeLayoutRules.textDensity, .fine)
        XCTAssertEqual(ShapeLayoutRules.presetMarginCells, 1, "设计 v0.1.1 §2：预设和文字都是 1 格边距")
        XCTAssertEqual(ShapeLayoutRules.textMarginCells, 1)
        // 不同宽高比的「文字轮廓」都按长边 120 出网格，且没有可传密度的入口。
        for (aspect, w, h) in [(2.3, 2.3, 1.0), (4.3, 4.3, 1.0), (2.0, 4.3, 2.15), (0.9, 1.0, 1.1)] {
            let o = TextOutline(path: ShapePath(elements: S.square.elements, aspect: aspect), widthEm: w, heightEm: h)
            let g = try ShapeLayoutRules.text(o)
            XCTAssertEqual(g.density, .fine)
            XCTAssertEqual(max(g.layout.columns, g.layout.rows), 120)
        }
    }

    /// 每 em 格数：4 个汉字一行（约 4.3 em 宽）≈ 27 格 ≥ 24；两行 4 字也 ≥ 24；1–3 字约 30 以上。
    func testCellsPerEmMeetsAcceptanceLine() throws {
        func cpe(_ w: Double, _ h: Double) throws -> Double {
            try ShapeLayoutRules.cellsPerEm(TextOutline(path: ShapePath(elements: S.square.elements, aspect: w / h),
                                                        widthEm: w, heightEm: h))
        }
        XCTAssertGreaterThanOrEqual(try cpe(4.3, 1.0), 24)
        XCTAssertEqual(try cpe(4.3, 1.0), 118 / 4.3, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(try cpe(4.3, 2.15), 24)
        XCTAssertGreaterThanOrEqual(try cpe(3.3, 1.0), 30)
        XCTAssertLessThan(try cpe(6, 1), 24, "超出时不达标（UI 提示 shape.text.too_long）")
        XCTAssertFalse(try ShapeLayoutRules.meetsMinimumCellsPerEm(
            TextOutline(path: ShapePath(elements: S.square.elements, aspect: 6), widthEm: 6, heightEm: 1)))
    }

    func testTextFilterAndCounting() {
        XCTAssertEqual(ShapeTextRules.filter("生日快乐").text, "生日快乐")
        XCTAssertFalse(ShapeTextRules.filter("LOVE520").droppedUnsupported)
        let f = ShapeTextRules.filter("宝贝❤️ ！a1😀1️⃣")
        XCTAssertEqual(f.text, "宝贝a1")
        XCTAssertTrue(f.droppedUnsupported)
        XCTAssertEqual(ShapeTextRules.units("生日快乐"), 4)
        XCTAssertEqual(ShapeTextRules.units("LOVE"), 2)
        XCTAssertEqual(ShapeTextRules.units("520"), 1.5)
        XCTAssertEqual(ShapeTextRules.validate(lines: ["生日快乐", "宝贝"]), .ok)
        XCTAssertEqual(ShapeTextRules.validate(lines: ["LOVELOVE"]), .ok, "英文数字每行约 8 个")
        XCTAssertEqual(ShapeTextRules.validate(lines: ["", ""]), .empty)
        XCTAssertEqual(ShapeTextRules.validate(lines: ["生日快乐呀"]), .lineTooLong(line: 0))
        XCTAssertEqual(ShapeTextRules.validate(lines: ["a", "b", "c"]), .tooManyLines)
        XCTAssertFalse(ShapeTextRules.canAppend("呀", to: "生日快乐"))
        XCTAssertFalse(ShapeTextRules.canAppend("😀", to: ""))
        XCTAssertTrue(ShapeTextRules.canAppend("A", to: "LOVELOV"))
    }

    // MARK: - Codable（manifest v2 字段名）

    func testShapeSpecCodableUsesManifestFieldNames() throws {
        let spec = ShapeSpec(source: .text(lines: ["生日快乐", "宝贝"]), palette: .warmRed, background: .black)
        let data = try JSONEncoder().encode(spec)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["color"] as? String, "warmRed")
        XCTAssertEqual(obj["background"] as? String, "black")
        XCTAssertEqual((obj["source"] as? [String: Any])?["text"] as? [String], ["生日快乐", "宝贝"])
        XCTAssertNil(obj["outline"], "P0 不存 outline")
        XCTAssertEqual(try JSONDecoder().decode(ShapeSpec.self, from: data), spec)

        let bad = Data(#"{"source":{"preset":"no-such-shape"},"color":"auto","background":"white"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ShapeSpec.self, from: bad))
        let both = Data(#"{"source":{"preset":"x","text":["a"]},"color":"auto","background":"white"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ShapeSpec.self, from: both))
        XCTAssertEqual(Set(ShapePalette.allCases.map(\.rawValue)), ["auto", "warmRed", "pink", "blue", "gold"])
    }

    // MARK: - 渐变与配色

    func testGradientInterpolatesAnyNumberOfStops() {
        let a = OKLab(L: 0.3, a: 0.1, b: 0), b = OKLab(L: 0.6, a: 0, b: 0.1), c = OKLab(L: 0.9, a: -0.1, b: 0)
        let g = ShapeGradient(stops: [a, b, c])
        XCTAssertEqual(g.color(at: 0), a)
        XCTAssertEqual(g.color(at: 0.5), b)
        XCTAssertEqual(g.color(at: 1), c)
        XCTAssertEqual(g.color(at: 0.25).L, 0.45, accuracy: 1e-5)
        XCTAssertEqual(g.color(at: -1), a)
        XCTAssertEqual(g.distance(to: b), 0, accuracy: 1e-6)
        XCTAssertEqual(ShapeGradient(stops: [a]).color(at: 0.7), a)
    }

    /// 4 个固定配色 = 两个色标的同一种渐变。
    func testFixedPalettesAreTwoStopGradients() {
        for p in ShapePalette.allCases where p != .auto {
            let g = ShapePaletteBuilder.gradient(for: p, photoColors: [])
            XCTAssertEqual(g.stops.count, 2, "\(p)")
            let (s, e) = ShapePaletteBuilder.fixedEndpoints(p)!
            let start = ShapeTarget.srgb8(g.stops[0])
            XCTAssertEqual(Int(start.r), Int((s >> 16) & 0xFF), accuracy: 1)
            XCTAssertEqual(Int(start.g), Int((s >> 8) & 0xFF), accuracy: 1)
            XCTAssertEqual(Int(start.b), Int(s & 0xFF), accuracy: 1)
            let end = ShapeTarget.srgb8(g.stops[1])
            XCTAssertEqual(Int(end.r), Int((e >> 16) & 0xFF), accuracy: 1)
        }
    }

    /// 两种以上主色：多段渐变，形状里能看出两种以上颜色的过渡（AndyL 11-17 05:55 验收）。
    func testAutoPaletteMultiHueShowsTransitionInsideShape() throws {
        let colors = S.cluster(hueDegrees: 30, chroma: 0.12, count: 400, seed: 1)
            + S.cluster(hueDegrees: 150, chroma: 0.10, count: 300, seed: 2)
            + S.cluster(hueDegrees: 260, chroma: 0.10, count: 200, seed: 3)
            + (0..<100).map { i in OKLab(L: Float(i) / 100, a: 0, b: 0) }
        let auto = ShapePaletteBuilder.auto(photoColors: colors)
        XCTAssertEqual(auto.kind, .multiHue(count: 3))
        let hues = auto.gradient.stops.map(S.hueDegrees)
        XCTAssertEqual(hues, hues.sorted(), "按色相排序")
        for (i, h) in hues.enumerated() {
            for h2 in hues.dropFirst(i + 1) { XCTAssertGreaterThan(S.hueGap(h, h2), 50) }
        }

        // 形状内：左上角与右下角的格子色相差很大（两种以上颜色的过渡）。
        let g = try ShapeLayoutRules.preset(path: S.circle, density: .coarse)
        let img = try ShapeTarget.render(mask: g.mask, gradient: auto.gradient, background: .white)
        let active = g.mask.activeIndices
        let first = active.min { ($0 % 40 + $0 / 40) < ($1 % 40 + $1 / 40) }!
        let last = active.max { ($0 % 40 + $0 / 40) < ($1 % 40 + $1 / 40) }!
        func hueAt(_ i: Int) -> Double {
            let (r, gg, b) = img.rgb(x: (i % 40) * 16 + 8, y: (i / 40) * 16 + 8)
            return S.hueDegrees(OKLab(LinearRGB(srgb8Red: r, green: gg, blue: b)))
        }
        XCTAssertGreaterThan(S.hueGap(hueAt(first), hueAt(last)), 90)
        // 不同色相的格子至少 3 种（按 60° 分组）。
        let groups = Set(active.map { Int(hueAt($0) / 60) })
        XCTAssertGreaterThanOrEqual(groups.count, 3)
    }

    func testAutoPaletteTwoHues() {
        let colors = S.cluster(hueDegrees: 20, chroma: 0.12, count: 300, seed: 4)
            + S.cluster(hueDegrees: 200, chroma: 0.10, count: 250, seed: 5)
        let auto = ShapePaletteBuilder.auto(photoColors: colors)
        XCTAssertEqual(auto.kind, .multiHue(count: 2))
        XCTAssertGreaterThan(S.hueGap(S.hueDegrees(auto.gradient.stops[0]), S.hueDegrees(auto.gradient.stops[1])), 120)
    }

    /// 只有一种主色：退成这个颜色的深浅渐变，不报错。
    func testAutoPaletteSingleHueFallsBackToShades() {
        let colors = S.cluster(hueDegrees: 40, chroma: 0.11, count: 500, seed: 6)
        let auto = ShapePaletteBuilder.auto(photoColors: colors)
        XCTAssertEqual(auto.kind, .singleHue)
        XCTAssertEqual(auto.gradient.stops.count, 2)
        let (s0, s1) = (auto.gradient.stops[0], auto.gradient.stops[1])
        XCTAssertLessThan(S.hueGap(S.hueDegrees(s0), 40), 15)
        XCTAssertEqual(S.hueDegrees(s0), S.hueDegrees(s1), accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(s1.L - s0.L, 0.1, "看得出深浅")
    }

    /// 有彩照片 < 30%：按明度的中性渐变。空相册不报错。
    func testAutoPaletteGrayAlbumFallsBackToLightness() {
        let gray = (0..<800).map { i in OKLab(L: Float(i % 100) / 100, a: 0.005, b: -0.004) }
        let colors = gray + S.cluster(hueDegrees: 30, chroma: 0.12, count: 200, seed: 7) // 20% 有彩
        let auto = ShapePaletteBuilder.auto(photoColors: colors)
        XCTAssertEqual(auto.kind, .lightness)
        XCTAssertEqual(auto.gradient.stops[0].a, 0)
        XCTAssertLessThan(auto.gradient.stops[0].L, auto.gradient.stops[1].L)
        XCTAssertEqual(ShapePaletteBuilder.auto(photoColors: []).kind, .empty)
    }

    /// 有彩照片：chroma ≥ 0.03（正好 0.03 算有彩）。走明度渐变的条件是有彩占比**严格小于** 30%（设计 v0.1.1 §4）。
    func testColorfulShareBoundaryAt29_30_31Percent() {
        func album(colorful: Int, total: Int) -> [OKLab] {
            let hued = S.cluster(hueDegrees: 45, chroma: 0.12, count: colorful, seed: 21)
            let gray = (0..<(total - colorful)).map { i in OKLab(L: 0.2 + Float(i % 60) / 100, a: 0.01, b: -0.01) }
            return hued + gray
        }
        XCTAssertEqual(ShapePaletteBuilder.auto(photoColors: album(colorful: 29, total: 100)).kind, .lightness, "29%")
        XCTAssertNotEqual(ShapePaletteBuilder.auto(photoColors: album(colorful: 30, total: 100)).kind, .lightness, "30% 整按多色走")
        XCTAssertNotEqual(ShapePaletteBuilder.auto(photoColors: album(colorful: 31, total: 100)).kind, .lightness, "31%")
        // 另一组总数，排除只在 100 张时成立：290 / 300 / 310 ‰。
        XCTAssertEqual(ShapePaletteBuilder.auto(photoColors: album(colorful: 290, total: 1000)).kind, .lightness)
        XCTAssertNotEqual(ShapePaletteBuilder.auto(photoColors: album(colorful: 300, total: 1000)).kind, .lightness)
        XCTAssertNotEqual(ShapePaletteBuilder.auto(photoColors: album(colorful: 310, total: 1000)).kind, .lightness)
        // 色度边界：0.03 算有彩，0.0299 算近灰。
        XCTAssertGreaterThanOrEqual(ShapePaletteBuilder.chroma(OKLab(L: 0.5, a: 0.03, b: 0)), ShapePaletteBuilder.grayChroma)
        XCTAssertLessThan(ShapePaletteBuilder.chroma(OKLab(L: 0.5, a: 0.0299, b: 0)), ShapePaletteBuilder.grayChroma)
        let edge = [OKLab](repeating: OKLab(L: 0.5, a: 0.03, b: 0), count: 3)
            + [OKLab](repeating: OKLab(L: 0.5, a: 0, b: 0), count: 7)
        XCTAssertNotEqual(ShapePaletteBuilder.auto(photoColors: edge).kind, .lightness, "3/10 且色度正好 0.03")
    }

    /// 色标门槛 10%（设计 v0.1.1 §4-2）：正好 10% 的桶能当色标，不到 10% 的不能。
    func testStopShareBoundaryAtTenPercent() {
        // 色相取桶中心（每桶 30°），±8° 抖动不会跨桶。
        let main = S.cluster(hueDegrees: 45, chroma: 0.12, count: 90, seed: 31)
        let tenth = S.cluster(hueDegrees: 225, chroma: 0.12, count: 10, seed: 32)   // 10 / 100 = 10%
        XCTAssertEqual(ShapePaletteBuilder.auto(photoColors: main + tenth).kind, .multiHue(count: 2))
        let fewer = S.cluster(hueDegrees: 225, chroma: 0.12, count: 9, seed: 33)    // 9 / 99 < 10%
        XCTAssertEqual(ShapePaletteBuilder.auto(photoColors: main + fewer).kind, .singleHue)
    }

    /// 单主色明度太集中：以中点为中心各拉开 0.1，并限制在 L 0.05–0.95（设计 v0.1.1 §4-2，e2a3755）。
    func testSingleHueStretchIsClampedToValidLightness() {
        func flat(_ l: Float) -> [OKLab] { (0..<200).map { i in OKLab(L: l + Float(i % 3) * 0.001, a: 0.06, b: 0.06) } }
        let mid = ShapePaletteBuilder.auto(photoColors: flat(0.5))
        XCTAssertEqual(mid.kind, .singleHue)
        XCTAssertEqual(mid.gradient.stops[1].L - mid.gradient.stops[0].L, 0.2, accuracy: 1e-3)
        let bright = ShapePaletteBuilder.auto(photoColors: flat(0.93))
        XCTAssertEqual(bright.gradient.stops[1].L, 0.95, accuracy: 1e-6)
        XCTAssertLessThan(bright.gradient.stops[0].L, bright.gradient.stops[1].L)
        let dark = ShapePaletteBuilder.auto(photoColors: flat(0.02))
        XCTAssertEqual(dark.gradient.stops[0].L, 0.05, accuracy: 1e-6)
        // 没有可用颜色：中性灰 0.45 → 0.80，不报错。
        let none = ShapePaletteBuilder.auto(photoColors: [])
        XCTAssertEqual(none.gradient.stops.map(\.L), [0.45, 0.80])
        XCTAssertEqual(none.gradient.stops.map(\.a), [0, 0])
    }

    /// 文字轮廓（各种宽高比、各种排版大小）也不会出全 0 掩码。
    func testTextMasksAreNeverAllZero() throws {
        for aspect in [0.4, 0.9, 1.0, 2.3, 4.3, 6.0, 8.6] {
            for path in [S.square, S.circle] {
                let o = TextOutline(path: ShapePath(elements: path.elements, aspect: aspect), widthEm: aspect, heightEm: 1)
                let g = try ShapeLayoutRules.text(o)
                XCTAssertGreaterThan(g.mask.activeCount, 0, "aspect \(aspect)")
                XCTAssertEqual(g.density, .fine)
            }
        }
    }

    /// 色标与种子无关：同一批照片（顺序不同）得到同一渐变。
    func testAutoPaletteDeterministic() {
        let colors = S.cluster(hueDegrees: 20, chroma: 0.12, count: 300, seed: 4)
            + S.cluster(hueDegrees: 200, chroma: 0.10, count: 250, seed: 5)
        XCTAssertEqual(ShapePaletteBuilder.auto(photoColors: colors), ShapePaletteBuilder.auto(photoColors: colors.reversed()))
    }

    // MARK: - 素材不足检测（固定配色）

    func testColorShortageThreshold() {
        // 自动上限 cap = ceil(形状内格数 / 可用 × 2)；所需近色张数 = max(50, ceil(格数 / cap))。
        XCTAssertEqual(ShapeColorShortage.requiredNearCount(activeCells: 1000, availableCount: 5000), 1000)
        XCTAssertEqual(ShapeColorShortage.requiredNearCount(activeCells: 1000, availableCount: 300), 143)
        XCTAssertEqual(ShapeColorShortage.requiredNearCount(activeCells: 60, availableCount: 5000), 60)
        XCTAssertEqual(ShapeColorShortage.requiredNearCount(activeCells: 1000, availableCount: 300, cap: .unlimited), 50)

        let red = ShapePaletteBuilder.gradient(for: .warmRed, photoColors: [])
        let nearRed = (0..<120).map { i in red.color(at: Double(i) / 119) }
        let blue = S.cluster(hueDegrees: 260, chroma: 0.12, count: 2000, seed: 8)
        XCTAssertEqual(ShapeColorShortage.nearCount(photoColors: nearRed + blue, gradient: red), 120)
        XCTAssertTrue(ShapeColorShortage.shouldWarn(palette: .warmRed, photoColors: nearRed + blue, activeCells: 1200))
        XCTAssertFalse(ShapeColorShortage.shouldWarn(palette: .warmRed, photoColors: nearRed + blue, activeCells: 100))
        XCTAssertFalse(ShapeColorShortage.shouldWarn(palette: .auto, photoColors: blue, activeCells: 5000), "auto 不做此检测")
    }

    // MARK: - 合成目标图

    func testTargetPaintsCellsNotPath() throws {
        let g = try ShapeLayoutRules.preset(path: S.circle, density: .coarse)
        let grad = ShapePaletteBuilder.gradient(for: .blue, photoColors: [])
        for bg in ShapeBackground.allCases {
            let img = try ShapeTarget.render(mask: g.mask, gradient: grad, background: bg)
            XCTAssertEqual(img.width, g.layout.columns * 16)
            XCTAssertEqual(img.height, g.layout.rows * 16)
            for i in [0, 820, 1599] {
                let c = i % 40, r = i / 40
                let corner = img.rgb(x: c * 16, y: r * 16), center = img.rgb(x: c * 16 + 15, y: r * 16 + 15)
                XCTAssertTrue(corner == center, "整格同色")
                if !g.mask.isActive(i) {
                    XCTAssertTrue(corner == bg.srgb8, "形状外 = 背景色")
                } else {
                    let want = ShapeTarget.srgb8(ShapeTarget.cellColor(column: c, row: r, columns: 40, rows: 40, gradient: grad))
                    XCTAssertTrue(corner == want)
                }
            }
        }
    }

    // MARK: - 端到端：掩码 + 合成目标图 + 匹配器

    func testEndToEndOnlyShapeCellsGetPhotos() throws {
        let g = try ShapeLayoutRules.preset(path: S.circle, density: .coarse)
        let records = (0..<600).map { i -> FeatureRecord in
            let l = Float(i % 50) / 50, a = Float(i % 7) * 0.03 - 0.09, b = Float(i % 11) * 0.02 - 0.1
            return FeatureRecord(vector: FeatureVector(uniform: SIMD3(l, a, b)), lightnessVariance: 0.01, aspectRatio: 1)
        }
        let snap = try LibrarySnapshot(table: FeatureTable(records: records))
        let colors = ShapePaletteBuilder.photoColors(snapshot: snap)
        XCTAssertEqual(colors.count, 600)
        let auto = ShapePaletteBuilder.auto(photoColors: colors)
        let target = try ShapeTarget.render(mask: g.mask, gradient: auto.gradient, background: .white)
        let gen = try MosaicPipeline().generate(target: target, density: g.density, snapshot: snap, seed: 1,
                                                activeCells: g.mask)
        XCTAssertEqual(gen.layout.grid, g.layout.grid)
        for i in 0..<g.mask.cellCount {
            XCTAssertEqual(gen.assignment.tiles[i] >= 0, g.mask.isActive(i))
        }
        XCTAssertEqual(gen.assignment.statistics.cellCount, g.mask.activeCount)
    }
}
