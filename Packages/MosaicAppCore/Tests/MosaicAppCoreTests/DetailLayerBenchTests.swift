import Foundation
import XCTest
@testable import MosaicAppCore

/// 清晰层纯逻辑（启用判断 + 取图计划 + 请求差分）每次「手势停下」的耗时。只在 `MOSAIC_BENCH=1` 时运行。
/// PhotoKit 取图、SwiftUI / Core Animation 合成在 Linux 上测不了，要看真机 os_log（category "preview-detail"）和性能页「预览清晰层」。
final class DetailLayerBenchTests: XCTestCase {
    func testBenchSettleLogic() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MOSAIC_BENCH"] == "1", "设 MOSAIC_BENCH=1 运行")
        let viewport = ZoomState.Vector(x: 440, y: 560)
        let cases: [(name: String, columns: Int, rows: Int, scale: Double)] = [
            ("粗 40×30 @6x", 40, 30, 6),
            ("中 80×60 @10x", 80, 60, 10),
            ("细 120×90 @18x", 120, 90, 18),
            ("细 120×90 一格铺满 @120x", 120, 90, 120),
        ]
        for c in cases {
            let aspect: Double = Double(c.columns) / Double(c.rows)
            let fittedH: Double = viewport.x / aspect
            let fitted = ZoomState.Vector(x: viewport.x, y: fittedH)
            let g = DetailGeometry(viewport: viewport, fittedSize: fitted, scale: c.scale, offset: .zero,
                                   displayScale: 3, columns: c.columns, rows: c.rows)
            let ids: [String?] = (0..<(c.columns * c.rows)).map { "asset-\($0 % 300)" }
            let base = PreviewImageLimits.cellPixels(columns: c.columns, rows: c.rows)
            var decision = DetailLayerTrigger.Decision.invalidGeometry
            var plan: DetailLoadPlan?
            let n = 200
            let t0 = Date().timeIntervalSince1970
            for _ in 0..<n {
                decision = DetailLayerTrigger.decide(g, baseCellPixels: base)
                if case .activate(_, _, let tier) = decision {
                    let p = DetailLoadPlan(geometry: g, cellAssetIDs: ids, tier: tier)
                    _ = DetailRequestDiff.diff(inFlight: [], needed: p.items.map(\.assetID), cached: { _ in false })
                    plan = p
                }
            }
            let perCall: Double = (Date().timeIntervalSince1970 - t0) / Double(n)
            print(String(format: "[bench-detail] %@  每格屏幕 %.0f px  可见 %d 格  决定 %@  计划 %d 格 / %d 张  每次 %.3f ms",
                         c.name, g.cellScreenPixels, g.visibleCellCount, "\(decision)",
                         plan?.cellCount ?? 0, plan?.items.count ?? 0, perCall * 1000))
        }
    }
}
