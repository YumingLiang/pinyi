import XCTest
@testable import MosaicAppCore

final class ExportFillStatsTests: XCTestCase {
    func testClassifyAndAccumulate() {
        var s = ExportFillStats()
        s.add(.highQuality)
        s.add(.highQuality)
        s.add(.blurryFallback)
        s.add(.blank)
        s.add(ExportFillStats.fill(highQuality: true, scanThumbnail: true))
        s.add(ExportFillStats.fill(highQuality: false, scanThumbnail: true))
        s.add(ExportFillStats.fill(highQuality: false, scanThumbnail: false))
        XCTAssertEqual(s.highQuality, 3)
        XCTAssertEqual(s.blurryFallback, 2)
        XCTAssertEqual(s.blank, 2)
        XCTAssertEqual(s.total, 7)
        XCTAssertEqual(s.logDescription, "糊格子 2 白格子 2")
        XCTAssertFalse(s.logDescription.contains("asset"), "日志不含资产标识")
    }

    func testHighQualityWinsOverScan() {
        XCTAssertEqual(ExportFillStats.fill(highQuality: true, scanThumbnail: true), .highQuality)
        XCTAssertEqual(ExportFillStats.fill(highQuality: true, scanThumbnail: false), .highQuality)
        XCTAssertEqual(ExportFillStats.fill(highQuality: false, scanThumbnail: true), .blurryFallback)
        XCTAssertEqual(ExportFillStats.fill(highQuality: false, scanThumbnail: false), .blank)
    }
}
