import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 控制器上的公开保存链：当前普通照片结果 → 保存 → 列表出现 → 打开这次新作 → 再导出。
/// 不重做底层事务。已有干净作品的字节必须保持不变。
@MainActor
final class OrdinaryPhotoAppChainTests: XCTestCase {
    func testControllerSaveListsOpensAndExportsTheNewPhotoWithoutTouchingTheOldWork() async throws {
        let (dir, images, store) = try await library()
        let old = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let oldBytes = try snapshot(dir.appendingPathComponent(old.summary.id.directoryName))
        let shown = sampleColorLayout(["a", "", "c"], color: CellColor(r: 4, g: 5, b: 6))
        let exporter = ChainExporter()
        let controller = WorksController(store: store, existence: FakeExistence(), images: images,
                                        resultContext: { WorkResultContext(layout: shown, target: nil,
                                                                           overlayAlpha: shown.params.overlayAlpha, tier: nil, resultRevision: 3) })
        controller.exportHandler = exporter
        await controller.refreshFilledPhotoStatus()
        XCTAssertEqual(controller.state.saveStatus, .idle)
        await controller.saveCurrentResultTapped()
        guard case .saved(let id) = controller.state.saveStatus else {
            return XCTFail("保存后按钮应是已保存 \(controller.state.saveStatus)")
        }
        XCTAssertNotEqual(id, old.summary.id)
        XCTAssertTrue(controller.state.summaries.contains { $0.id == id }, "我的作品列表应出现这次新作")
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(old.summary.id.directoryName)), oldBytes, "列表刷新不能改干净的旧作")
        let afterSave = try snapshot(dir.appendingPathComponent(id.directoryName))
        await controller.open(id)
        XCTAssertEqual(controller.openedWork?.id, id)
        XCTAssertEqual(controller.openedWork?.layout.cellAssignments[1].fill, CellColor(r: 4, g: 5, b: 6))
        XCTAssertEqual(controller.openedWork?.layout.cellAssignments[0].localIdentifier, "a")
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(id.directoryName)), afterSave, "打开这次新作不应重画或清它")
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(old.summary.id.directoryName)), oldBytes)
        await controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(exporter.layout?.cellAssignments[1].fill, CellColor(r: 4, g: 5, b: 6))
        XCTAssertEqual(exporter.layout?.cellAssignments[2].localIdentifier, "c")
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(id.directoryName)), afterSave, "再导出不应写回这次新作")
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(old.summary.id.directoryName)), oldBytes)
        let whole = try snapshot(dir)
        await controller.saveCurrentResultTapped()
        XCTAssertEqual(controller.state.saveStatus, .saved(id))
        XCTAssertEqual(try snapshot(dir), whole, "等价再存不写盘")
        XCTAssertEqual(controller.state.summaries.filter { $0.id != old.summary.id }.map(\.id), [id])
    }

    func testRejectedFallbackDoesNotWriteAndMarksTheButtonFailed() async throws {
        let (dir, images, store) = try await library()
        let old = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let oldBytes = try snapshot(dir.appendingPathComponent(old.summary.id.directoryName))
        var shown = sampleColorLayout(["a", "", "c"], color: CellColor(r: 4, g: 5, b: 6))
        shown.cellAssignments[1].fallback = true
        let controller = WorksController(store: store, existence: FakeExistence(), images: images,
                                        resultContext: { WorkResultContext(layout: shown, target: nil,
                                                                           overlayAlpha: shown.params.overlayAlpha, tier: nil, resultRevision: 1) })
        let before = try snapshot(dir)
        await controller.saveCurrentResultTapped()
        XCTAssertEqual(controller.state.saveStatus, .failed)
        XCTAssertEqual(try snapshot(dir), before)
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(old.summary.id.directoryName)), oldBytes)
        XCTAssertFalse(try snapshot(dir).contains(".tmp-fc-new-"))
    }

    private func library() async throws -> (URL, FakeWorkImages, FileWorksStore) {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        return (dir, images, FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider))
    }

    private func snapshot(_ dir: URL) throws -> String {
        let fm = FileManager.default
        guard let names = fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] else { return "" }
        return try names.sorted { $0.path < $1.path }.map { url -> String in
            var isDir: ObjCBool = false
            let rel = url.path.replacingOccurrences(of: dir.path, with: "")
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return "dir \(rel)" }
            let data = try Data(contentsOf: url)
            return "file \(rel) \(data.base64EncodedString())"
        }.joined(separator: "\n")
    }
}

@MainActor
private final class ChainExporter: WorkExportHandling {
    var layout: MosaicLayout?
    func exportWork(layout: MosaicLayout, target: PixelBuffer?, fallbacks: [Int: PixelBuffer], purpose: ExportPurpose) async {
        self.layout = layout
    }
}
