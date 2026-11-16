import Foundation
import XCTest
@testable import MosaicCore

/// 性能基线（技术方案 §7：`measure {}`）。
/// 默认规模较小以免拖慢 CI；设置环境变量 `MOSAIC_BENCH=1` 并用
/// `swift test -c release --filter PerformanceTests` 跑方案中的全规模（10,800 格 × 50,000 素材）。
final class PerformanceTests: XCTestCase {
    private var fullScale: Bool { ProcessInfo.processInfo.environment["MOSAIC_BENCH"] == "1" }

    func testTopKPerformanceBaseline() throws {
        let cells = fullScale ? 10_800 : 1_200
        let library = fullScale ? 50_000 : 5_000
        let lib = FeatureMatrix(vectors: syntheticVectors(count: library, seed: 1))
        let queries = FeatureMatrix(vectors: syntheticVectors(count: cells, seed: 2))
        let kernel = ScalarSIMDKernel()
        // swift-corelibs-xctest 不支持 XCTMeasureOptions，用默认 measure（10 次）。
        measure {
            _ = try? kernel.topK(queries: queries, candidates: lib, k: 32)
        }
    }

    func testEndToEndAssignmentTiming() throws {
        let cols = fullScale ? 120 : 40
        let rows = fullScale ? 90 : 30
        let library = fullScale ? 50_000 : 5_000
        let grid = try MosaicGrid(columns: cols, rows: rows)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: library, seed: 3))
        let cells = FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: 4))
        let start = DispatchTime.now().uptimeNanoseconds
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print("[bench] assign \(cols)x\(rows) cells × \(library) candidates: \(String(format: "%.1f", ms)) ms; levels=\(a.statistics.levelCounts); cap=\(a.statistics.resolvedCap.map(String.init) ?? "∞")")
        XCTAssertEqual(neighborhoodViolations(a, .eight), 0)
    }

    /// 最坏情况：整张目标图同一颜色（如大片天空），每格的 128 近邻很快被上限用尽，大量格子走全库搜索。
    func testWorstCaseUniformTargetTiming() throws {
        let cols = fullScale ? 120 : 30
        let rows = fullScale ? 90 : 20
        let library = fullScale ? 50_000 : 3_000
        let grid = try MosaicGrid(columns: cols, rows: rows)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: library, seed: 5))
        let cells = FeatureMatrix(vectors: Array(repeating: FeatureVector(uniform: SIMD3(0.6, 0.02, 0.05)), count: grid.cellCount))
        let start = DispatchTime.now().uptimeNanoseconds
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print("[bench] worst-case uniform \(cols)x\(rows) × \(library): \(String(format: "%.1f", ms)) ms; levels=\(a.statistics.levelCounts)")
        XCTAssertFalse(a.statistics.relaxedConstraints)
    }
}
