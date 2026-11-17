import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 预览位图尺寸约定（feat/preview-sharp-quick）：每格 48–64 px，长边上限约 4096。
final class PreviewImageLimitsTests: XCTestCase {
    /// 旧口径（对照）：每格 8–32，长边约 2400。只出现在测试里，方便写清改前尺寸。
    static func legacyCellPixels(columns: Int, rows: Int) -> Int {
        max(8, min(32, 2400 / max(max(columns, rows), 1)))
    }

    func testTypicalDensitiesStayWithinCapAndPrefer48to64() {
        // 粗 40×30（4:3 横图）
        XCTAssertEqual(PreviewImageLimits.cellPixels(columns: 40, rows: 30), 64)
        XCTAssertEqual(PreviewImageLimits.size(columns: 40, rows: 30).width, 2560)
        XCTAssertEqual(PreviewImageLimits.size(columns: 40, rows: 30).height, 1920)
        XCTAssertGreaterThanOrEqual(PreviewImageLimits.cellPixels(columns: 40, rows: 30),
                                    PreviewImageLimits.minPreferredCellPixels)

        // 中 80×60：4096/80 = 51，落在 48–64
        XCTAssertEqual(PreviewImageLimits.cellPixels(columns: 80, rows: 60), 51)
        let mid = PreviewImageLimits.size(columns: 80, rows: 60)
        XCTAssertEqual(mid.width, 80 * 51)
        XCTAssertEqual(mid.height, 60 * 51)
        XCTAssertLessThanOrEqual(max(mid.width, mid.height), PreviewImageLimits.maxLongEdge)

        // 细 120×90：4096/120 = 34，低于 48，但长边守住 4096
        XCTAssertEqual(PreviewImageLimits.cellPixels(columns: 120, rows: 90), 34)
        let fine = PreviewImageLimits.size(columns: 120, rows: 90)
        XCTAssertEqual(fine.width, 120 * 34)
        XCTAssertLessThanOrEqual(fine.width, PreviewImageLimits.maxLongEdge)
        XCTAssertLessThan(fine.cellPixels, PreviewImageLimits.minPreferredCellPixels)
    }

    func testPortraitUsesTheLongerSide() {
        XCTAssertEqual(PreviewImageLimits.cellPixels(columns: 30, rows: 40), 64)
        XCTAssertEqual(PreviewImageLimits.cellPixels(columns: 90, rows: 120), 34)
    }

    func testLongEdgeCapAndDegenerateInputs() {
        XCTAssertEqual(PreviewImageLimits.cellPixels(columns: 64, rows: 64), 64)
        XCTAssertEqual(PreviewImageLimits.size(columns: 64, rows: 48).width, 4096)
        XCTAssertEqual(PreviewImageLimits.cellPixels(columns: 200, rows: 100), 20)
        XCTAssertEqual(PreviewImageLimits.cellPixels(columns: 1, rows: 1), 64)
        XCTAssertEqual(PreviewImageLimits.cellPixels(columns: 0, rows: 0), 64)
        let maxBytes = PreviewImageLimits.maxLongEdge * PreviewImageLimits.maxLongEdge * 4
        XCTAssertEqual(maxBytes, 64 * 1024 * 1024, "4096×4096 RGBA = 64 MiB")
        XCTAssertLessThanOrEqual(PreviewImageLimits.rgbaByteCount(columns: 64, rows: 64), maxBytes)
        XCTAssertLessThanOrEqual(PreviewImageLimits.rgbaByteCount(columns: 80, rows: 60), maxBytes)
        XCTAssertLessThanOrEqual(PreviewImageLimits.rgbaByteCount(columns: 120, rows: 90), maxBytes)
    }

    func testNewPreviewIsLargerThanLegacyAtEachDensity() {
        for (c, r) in [(40, 30), (80, 60), (120, 90)] {
            let oldCP = Self.legacyCellPixels(columns: c, rows: r)
            let newCP = PreviewImageLimits.cellPixels(columns: c, rows: r)
            XCTAssertGreaterThan(newCP, oldCP, "\(c)×\(r)")
            XCTAssertLessThanOrEqual(c * newCP, PreviewImageLimits.maxLongEdge)
        }
        XCTAssertEqual(Self.legacyCellPixels(columns: 40, rows: 30), 32)
        XCTAssertEqual(Self.legacyCellPixels(columns: 80, rows: 60), 30)
        XCTAssertEqual(Self.legacyCellPixels(columns: 120, rows: 90), 20)
    }

    func testPreviewRendererOutputSizeFollowsLimits() throws {
        let records = (0..<40).map { i in
            FeatureRecord(vector: FeatureVector(uniform: SIMD3(0.4 + Float(i) * 0.001, 0.02, -0.01)),
                          lightnessVariance: 0.01)
        }
        let table = FeatureTable(records: records)
        let target = try PixelBuffer.solid(width: 160, height: 120, red: 180, green: 40, blue: 50)
        let g = try MosaicPipeline().generate(target: target, density: .custom(columns: 8), table: table, seed: 1)
        let cp = PreviewImageLimits.cellPixels(columns: g.layout.columns, rows: g.layout.rows)
        XCTAssertEqual(cp, 64)
        let img = try PreviewRenderer.render(g, table: table, cellPixels: cp)
        XCTAssertEqual(img.width, g.layout.columns * cp)
        XCTAssertEqual(img.height, g.layout.rows * cp)
        XCTAssertEqual(img.bytes.count, g.layout.columns * g.layout.rows * cp * cp * 4)
    }
}
