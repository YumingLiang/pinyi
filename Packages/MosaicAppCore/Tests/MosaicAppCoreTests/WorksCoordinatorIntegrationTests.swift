import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// AppCoordinator × WorksController：结果页现状、换一种拼法不存、手动存的是当前结果的显式布局。
@MainActor
final class WorksCoordinatorIntegrationTests: XCTestCase {
    private func generated(_ h: CoordinatorHarness) async throws {
        h.coordinator.setTarget(try CoordinatorHarness.target())
        h.coordinator.start()
        await h.coordinator.settle()
        await h.coordinator.generateTapped()
        await h.coordinator.settle()
        guard case .result = h.coordinator.state.flow.generation.phase else { return XCTFail("没有结果") }
    }

    func testResultContextTierFollowsExportTier() async throws {
        let h = CoordinatorHarness(assets: 300)
        try await generated(h)
        XCTAssertEqual(h.coordinator.workResultContext.tier, ExportTier.uhd.rawValue, "默认超清")
        h.coordinator.setExportTier(.hd)
        XCTAssertEqual(h.coordinator.workResultContext.tier, "hd")
        h.coordinator.stop()
    }

    /// 从作品再导出：兜底格的小图经协调器原样交给导出器（`ExportRequest.cellFallbacks`）；结果页导出不带。
    func testWorkExportPassesFallbacksToExporter() async throws {
        let h = CoordinatorHarness(assets: 300)
        try await generated(h)
        let c = h.coordinator
        let layout = sampleFallbackLayout(["a", "", "c"])
        let tile = try PixelBuffer.solid(width: 4, height: 4, red: 1, green: 2, blue: 3)
        await c.export(layout: layout, target: nil, fallbacks: [1: tile], purpose: .share)
        await waitFor(c, "导出完成") { if case .sharing = $0.export { return true } else { return false } }
        XCTAssertEqual(h.exporter.state.get().fallbackCells.last, [1])
        c.shareFinished()
        await c.export(layout: layout, target: nil, purpose: .share)
        await waitFor(c, "导出完成") { if case .sharing = $0.export { return true } else { return false } }
        XCTAssertEqual(h.exporter.state.get().fallbackCells.last, [], "不给就不带")
        c.shareFinished()
        c.stop()
    }

    func testResultContextAndReshuffleDoesNotSave() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        XCTAssertNil(c.workResultContext.layout, "没有结果时没有布局")
        try await generated(h)

        let dir = makeTempDir()
        let images = FakeWorkImages()
        let works = WorksController(store: FileWorksStore(directory: dir, images: images), existence: FakeExistence(),
                                    images: images)
        let relay = ExportSuccessRelay()
        works.attach(resultContext: { [weak c] in c!.workResultContext }, relay: relay)
        await works.start()
        works.resultDidChange(revision: c.state.resultRevision)

        let ctx = c.workResultContext
        let layout = try XCTUnwrap(ctx.layout)
        XCTAssertTrue(layout.isValid)
        XCTAssertNotNil(ctx.target)
        XCTAssertEqual(layout.cellAssignments.map(\.localIdentifier), c.product?.cellAssetIDs.map { $0 ?? "" })

        await works.saveCurrentResultTapped()
        XCTAssertEqual(works.state.count, 1)
        let saved = try await works.store.load(XCTUnwrap(works.state.summaries.first?.id))
        XCTAssertEqual(saved.layout.cellAssignments, layout.cellAssignments, "存的是显式布局，逐格一致")

        // 换一种拼法：新结果，不自动存
        let rev = c.state.resultRevision
        c.send(.reshuffleTapped)
        await c.settle()
        await waitFor(c, "换拼法出结果") { $0.resultRevision > rev }
        works.resultDidChange(revision: c.state.resultRevision)
        XCTAssertEqual(works.state.saveStatus, .idle)
        let count = await works.store.list().count
        XCTAssertEqual(count, 1, "换一种拼法不自动存")
        works.stop()
        c.stop()
    }
}
