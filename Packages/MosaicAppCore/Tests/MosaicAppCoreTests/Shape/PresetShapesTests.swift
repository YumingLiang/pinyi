import Foundation
import XCTest
@testable import MosaicAppCore
import MosaicCore

/// 10 个预设形状（需求 1a，验收 1）：掩码非空、连通、无孔、对称性、面积大致合理、不同网格尺寸下一致。
/// 测试遍历注册表；砍掉某个形状只需删注册表条目（这里的期望表多出来的条目不影响）。
final class PresetShapesTests: XCTestCase {
    typealias S = ShapeTestSupport

    /// 实现顺序（产品经理 11-17 05:55）：先 5 个，再 5 个。
    static let implementationOrder = ["heart", "star", "circle", "birthdayCake", "flower",
                                      "moon", "fourLeafClover", "house", "speechBubble", "roundedSquare"]

    struct Expectation {
        var mirrorX: Bool
        var mirrorY: Bool
        /// 形状内格数 ÷ 外接框格数 的合理范围（细档）。
        var fill: ClosedRange<Double>
    }

    static let expectations: [String: Expectation] = [
        "heart": Expectation(mirrorX: true, mirrorY: false, fill: 0.62...0.78),
        "star": Expectation(mirrorX: true, mirrorY: false, fill: 0.35...0.55),
        "circle": Expectation(mirrorX: true, mirrorY: true, fill: 0.76...0.81),
        "birthdayCake": Expectation(mirrorX: true, mirrorY: false, fill: 0.45...0.75),
        "flower": Expectation(mirrorX: true, mirrorY: false, fill: 0.45...0.65),   // 凹口加深后（产品 11-17）面积比约 0.52
        "moon": Expectation(mirrorX: false, mirrorY: true, fill: 0.35...0.65),
        "fourLeafClover": Expectation(mirrorX: false, mirrorY: false, fill: 0.40...0.70),
        "house": Expectation(mirrorX: false, mirrorY: false, fill: 0.55...0.85),
        "speechBubble": Expectation(mirrorX: false, mirrorY: false, fill: 0.65...0.90),
        "roundedSquare": Expectation(mirrorX: true, mirrorY: true, fill: 0.95...0.98),
    ]

    static let densities: [Density] = [.coarse, .medium, .fine, .custom(columns: 57)]

    func testRegistryOrderAndIDs() {
        let ids = ShapePresetID.all.map(\.rawValue)
        XCTAssertEqual(ids, Array(Self.implementationOrder.prefix(ids.count)), "按约定顺序登记")
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ShapePresetID.all {
            XCTAssertTrue(id.isKnown)
            XCTAssertNotNil(Self.expectations[id.rawValue], "\(id) 缺测试期望")
        }
    }

    /// rawValue 会写进作品 manifest 的 `source.preset`、也是文案 key `shape.preset.<id>` 的后缀，定稿后不能改（设计 v0.1.1 §1）。
    func testPresetRawValuesAreLocked() throws {
        XCTAssertEqual(ShapePresetID.heart.rawValue, "heart")
        XCTAssertEqual(ShapePresetID.star.rawValue, "star")
        XCTAssertEqual(ShapePresetID.circle.rawValue, "circle")
        XCTAssertEqual(ShapePresetID.birthdayCake.rawValue, "birthdayCake")
        XCTAssertEqual(ShapePresetID.flower.rawValue, "flower")
        XCTAssertEqual(ShapePresetID.moon.rawValue, "moon")
        XCTAssertEqual(ShapePresetID.fourLeafClover.rawValue, "fourLeafClover")
        XCTAssertEqual(ShapePresetID.house.rawValue, "house")
        XCTAssertEqual(ShapePresetID.speechBubble.rawValue, "speechBubble")
        XCTAssertEqual(ShapePresetID.roundedSquare.rawValue, "roundedSquare")
        XCTAssertEqual(ShapePresetID.all.map(\.rawValue), Self.implementationOrder)
        // 已登记的能解码；没登记的（大小写不同、旧名、空串）一律报错。
        for raw in Self.implementationOrder {
            let id = try JSONDecoder().decode(ShapePresetID.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(id.rawValue, raw)
        }
        for raw in ["Heart", "cake", "clover", "bubble", "square", ""] {
            XCTAssertThrowsError(try JSONDecoder().decode(ShapePresetID.self, from: Data("\"\(raw)\"".utf8)), raw)
            let json = #"{"source":{"preset":"\#(raw)"},"color":"auto","background":"white"}"#
            XCTAssertThrowsError(try JSONDecoder().decode(ShapeSpec.self, from: Data(json.utf8)), raw)
        }
    }

    /// 预设形状在任何密度下都不会出全 0 掩码（全 0 时引擎不抛错、返回全 -1，见 MosaicCore ActiveCellsTests）。
    func testPresetMasksAreNeverAllZero() throws {
        for id in ShapePresetID.all {
            for d in [Density.coarse, .medium, .fine, .custom(columns: 57), .custom(columns: 12)] {
                let g = try ShapeLayoutRules.preset(id, density: d)
                XCTAssertGreaterThan(g.mask.activeCount, 0, "\(id) @\(d.columns)")
            }
        }
    }

    /// 花朵（产品 11-17）：粗档下以中心为原点径向扫一圈，外缘半径有 5 个明显的局部最大值（5 片花瓣数得出来）。
    func testFlowerHasFiveDistinctPetalsAtCoarse() throws {
        let g = try ShapeLayoutRules.preset(.flower, density: .coarse)
        let peaks = Self.radialPeaks(g.mask, minProminence: 2)
        XCTAssertEqual(peaks.count, 5, "外缘半径峰值 \(peaks)")
        // 相邻峰大约相隔 72°。
        let sorted = peaks.sorted()
        for i in sorted.indices {
            let gap = (sorted[(i + 1) % sorted.count] - sorted[i] + 360) % 360
            XCTAssertEqual(Double(gap), 72, accuracy: 12, "峰角度 \(sorted)")
        }
    }

    /// 从形状内格子的质心出发，每 2° 一条射线，求外缘半径（最后一个形状内格子的距离，单位格）；
    /// 返回「在 ±18° 内最高、且比 ±36° 内最低处高出 minProminence 格」的峰的角度。
    static func radialPeaks(_ m: CellMask, minProminence: Double) -> [Int] {
        var sx = 0.0, sy = 0.0
        let act = m.activeIndices
        for i in act { sx += Double(i % m.columns) + 0.5; sy += Double(i / m.columns) + 0.5 }
        let cx = sx / Double(act.count), cy = sy / Double(act.count)
        let step = 2, n = 360 / step
        var radius = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let a = Double(k * step) * Double.pi / 180
            var r = 0.0
            while true {
                let x = cx + r * cos(a), y = cy + r * sin(a)
                guard x >= 0, y >= 0, x < Double(m.columns), y < Double(m.rows) else { break }
                if m.isActive(column: Int(x), row: Int(y)) { radius[k] = r }
                r += 0.25
            }
        }
        var peaks: [Int] = []
        let near = 18 / step, far = 36 / step
        for k in 0..<n {
            var isMax = true
            var low = Double.infinity
            for d in -far...far {
                let v = radius[(k + d + n) % n]
                low = min(low, v)
                if abs(d) <= near, d != 0 {
                    // 平顶只记最左一个：左侧相等不算峰。
                    if v > radius[k] || (d < 0 && v == radius[k]) { isMax = false }
                }
            }
            if isMax, radius[k] - low >= minProminence { peaks.append(k * step) }
        }
        return peaks
    }

    func testEveryPresetRoundTripsThroughCodable() throws {
        for id in ShapePresetID.all {
            let spec = ShapeSpec(source: .preset(id))
            let data = try JSONEncoder().encode(spec)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""preset":"\#(id.rawValue)""#))
            XCTAssertEqual(try JSONDecoder().decode(ShapeSpec.self, from: data), spec)
        }
    }

    /// 路径归一化到 0…1，所有子路径都是正向（非零环绕下叠加 = 并集）。
    func testPathsAreNormalizedAndPositivelyOriented() throws {
        for entry in PresetShapes.registry {
            let p = entry.path
            XCTAssertGreaterThan(p.aspect, 0.5, "\(entry.id)")
            XCTAssertLessThan(p.aspect, 2, "\(entry.id)")
            let polys = p.polygons(transform: { $0 }, tolerance: 1e-3)
            XCTAssertFalse(polys.isEmpty)
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            for poly in polys {
                XCTAssertGreaterThan(ShapePathBuilder.signedArea(poly), 0, "\(entry.id) 子路径方向")
                for q in poly { minX = min(minX, q.x); maxX = max(maxX, q.x); minY = min(minY, q.y); maxY = max(maxY, q.y) }
            }
            XCTAssertEqual(minX, 0, accuracy: 1e-3); XCTAssertEqual(maxX, 1, accuracy: 1e-3)
            XCTAssertEqual(minY, 0, accuracy: 1e-3); XCTAssertEqual(maxY, 1, accuracy: 1e-3)
        }
    }

    func testMaskNonEmptyConnectedWithoutHolesAtEveryDensity() throws {
        for id in ShapePresetID.all {
            for d in Self.densities {
                let g = try ShapeLayoutRules.preset(id, density: d)
                let tag = "\(id) @\(d.columns)"
                XCTAssertEqual(max(g.layout.columns, g.layout.rows), d.columns, tag)
                XCTAssertTrue(g.mask.matches(g.layout.grid), tag)
                XCTAssertGreaterThan(g.mask.activeCount, g.mask.cellCount / 4, tag)
                XCTAssertLessThan(g.mask.activeCount, g.mask.cellCount, tag)
                XCTAssertEqual(S.foregroundComponents(g.mask), 1, "\(tag) 不能断开")
                XCTAssertEqual(S.interiorHoles(g.mask), [], "\(tag) 内部不留孔")
                // 1 格边距（设计 v0.1.1 §2）：最外一圈格子完全不被覆盖，图边永远留白。
                let cols = g.mask.columns, rows = g.mask.rows
                for i in 0..<g.mask.cellCount where i % cols == 0 || i % cols == cols - 1 || i / cols == 0 || i / cols == rows - 1 {
                    XCTAssertEqual(Int(g.raster.coverage[i]), 0, "\(tag) 边框格 \(i)")
                    XCTAssertFalse(g.mask.isActive(i), tag)
                }
            }
        }
    }

    func testSymmetry() throws {
        for id in ShapePresetID.all {
            guard let e = Self.expectations[id.rawValue] else { continue }
            for d in Self.densities {
                let g = try ShapeLayoutRules.preset(id, density: d)
                let allowance = max(2, g.mask.activeCount / 100)
                if e.mirrorX { XCTAssertLessThanOrEqual(S.mirrorXMismatch(g.mask), allowance, "\(id) @\(d.columns) 左右对称") }
                if e.mirrorY { XCTAssertLessThanOrEqual(S.mirrorYMismatch(g.mask), allowance, "\(id) @\(d.columns) 上下对称") }
            }
        }
    }

    /// 面积在合理范围内，且粗 / 中 / 细 / 57 格下与细档接近（换网格尺寸形状不变）。
    func testAreaReasonableAndStableAcrossGridSizes() throws {
        for id in ShapePresetID.all {
            guard let e = Self.expectations[id.rawValue] else { continue }
            let fine = S.fillRatio(try ShapeLayoutRules.preset(id, density: .fine))
            XCTAssertTrue(e.fill.contains(fine), "\(id) 细档面积比 \(fine) 不在 \(e.fill)")
            for d in Self.densities {
                let r = S.fillRatio(try ShapeLayoutRules.preset(id, density: d))
                XCTAssertEqual(r, fine, accuracy: 0.06, "\(id) @\(d.columns)")
            }
        }
    }

    /// 生成：每个形状都能走完 掩码 → 合成目标图 → 匹配，形状外不分配照片（验收 1、5 的引擎部分）。
    func testEveryPresetGeneratesWithPhotosOnlyInside() throws {
        let records = (0..<500).map { i -> FeatureRecord in
            let l = Float(i % 50) / 50, a = Float(i % 7) * 0.03 - 0.09, b = Float(i % 11) * 0.02 - 0.1
            return FeatureRecord(vector: FeatureVector(uniform: SIMD3(l, a, b)), lightnessVariance: 0.01, aspectRatio: 1)
        }
        let snap = try LibrarySnapshot(table: FeatureTable(records: records))
        let grad = ShapePaletteBuilder.gradient(for: .auto, photoColors: ShapePaletteBuilder.photoColors(snapshot: snap))
        for id in ShapePresetID.all {
            let g = try ShapeLayoutRules.preset(id, density: .coarse)
            let target = try ShapeTarget.render(mask: g.mask, gradient: grad, background: .black)
            let gen = try MosaicPipeline().generate(target: target, density: .coarse, snapshot: snap, seed: 3,
                                                    activeCells: g.mask)
            let inside = (0..<g.mask.cellCount).filter { gen.assignment.tiles[$0] >= 0 }
            XCTAssertEqual(inside, g.mask.activeIndices, "\(id)")
        }
    }

    /// 设 `SHAPE_PREVIEW_OUT=<文件>` 时把每个形状的粗档掩码画成字符图（给 QA / 产品看形状是否认得出）。
    func testWriteAsciiPreviewsWhenRequested() throws {
        guard let out = ProcessInfo.processInfo.environment["SHAPE_PREVIEW_OUT"] else { return }
        var text = ""
        for id in ShapePresetID.all {
            let g = try ShapeLayoutRules.preset(id, density: .coarse)
            text += "== \(id.rawValue) \(g.mask.columns)×\(g.mask.rows) 形状内 \(g.mask.activeCount) 格\n"
            for r in 0..<g.mask.rows {
                text += String((0..<g.mask.columns).map { g.mask.isActive(column: $0, row: r) ? "█" : "·" }) + "\n"
            }
            text += "\n"
        }
        try text.write(toFile: out, atomically: true, encoding: .utf8)
    }
}
