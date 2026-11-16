import XCTest
@testable import MosaicCore

/// 网格划分（技术方案 v0.2 §3.6 / 产品决定第 9 条）。
final class LayoutTests: XCTestCase {
    /// 通用断言：cols·s ≈ 长边、rows·s + 裁掉量 ≈ 短边、每侧裁掉 ≤ s/2、格子为正方形、裁切居中。
    private func assertRules(_ w: Int, _ h: Int, _ d: Density, file: StaticString = #filePath, line: UInt = #line) throws -> GridLayout {
        let g = try Layout.grid(width: w, height: h, density: d)
        let n = d.columns
        let landscape = w >= h
        let long = Double(max(w, h)), short = Double(min(w, h))
        let s = g.cellSize
        XCTAssertEqual(s, long / Double(n), accuracy: 1e-9, file: file, line: line)
        let longCount = landscape ? g.columns : g.rows
        let shortCount = landscape ? g.rows : g.columns
        XCTAssertEqual(longCount, n, "长边 = N 格", file: file, line: line)
        XCTAssertEqual(shortCount, max(1, Int((short * Double(n) / long).rounded(.down))), file: file, line: line)
        XCTAssertLessThanOrEqual(g.cellCount, n * n, file: file, line: line)
        XCTAssertEqual(Double(longCount) * s, long, accuracy: 1e-6, "长边不裁", file: file, line: line)
        if !g.shortEdgeUnderflow {
            XCTAssertEqual(Double(shortCount) * s + g.croppedAmount, short, accuracy: 1e-6, file: file, line: line)
            XCTAssertGreaterThanOrEqual(g.croppedAmount, -1e-9, file: file, line: line)
            XCTAssertLessThanOrEqual(g.croppedAmount / 2, s / 2 + 1e-9, "每侧裁掉 ≤ 半格", file: file, line: line)
            let r0 = g.cellRect(0)
            XCTAssertEqual(r0.width, r0.height, accuracy: 1e-9, "正方形格", file: file, line: line)
        }
        // 居中：两侧裁掉量相等。
        let before = landscape ? g.cropRect.y : g.cropRect.x
        let after = landscape ? Double(h) - g.cropRect.y - g.cropRect.height : Double(w) - g.cropRect.x - g.cropRect.width
        XCTAssertEqual(before, after, accuracy: 1e-9, "居中裁切", file: file, line: line)
        return g
    }

    func testFourByThree() throws {
        let g = try assertRules(4000, 3000, .coarse)
        XCTAssertEqual([g.columns, g.rows], [40, 30])
        XCTAssertEqual(g.croppedAmount, 0)  // r 恰为 0
        XCTAssertEqual(try assertRules(4000, 3000, .medium).cellCount, 4800)
        XCTAssertEqual(try assertRules(4000, 3000, .fine).cellCount, 10800)
    }

    func testThreeByFourPortrait() throws {
        let g = try assertRules(3000, 4000, .medium)
        XCTAssertEqual([g.columns, g.rows], [60, 80])
        XCTAssertFalse(g.isLandscape)
    }

    func testSquare() throws {
        let g = try assertRules(1024, 1024, .fine)
        XCTAssertEqual([g.columns, g.rows], [120, 120])
        XCTAssertEqual(g.cellCount, 14_400) // 上界 N×N
    }

    func testSixteenByNine() throws {
        let g = try assertRules(1920, 1080, .medium) // s = 24, M = 45, r = 0
        XCTAssertEqual([g.columns, g.rows], [80, 45])
        XCTAssertEqual(g.croppedAmount, 0)
        let g2 = try assertRules(1920, 1080, .coarse) // s = 48, M = 22, r = 1080 − 1056 = 24
        XCTAssertEqual(g2.rows, 22)
        XCTAssertEqual(g2.croppedAmount, 24, accuracy: 1e-9)
        XCTAssertEqual(g2.cropRect.y, 12, accuracy: 1e-9)
    }

    func testNonIntegerCellSize() throws {
        let g = try assertRules(1000, 777, .fine) // s = 8.333…，M = floor(777×120/1000) = 93
        XCTAssertEqual(g.rows, 93)
        XCTAssertEqual(g.cellSize, 1000.0 / 120.0, accuracy: 1e-12)
        _ = try assertRules(997, 1301, .medium)
        _ = try assertRules(4032, 3024, .fine)   // iPhone 常见 4:3
        _ = try assertRules(3024, 4032, .coarse)
    }

    /// 浮点陷阱：3 ÷ (4/80) = 59.999…，必须得到 60。
    func testNoFloatingPointUnderCount() throws {
        XCTAssertEqual(try Layout.grid(width: 4, height: 3, density: .medium).rows, 60)
        for w in [3, 7, 10, 33, 100, 4000] {
            for d in [Density.coarse, .medium, .fine] {
                _ = try assertRules(w * 4, w * 3, d)
            }
        }
    }

    func testExtremePanorama() throws {
        let g = try assertRules(2000, 100, .coarse) // 20:1, s = 50 → M = 2
        XCTAssertEqual([g.columns, g.rows], [40, 2])
        let g1 = try assertRules(4000, 100, .coarse) // 40:1, s = 100 → M = 1, r = 0
        XCTAssertEqual(g1.rows, 1)
        XCTAssertFalse(g1.shortEdgeUnderflow)
        // 短边不足一格：M 钳为 1，不裁不补（待架构师确认的特例）。
        let g2 = try Layout.grid(width: 3000, height: 50, density: .coarse) // s = 75 > 50
        XCTAssertEqual(g2.rows, 1)
        XCTAssertTrue(g2.shortEdgeUnderflow)
        XCTAssertEqual(g2.cropRect, CropRect(x: 0, y: 0, width: 3000, height: 50))
    }

    func testCellPixelRegionsCoverCropWithoutGapsOrOverflow() throws {
        let g = try Layout.grid(width: 1000, height: 777, density: .coarse) // s = 25, M = 31, 每侧裁 1
        XCTAssertEqual(g.cropRect.y, 1, accuracy: 1e-9)
        var covered = 0
        for i in 0..<g.cellCount {
            let r = g.cellPixelRegion(i)
            XCTAssertTrue(r.width >= 1 && r.height >= 1)
            XCTAssertTrue(r.x >= 0 && r.y >= 0 && r.x + r.width <= 1000 && r.y + r.height <= 777)
            covered += r.width * r.height
        }
        XCTAssertEqual(covered, 1000 * 775) // 裁掉上下各 1 行，其余无缝覆盖
        XCTAssertEqual(g.cellPixelRegion(0), PixelRegion(x: 0, y: 1, width: 25, height: 25))
    }

    func testExportSize() throws {
        let g = try Layout.grid(width: 4032, height: 3024, density: .medium) // 80×60
        let e = g.exportSize(longEdge: 4000)
        XCTAssertEqual(e.cellPixels, 50)
        XCTAssertEqual(e.width, 4000)
        XCTAssertEqual(e.height, 3000)
        let p = try Layout.grid(width: 3024, height: 4032, density: .fine).exportSize(longEdge: 6000) // 90×120
        XCTAssertEqual(p.cellPixels, 50)
        XCTAssertEqual(p.width, 4500)
        XCTAssertEqual(p.height, 6000)
        let odd = try Layout.grid(width: 1000, height: 1000, density: .fine).exportSize(longEdge: 4000) // 4000/120 = 33
        XCTAssertEqual(odd.width, 3960) // 不拉伸，长边向下取整
    }

    func testInvalidSize() {
        XCTAssertThrowsError(try Layout.grid(width: 0, height: 10, density: .coarse))
        XCTAssertThrowsError(try Layout.grid(width: 10, height: -1, density: .coarse))
    }
}
