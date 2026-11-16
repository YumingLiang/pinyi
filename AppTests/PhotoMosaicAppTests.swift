import XCTest
import MosaicCore
@testable import PhotoMosaic

/// iOS 模拟器上的冒烟测试：注入的内核与参考实现结果一致。
final class PhotoMosaicAppTests: XCTestCase {
    func testInjectedKernelMatchesReference() throws {
        var rng = SplitMix64(seed: 1)
        let rows = (0..<500).map { _ in (0..<12).map { _ in rng.nextUnitFloat() } }
        let lib = try FeatureMatrix(dimension: 12, rows: rows)
        let queries = try FeatureMatrix(dimension: 12, rows: Array(rows.prefix(20)))
        let injected = try KernelProvider.make().topK(queries: queries, candidates: lib, k: 8)
        let reference = try ScalarSIMDKernel().topK(queries: queries, candidates: lib, k: 8)
        XCTAssertEqual(injected.indices, reference.indices)
    }

    func testAssignmentRunsOnDevice() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        var rng = SplitMix64(seed: 2)
        let lib = try FeatureMatrix(dimension: 12, rows: (0..<300).map { _ in (0..<12).map { _ in rng.nextUnitFloat() } })
        let cells = try FeatureMatrix(dimension: 12, rows: (0..<100).map { _ in (0..<12).map { _ in rng.nextUnitFloat() } })
        let a = try GreedyAssigner(kernel: KernelProvider.make()).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertEqual(a.tiles.count, 100)
    }
}
