// 适配层：feat/gen-perf-fix（f2e4152）之后——生产接线收进 MosaicAppCore 的 `GenerationRunner.production(pipeline:perf:)`。
// 测试直接调同一个工厂；另有守卫确认 App/Adapters/LiveDependencies.swift 确实用的是它（否则测的就不是生产接法）。
import Foundation
import MosaicCore
import MosaicAppCore

enum GenPerfWiring {
    static let label = "GenerationRunner.production"
    static var wiresSharpnessProbe: Bool { productionRunnerHasSharpness }
    private static var productionRunnerHasSharpness: Bool {
        GenerationRunner.production(pipeline: MosaicPipeline(), perf: nil).sharpness != nil
    }
    static func makeRunner(probe: GPProbeLog, perf: PerfRecorder) -> GenerationRunner {
        // 注意：production 不接受探测器参数。如果以后 production 里又接了探测（sharpness != nil），
        // 下面的守卫会红，提醒在 MosaicAppCore 里加可注入探测器的入口（plan §7 J1）。
        GenerationRunner.production(pipeline: MosaicPipeline(), perf: perf)
    }
    static func rematchRounds(_ p: GenerationProduct) -> Int { p.lowRes.rematchRounds }
    static func refilled(_ p: GenerationProduct) -> Bool { p.lowRes.finalFallbackCellCount > 0 }
}

import XCTest

final class GenPerfWiringGuardTests: XCTestCase {
    /// 生产接线必须走 GenerationRunner.production（测试测的就是它）。
    func testLiveDependenciesUsesProductionFactory() throws {
        let url = gpRepoRoot().appendingPathComponent("App/Adapters/LiveDependencies.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let code = src.split(separator: "\n").map { l -> Substring in l.range(of: "//").map { l[..<$0.lowerBound] } ?? l }.joined(separator: "\n")
        XCTAssertTrue(code.contains("generator: GenerationRunner.production("), "LiveDependencies 的 generator 不再用 GenerationRunner.production：性能回归测的不是生产接法")
        XCTAssertFalse(code.contains("LocalResolutionChecker("), "LiveDependencies 又直接接了 LocalResolutionChecker")
    }
    /// production 不接清晰度探测（AndyL 11-16 取消逐张检查）。若以后重新接入，必须先给 QA 可注入的探测器入口。
    func testProductionRunnerHasNoSharpnessProbe() {
        XCTAssertNil(GenerationRunner.production(pipeline: MosaicPipeline(), perf: nil).sharpness)
    }
}
