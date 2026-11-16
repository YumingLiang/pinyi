import MosaicCore
import XCTest
@testable import MosaicAppCore

final class InternalToolsTests: XCTestCase {
    func testBuildFlags() {
        XCTAssertTrue(BuildFlags(internalTools: true).showsPerformanceEntryInSettings)
        XCTAssertTrue(BuildFlags(internalTools: true).allowsHiddenPerformanceEntry)
        XCTAssertFalse(BuildFlags(internalTools: false).showsPerformanceEntryInSettings)
        XCTAssertFalse(BuildFlags(internalTools: false).allowsHiddenPerformanceEntry)
    }

    func testPlanBatches() {
        let p = TestAlbumPlan(count: 120, batchSize: 50)
        XCTAssertEqual(p.batches, [0..<50, 50..<100, 100..<120])
        XCTAssertEqual(TestAlbumPlan(count: 0).batches, [])
        XCTAssertEqual(TestAlbumPlan(count: 10_000).batches.count, 200)
        XCTAssertEqual(TestAlbumPlan(count: 10_000).batches.map(\.count).reduce(0, +), 10_000)
    }

    func testPolicyPendingOwnerDecision() {
        XCTAssertFalse(TestAlbumPolicy.ownerApproved, "决定 13 待 AndyL 拍板：默认不允许生成")
        XCTAssertEqual(TestAlbumPolicy.albumTitle, "马赛克测试")
        XCTAssertEqual(TestAlbumPolicy.countOptions, [1_000, 10_000, 50_000])
    }

    func testSyntheticImagesDeterministicAndDiverse() throws {
        let a = SyntheticImage.make(index: 7, size: 32)
        let b = SyntheticImage.make(index: 7, size: 32)
        XCTAssertEqual(a.bytes, b.bytes)
        let ex = FeatureExtractor()
        var features: [FeatureRecord] = []
        for i in 0..<200 { features.append(try ex.extract(from: SyntheticImage.make(index: i, size: 32))) }
        // 不同 index 特征互不相同，且亮度方差非零（不是纯色图）
        XCTAssertEqual(Set(features.map(\.vector)).count, 200)
        XCTAssertTrue(features.allSatisfy { $0.lightnessVariance > 0 })
        // 平均色覆盖面广：L 跨度 > 0.3
        let ls = features.map { $0.vector.meanColor.x }
        XCTAssertGreaterThan(ls.max()! - ls.min()!, 0.3)
    }
}
