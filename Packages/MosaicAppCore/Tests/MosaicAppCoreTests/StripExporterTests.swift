import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

/// 假渲染器：每条带填充 strip.index 字节；可在指定条带上停住（gate），可在指定条带抛错。
final class FakeStripRenderer: StripRendering, Sendable {
    let rendered = Locked<[Int]>([])
    let stopAt: Int?
    let gate: GatePoint?
    let failAt: (Int, ExportError)?
    let failCocoaAt: Int?
    init(stopAt: Int? = nil, gate: GatePoint? = nil, failAt: (Int, ExportError)? = nil, failCocoaAt: Int? = nil) {
        self.stopAt = stopAt; self.gate = gate; self.failAt = failAt; self.failCocoaAt = failCocoaAt
    }
    func render(_ strip: ExportStrip, geometry: ExportGeometry, request: ExportRequest) async throws -> Data {
        rendered.update { $0.append(strip.index) }
        if let stopAt, strip.index == stopAt, let gate {
            await gate.reached.open()
            await gate.release.wait()
        }
        if let failAt, failAt.0 == strip.index { throw failAt.1 }
        if let failCocoaAt, failCocoaAt == strip.index { throw CocoaError(.fileWriteOutOfSpace) }
        return Data(repeating: UInt8(truncatingIfNeeded: strip.index), count: geometry.width * strip.pixelHeight * 4)
    }
}

/// 假编码器：把 raw 原样拷到输出，并记录调用次数。
final class CopyEncoder: RasterEncoding, Sendable {
    let calls = Locked(0)
    var fileExtension: String { "jpg" }
    func encode(rawFile: URL, width: Int, height: Int, to output: URL) throws {
        calls.update { $0 += 1 }
        try FileManager.default.copyItem(at: rawFile, to: output)
    }
}

final class StripExporterTests: XCTestCase {
    var dir: URL!
    var indexDir: URL!
    override func setUp() { dir = makeTempDir().appendingPathComponent("export", isDirectory: true); indexDir = makeTempDir() }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: indexDir)
    }

    private func request(longEdge: Int = 1200) async throws -> ExportRequest {
        let idx = PhotoIndex(directory: indexDir, library: FakePhotoLibrary(assetCount: 300), thumbnails: FakeThumbnails(),
                             backupExclusion: RecordingBackupExclusion(), configuration: smallConfig(batch: 100, concurrency: 16, minRows: 1000))
        await idx.load()
        _ = try await idx.synchronize()
        let snap = try await idx.snapshot(for: .allPhotos)
        var bytes = [UInt8](repeating: 200, count: 160 * 120 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i] = UInt8(i % 251) }
        let target = try PixelBuffer(width: 160, height: 120, bytes: bytes)
        let product = try await GenerationRunner().run(target: target, snapshot: snap,
                                                       settings: GenerationSettings(density: .coarse), seed: 3)
        return ExportRequest(product: product, target: target, overlayAlpha: 0.2, longEdge: longEdge)
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// 不假设尺寸上限：长边 1000 → 30000（「高清导出」）都按字节预算切条带，单条带画布 ≤ 预算，Int64 不溢出。
    func testGeometryHasNoSizeCeilingAndBoundedStripMemory() async throws {
        let req = try await request()
        let layout = req.product.generation.layout
        let budget = ExportGeometry.defaultStripByteBudget
        for longEdge in [1_000, 4_000, 6_000, 12_000, 20_000, 30_000] {
            let g = ExportGeometry(layout: layout, longEdge: longEdge)
            XCTAssertLessThanOrEqual(max(g.width, g.height), longEdge)
            XCTAssertGreaterThan(max(g.width, g.height), longEdge - max(layout.columns, layout.rows), "向下取整只损失不到 1 格")
            XCTAssertEqual(g.strips.map(\.pixelHeight).reduce(0, +), g.height, "条带并集 = 整张图")
            XCTAssertEqual(g.strips.map { g.cells(in: $0).count }.reduce(0, +), layout.cellCount)
            let oneRow = Int64(g.width) * 4 * Int64(g.cellPixels)
            XCTAssertLessThanOrEqual(g.peakStripBytes, max(Int64(budget), oneRow), "单条带 ≤ 预算（最少 1 行格子）")
            XCTAssertEqual(g.rawBytes, Int64(g.width) * Int64(g.height) * 4)
            XCTAssertEqual(g.estimatedDiskBytes, g.rawBytes + 2 * g.estimatedEncodedBytes + ExportGeometry.safetyMarginBytes)
        }
        let huge = ExportGeometry(layout: layout, longEdge: 30_000)
        XCTAssertGreaterThan(huge.rawBytes, Int64(Int32.max), "3 万像素的 raw 超过 2 GB，仍正确计算")
        XCTAssertGreaterThan(huge.strips.count, 20, "宽图自动切成更多更矮的条带")
    }

    func testSuccessWritesStripsInOrderEncodesAndRemovesRaw() async throws {
        let req = try await request()
        let renderer = FakeStripRenderer()
        let encoder = CopyEncoder()
        let exporter = StripExporter(directory: dir, renderer: renderer, encoder: encoder, stripByteBudget: 64 * 1024, storage: { nil })
        let fractions = Locked<[Double]>([])
        let url = try await exporter.export(req) { f in fractions.update { $0.append(f) } }
        let g = exporter.geometry(for: req)
        XCTAssertEqual(renderer.rendered.get(), Array(0..<g.strips.count))
        XCTAssertEqual(encoder.calls.get(), 1)
        XCTAssertEqual(files(), [url.lastPathComponent], "raw 暂存文件已删除，只剩输出")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Int64(data.count), g.rawBytes)
        // 第 k 条带的首字节 = k（自上而下顺序写入）
        for s in g.strips { XCTAssertEqual(data[s.pixelRows.lowerBound * g.width * 4], UInt8(truncatingIfNeeded: s.index)) }
        let fs = fractions.get()
        XCTAssertEqual(fs, fs.sorted())
        XCTAssertEqual(fs.last, 1)
        exporter.discard(url)
        XCTAssertEqual(files(), [])
    }

    /// B-34：条带循环取消——取消后不再开始下一条，删掉半截文件，抛 CancellationError，不调编码器。
    func testCancelDuringStripLoopStopsAtNextStripBoundary_B34() async throws {
        let req = try await request()
        let gate = GatePoint()
        let renderer = FakeStripRenderer(stopAt: 1, gate: gate)
        let encoder = CopyEncoder()
        // 小预算 → 条带多，验证流式逐条写盘与条带边界取消
        let exporter = StripExporter(directory: dir, renderer: renderer, encoder: encoder, stripByteBudget: 64 * 1024, storage: { nil })
        XCTAssertGreaterThan(exporter.geometry(for: req).strips.count, 3)
        let task = Task { try await exporter.export(req) { _ in } }
        await gate.reached.wait()
        XCTAssertEqual(files().count, 1, "渲染中只有 raw 暂存文件")
        task.cancel()
        await gate.release.open()
        do {
            _ = try await task.value
            XCTFail("应被取消")
        } catch is CancellationError {}
        XCTAssertEqual(renderer.rendered.get(), [0, 1], "取消后最多完成当前条带，不开始下一条")
        XCTAssertEqual(encoder.calls.get(), 0)
        XCTAssertEqual(files(), [], "半截文件已删除")
    }

    /// 存储预检不足：不渲染、不建文件，抛 insufficientStorage（→ save.disk_full.*）。
    func testStoragePrecheckFailsBeforeRendering_B17() async throws {
        let req = try await request()
        let renderer = FakeStripRenderer()
        let exporter = StripExporter(directory: dir, renderer: renderer, encoder: CopyEncoder(), storage: { 10 })
        do {
            _ = try await exporter.export(req) { _ in }
            XCTFail("应预检失败")
        } catch let e as ExportError { XCTAssertEqual(e, .insufficientStorage) }
        XCTAssertEqual(renderer.rendered.get(), [])
        XCTAssertEqual(files(), [])
        XCTAssertEqual(exporter.estimatedBytes(for: req), exporter.geometry(for: req).estimatedDiskBytes)
    }

    /// 写入中磁盘写满（CocoaError.fileWriteOutOfSpace / ENOSPC）→ insufficientStorage，清理干净。
    func testDiskFullDuringWriteMapsToInsufficientStorage_B17() async throws {
        let req = try await request()
        let exporter = StripExporter(directory: dir, renderer: FakeStripRenderer(failCocoaAt: 1), encoder: CopyEncoder(), stripByteBudget: 64 * 1024, storage: { nil })
        do {
            _ = try await exporter.export(req) { _ in }
            XCTFail()
        } catch let e as ExportError { XCTAssertEqual(e, .insufficientStorage) }
        XCTAssertEqual(files(), [])
        XCTAssertTrue(StoragePrecheck.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertFalse(StoragePrecheck.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    func testOtherFailureMapsToEncodingFailed_B30() async throws {
        let req = try await request()
        let exporter = StripExporter(directory: dir, renderer: FakeStripRenderer(failAt: (0, .encodingFailed)), encoder: CopyEncoder(), storage: { nil })
        do {
            _ = try await exporter.export(req) { _ in }
            XCTFail()
        } catch let e as ExportError { XCTAssertEqual(e, .encodingFailed) }
        XCTAssertEqual(files(), [])
    }

    /// B-27：启动时清空导出目录（上次导出中被杀留下的 raw / 半截文件）。
    func testRemoveStaleExportsClearsDirectory_B27() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: dir.appendingPathComponent("old.rgba").path, contents: Data([1, 2, 3]))
        _ = FileManager.default.createFile(atPath: dir.appendingPathComponent("old.jpg").path, contents: Data([4]))
        StripExporter(directory: dir, renderer: FakeStripRenderer(), encoder: CopyEncoder(), storage: { nil }).removeStaleExports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// 端到端：协调器 + 真实 StripExporter，保存流程写入相册后删除临时文件。
    @MainActor
    func testCoordinatorSaveWithStripExporterLeavesNoTempFiles() async throws {
        let exporter = StripExporter(directory: dir, renderer: FakeStripRenderer(), encoder: CopyEncoder(), storage: { nil })
        let h = CoordinatorHarness(assets: 300, realExporter: exporter)
        h.coordinator.setTarget(try CoordinatorHarness.target())
        h.coordinator.start()
        await h.coordinator.settle()
        await h.coordinator.generateTapped()
        await h.coordinator.settle()
        guard case .result = h.coordinator.state.flow.generation.phase else { return XCTFail("没有结果") }
        await h.coordinator.saveTapped()
        await h.coordinator.settle()
        XCTAssertEqual(h.coordinator.state.export, .saved)
        XCTAssertEqual(h.library.state.get().savedFiles.count, 1)
        XCTAssertEqual(files(), [], "保存后临时文件已删除")
        // 分享：文件留到分享面板关闭
        h.coordinator.shareTapped()
        await h.coordinator.settle()
        guard case .sharing(let url) = h.coordinator.state.export else { return XCTFail("应进入分享") }
        XCTAssertEqual(files(), [url.lastPathComponent])
        h.coordinator.shareFinished()
        XCTAssertEqual(files(), [])
    }

    /// 失败 / 成功 / 打断后的按钮（文案 §4.9–4.10、§5.3 的 key 与动作一一对应）。
    @MainActor
    func testExportResultButtonsFollowCopyKeys_B16_B17_B18_B30() async throws {
        let h = CoordinatorHarness(assets: 300)
        let c = h.coordinator
        let actions = Locked<[SystemAction]>([])
        c.systemActionHandler = { a in actions.update { $0.append(a) } }
        c.setTarget(try CoordinatorHarness.target())
        c.start()
        await c.settle()
        await c.generateTapped()
        await c.settle()

        // 权限被拒：主按钮「去设置」→ openSettings；次按钮「分享」→ 走分享（不需要权限）
        h.library.state.update { $0.addOnlyAuth = .denied }
        await c.saveTapped()
        XCTAssertEqual(c.state.export, .failed(.addDenied))
        XCTAssertEqual(SaveFailure.addDenied.primaryKey, .saveAddDeniedSettings)
        await c.exportFailurePrimaryTapped()
        XCTAssertEqual(actions.get(), [.openSettings])
        XCTAssertEqual(c.state.export, .idle)
        await c.saveTapped()
        c.exportFailureSecondaryTapped()
        await c.settle()
        guard case .sharing = c.state.export else { return XCTFail("次按钮应进入分享") }
        c.shareFinished()

        // 其他失败：「再试一次」按原用途（保存）重来
        h.library.state.update { $0.addOnlyAuth = .authorized }
        h.exporter.state.update { $0.error = .encodingFailed }
        await c.saveTapped()
        await c.settle()
        XCTAssertEqual(c.state.export, .failed(.other))
        XCTAssertEqual(SaveFailure.other.primaryKey, .saveFailedRetry)
        h.exporter.state.update { $0.error = nil }
        await c.exportFailurePrimaryTapped()
        await c.settle()
        XCTAssertEqual(c.state.export, .saved)
        // 保存成功页「分享」
        c.saveSuccessShareTapped()
        await c.settle()
        guard case .sharing = c.state.export else { return XCTFail("成功页分享") }
        c.shareFinished()

        // 空间不足：「我知道了」只关闭
        h.exporter.state.update { $0.available = 1; $0.estimate = 1000 }
        await c.saveTapped()
        XCTAssertEqual(c.state.export, .failed(.diskFull))
        let exportsBefore = h.exporter.state.get().exports
        await c.exportFailurePrimaryTapped()
        XCTAssertEqual(c.state.export, .idle)
        XCTAssertEqual(h.exporter.state.get().exports, exportsBefore)
    }
}
