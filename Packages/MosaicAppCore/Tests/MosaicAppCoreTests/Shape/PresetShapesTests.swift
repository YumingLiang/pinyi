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
        "flower": Expectation(mirrorX: true, mirrorY: false, fill: 0.65...0.85),
        "moon": Expectation(mirrorX: false, mirrorY: true, fill: 0.35...0.65),
        "fourLeafClover": Expectation(mirrorX: false, mirrorY: false, fill: 0.40...0.70),
        "house": Expectation(mirrorX: false, mirrorY: false, fill: 0.65...0.90),
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
                // 0.5 格边距：最外一圈格子最多被盖住一半（≤ 32/64）。
                let cols = g.mask.columns, rows = g.mask.rows
                for i in 0..<g.mask.cellCount where i % cols == 0 || i % cols == cols - 1 || i / cols == 0 || i / cols == rows - 1 {
                    XCTAssertLessThanOrEqual(Int(g.raster.coverage[i]), PathRasterizer.insideThreshold, tag)
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
