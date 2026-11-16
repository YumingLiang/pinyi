import Foundation
import XCTest
@testable import MosaicAppCore

/// 紧急版导出档位 / 降档：总像素 ≤ min(300 MP, 可用内存 ÷ 2 ÷ 4)。
final class ExportPlanTests: XCTestCase {
    func testDefaultTierIsUHD() {
        XCTAssertEqual(ExportTier.default, .uhd)
        XCTAssertEqual(AppState(initialSeed: 1).exportTier, .uhd)
    }

    func testShareCellPixelsIsFloorOfLongEdgeOverCells() {
        XCTAssertEqual(ExportPlan(tier: .share, columns: 40, rows: 30).cellPixels, 100)
        XCTAssertEqual(ExportPlan(tier: .share, columns: 80, rows: 60).cellPixels, 50)
        XCTAssertEqual(ExportPlan(tier: .share, columns: 120, rows: 90).cellPixels, 33)
        XCTAssertEqual(ExportPlan(tier: .share, columns: 120, rows: 90).width, 3_960)
        XCTAssertEqual(ExportPlan(tier: .share, columns: 90, rows: 120).height, 3_960, "竖图按长边格数")
    }

    /// 内存充足（上限 = 300 MP）：粗 / 中 / 细超清 → 256 / 250 / 166。
    /// 注：中档 √(300e6 ÷ 4800) = 250 整，250² × 4800 = 300,000,000 恰好等于上限（≤ 允许），所以是 250 而不是「约 249」。
    func testAmpleMemoryCoarseMediumFine() {
        let big: Int64 = 8_000_000_000
        XCTAssertEqual(ExportPlan(tier: .uhd, columns: 40, rows: 30, availableMemoryBytes: big).cellPixels, 256)
        XCTAssertEqual(ExportPlan(tier: .uhd, columns: 80, rows: 60, availableMemoryBytes: big).cellPixels, 250)
        XCTAssertEqual(ExportPlan(tier: .uhd, columns: 120, rows: 90, availableMemoryBytes: big).cellPixels, 166)
        XCTAssertEqual(ExportPlan(tier: .hd, columns: 120, rows: 90, availableMemoryBytes: big).cellPixels, 160)
        XCTAssertEqual(ExportPlan(tier: .uhd, columns: 120, rows: 90, availableMemoryBytes: big).capPixels, 300_000_000)
        XCTAssertEqual(ExportPlan(tier: .uhd, columns: 120, rows: 90).capPixels, 300_000_000, "未知内存只用静态上限")
    }

    func testTotalPixelsWithinStaticAndDynamicCap() {
        for mem: Int64? in [nil, 8_000_000_000, 2_400_000_000, 1_000_000_000, 300_000_000, 50_000_000] {
            let cap = min(300_000_000, mem.map { $0 / 2 / 4 } ?? 300_000_000)
            for (c, r) in [(40, 30), (30, 40), (80, 60), (60, 80), (120, 90), (90, 120), (40, 40), (120, 1), (400, 300), (1000, 1)] {
                for tier in ExportTier.allCases {
                    let p = ExportPlan(tier: tier, columns: c, rows: r, availableMemoryBytes: mem)
                    XCTAssertEqual(p.capPixels, max(1, cap))
                    XCTAssertGreaterThanOrEqual(p.cellPixels, 1)
                    if p.cellPixels > 1 { XCTAssertLessThanOrEqual(p.totalPixels, cap, "\(tier) \(c)×\(r) mem \(String(describing: mem))") }
                    if let mem, p.cellPixels > 1 { XCTAssertLessThanOrEqual(p.bitmapBytes * 2, mem, "位图 ≤ 可用内存一半") }
                    XCTAssertLessThanOrEqual(max(p.width, p.height), ExportPlan.jpegMaxDimension)
                    XCTAssertEqual(p.cellPixels, max(1, min(p.requestedCellPixels, ExportPlan.maxCellPixels(columns: c, rows: r, maxTotalPixels: p.capPixels))))
                    XCTAssertTrue(tier == .share || p.cellPixels >= (tier == .hd ? 160 : 256) || p.isCapped)
                }
            }
        }
    }

    func testLowMemoryShrinksAutomatically() {
        // 可用 1 GB → 上限 125 MP：细档超清 √(125e6/10800) = 107
        let p = ExportPlan(tier: .uhd, columns: 120, rows: 90, availableMemoryBytes: 1_000_000_000)
        XCTAssertEqual(p.capPixels, 125_000_000)
        XCTAssertEqual(p.cellPixels, 107)
        // 粗档超清在 1 GB 下也降：√(125e6/1200) = 322 → 不降（256）；可用 400 MB → 50 MP → 204
        XCTAssertEqual(ExportPlan(tier: .uhd, columns: 40, rows: 30, availableMemoryBytes: 1_000_000_000).cellPixels, 256)
        XCTAssertEqual(ExportPlan(tier: .uhd, columns: 40, rows: 30, availableMemoryBytes: 400_000_000).cellPixels, 204)
        // 可用内存越小每格越小（单调）
        var last = Int.max
        for mem: Int64 in [4_000_000_000, 2_000_000_000, 1_000_000_000, 500_000_000, 100_000_000, 10_000_000] {
            let c = ExportPlan(tier: .uhd, columns: 120, rows: 90, availableMemoryBytes: mem).cellPixels
            XCTAssertLessThanOrEqual(c, last)
            last = c
        }
        XCTAssertEqual(ExportPlan(tier: .uhd, columns: 120, rows: 90, availableMemoryBytes: 0).cellPixels, 1, "不崩，最少 1 px")
    }

    func testDegenerateInputs() {
        let p = ExportPlan(tier: .uhd, columns: 0, rows: 0, availableMemoryBytes: -5)
        XCTAssertEqual(p.cellPixels, 1)
        XCTAssertFalse(p.logDescription.isEmpty)
    }

    func testTierCopyKeysExist() throws {
        let keys = try L10nKeyTests.stringsKeys()
        for t in ExportTier.allCases {
            XCTAssertTrue(keys.contains(t.titleKey.rawValue))
            XCTAssertTrue(keys.contains(t.descriptionKey.rawValue))
        }
        XCTAssertTrue(keys.contains(L10nKey.exportSizeLargeHint.rawValue))
    }
}
