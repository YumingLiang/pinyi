import XCTest
import MosaicCore
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

    func testDecisionAfterHighQuality() {
        XCTAssertEqual(ExportFillStats.decision(afterHighQuality: .missing), .blank)
        XCTAssertEqual(ExportFillStats.decision(afterHighQuality: .unavailableLocal), .tryScanDisplay)
        XCTAssertEqual(ExportFillStats.decision(afterHighQuality: .failed), .tryScanDisplay)
        let img = try! PixelBuffer.solid(width: 2, height: 2, red: 1, green: 2, blue: 3)
        XCTAssertEqual(ExportFillStats.decision(afterHighQuality: .image(img)), .highQuality)
    }

    func testFillAfterHighQualitySkipsScanDisplayWhenMissing() {
        XCTAssertEqual(ExportFillStats.fill(afterHighQuality: .missing, scanThumbnail: true), .blank)
        XCTAssertEqual(ExportFillStats.fill(afterHighQuality: .missing, scanThumbnail: false), .blank)
        XCTAssertEqual(ExportFillStats.fill(afterHighQuality: .unavailableLocal, scanThumbnail: true), .blurryFallback)
        XCTAssertEqual(ExportFillStats.fill(afterHighQuality: .unavailableLocal, scanThumbnail: false), .blank)
        XCTAssertEqual(ExportFillStats.fill(afterHighQuality: .failed, scanThumbnail: true), .blurryFallback)
        let img = try! PixelBuffer.solid(width: 2, height: 2, red: 8, green: 8, blue: 8)
        XCTAssertEqual(ExportFillStats.fill(afterHighQuality: .image(img), scanThumbnail: true), .highQuality)
    }

    func testVisibleAssetFilterDropsHiddenAndKeepsOrder() {
        struct Item: Equatable { let id: String; let hidden: Bool }
        let items = [
            Item(id: "a", hidden: false),
            Item(id: "h1", hidden: true),
            Item(id: "b", hidden: false),
            Item(id: "h2", hidden: true),
        ]
        XCTAssertEqual(
            VisibleAssetFilter.accepting(items, isHidden: \.hidden).map(\.id),
            ["a", "b"]
        )
        XCTAssertEqual(VisibleAssetFilter.accepting(items, isHidden: { _ in false }).map(\.id), ["a", "h1", "b", "h2"])
        XCTAssertEqual(VisibleAssetFilter.accepting([Item](), isHidden: \.hidden), [])
    }
}
