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

    func testMixedLibraryRefreshLeavesUnsettledBytesAndStillOpensSettledWorks() async throws {
        let (dir, images, store) = try await library()
        let ordinary = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let shape = try shapeLayout(source: .preset(.heart), background: .black)
        let text = try shapeLayout(source: .text(lines: ["生日快乐", "宝贝"]), background: .white)
        let shapeSaved = try await store.save(WorkDraft(layout: shape, target: nil, overlayAlpha: 0, origin: .savedManually))
        let textSaved = try await store.save(WorkDraft(layout: text, target: nil, overlayAlpha: 0, origin: .savedManually))
        let migrating = try await store.save(WorkDraft(layout: sampleLayout(["d", "e", "f"], seed: 3), target: nil, overlayAlpha: 0.1, origin: .savedManually))
        try plantPending(ordinary.summary.id, in: dir)
        let metaURL = dir.appendingPathComponent(migrating.summary.id.directoryName).appendingPathComponent("meta.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        object["fallbackFile"] = "fallback-old.jpg"
        try JSONSerialization.data(withJSONObject: object).write(to: metaURL, options: .atomic)
        try Data("old".utf8).write(to: dir.appendingPathComponent(migrating.summary.id.directoryName).appendingPathComponent("fallback-old.jpg"))
        let junk = dir.appendingPathComponent("not-a-work", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: junk.appendingPathComponent("meta.json"))
        let before = try snapshot(dir)
        let controller = WorksController(store: store, existence: FakeExistence(), images: images)
        let exporter = ChainExporter()
        controller.exportHandler = exporter
        await controller.start()
        XCTAssertEqual(try snapshot(dir), before, "冷启动纯读不能改混合库")
        let visible = Set(controller.state.summaries.map(\.id))
        XCTAssertTrue(visible.contains(shapeSaved.summary.id))
        XCTAssertTrue(visible.contains(textSaved.summary.id))
        XCTAssertFalse(visible.contains(ordinary.summary.id), "pending 只让这一份不可用")
        XCTAssertFalse(visible.contains(migrating.summary.id))
        await controller.open(shapeSaved.summary.id)
        XCTAssertEqual(controller.openedWork?.layout.shapeManifest?.spec.source, shape.shapeManifest?.spec.source)
        await controller.exportOpenedTapped(purpose: .share)
        XCTAssertEqual(exporter.layout?.shapeFrame?.background, .black)
        XCTAssertEqual(controller.exportGate, .none)
        XCTAssertEqual(try snapshot(dir), before)
        await controller.open(ordinary.summary.id)
        XCTAssertEqual(controller.state.notice, .worksOpenFailed)
        XCTAssertEqual(try snapshot(dir), before, "打开异常作品也不改它")
        let fresh = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
        let restarted = WorksController(store: fresh, existence: FakeExistence(), images: images)
        restarted.exportHandler = exporter
        await restarted.start()
        XCTAssertEqual(Set(restarted.state.summaries.map(\.id)), visible)
        await restarted.open(textSaved.summary.id)
        XCTAssertEqual(restarted.openedWork?.id, textSaved.summary.id)
        XCTAssertEqual(try snapshot(dir), before, "换进程后的纯读仍然不写旧库")
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

    func testPermissionMissingPhotosDeleteAndChangedStampStayOnTheReadPath() async throws {
        let (dir, images, store) = try await library()
        let photo = try await store.save(WorkDraft(layout: sampleLayout(["a", "b", "c"]), target: nil, overlayAlpha: 0.15, origin: .savedManually))
        let keep = try await store.save(WorkDraft(layout: sampleLayout(["d", "e", "f"], seed: 9), target: nil, overlayAlpha: 0.1, origin: .savedManually))
        let existence = FakeExistence()
        let controller = WorksController(store: store, existence: existence, images: images)
        let exporter = ChainExporter()
        controller.exportHandler = exporter
        await controller.start()
        let before = try snapshot(dir)
        existence.fullAccess.set(false)
        await controller.refreshLibraryAccess()
        await controller.open(photo.summary.id)
        XCTAssertEqual(controller.openedWork?.id, photo.summary.id)
        XCTAssertEqual(controller.state.openedPreviewDisplay, .limitedAccess)
        await controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(controller.exportGate, .needsPermission)
        XCTAssertNil(exporter.layout)
        XCTAssertEqual(try snapshot(dir), before, "权限不足不写作品")
        existence.fullAccess.set(true)
        existence.delete("b")
        await controller.refreshLibraryAccess()
        await controller.exportOpenedTapped(purpose: .share)
        XCTAssertEqual(controller.exportGate, .missingPhotos)
        XCTAssertNil(exporter.layout)
        XCTAssertEqual(try snapshot(dir), before)
        existence.deleted.set([])
        let layoutURL = dir.appendingPathComponent(photo.summary.id.directoryName).appendingPathComponent("layout.json")
        let layoutBytes = try Data(contentsOf: layoutURL)
        let keepBytes = try snapshot(dir.appendingPathComponent(keep.summary.id.directoryName))
        exporter.mutate = layoutURL
        await controller.exportOpenedTapped(purpose: .share)
        XCTAssertEqual(controller.exportGate, .retryBecauseChanged, "导出期间依赖变了就要求重试，不当成强快照")
        XCTAssertNotNil(exporter.layout)
        try layoutBytes.write(to: layoutURL)
        await controller.deleteConfirmed(photo.summary.id)
        XCTAssertFalse(controller.state.summaries.contains { $0.id == photo.summary.id })
        XCTAssertTrue(controller.state.summaries.contains { $0.id == keep.summary.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(photo.summary.id.directoryName).path))
        XCTAssertEqual(try snapshot(dir.appendingPathComponent(keep.summary.id.directoryName)), keepBytes, "删一张不改另一张")
    }

    private func shapeLayout(source: ShapeSource, background: ShapeBackground) throws -> MosaicLayout {
        let mask = try CellMask(columns: 2, rows: 1, bitsV1: [0b0000_0001])
        let manifest = ShapeManifest(spec: ShapeSpec(source: source, palette: .warmRed, background: background), mask: mask)
        return MosaicLayout(cols: 2, rows: 1,
                            cellAssignments: [MosaicLayout.CellAssignment(localIdentifier: "in"),
                                              MosaicLayout.CellAssignment(localIdentifier: "out")],
                            targetSize: .init(width: 8, height: 4),
                            targetCrop: CropRect(x: 0, y: 0, width: 8, height: 4),
                            params: .init(overlayAlpha: 0, density: "fine", seed: 4),
                            shapeFrame: ShapeFrame(background: background, mask: mask),
                            shapeManifest: manifest)
    }

    private func plantPending(_ id: WorkID, in dir: URL) throws {
        let metaURL = dir.appendingPathComponent(id.directoryName).appendingPathComponent("meta.json")
        var meta = try FileWorksStore.decoder().decode(WorkMeta.self, from: Data(contentsOf: metaURL))
        meta.pendingPreviewFile = ".preview-pending-probe.jpg"
        try FileWorksStore.encoder().encode(meta).write(to: metaURL, options: .atomic)
        try Data("pending".utf8).write(to: dir.appendingPathComponent(id.directoryName).appendingPathComponent(".preview-pending-probe.jpg"))
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
    var mutate: URL?
    func exportWork(layout: MosaicLayout, target: PixelBuffer?, fallbacks: [Int: PixelBuffer], purpose: ExportPurpose) async {
        self.layout = layout
        if let mutate, var data = try? Data(contentsOf: mutate) {
            data.append(0)
            try? data.write(to: mutate)
        }
    }
}
