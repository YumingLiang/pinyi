import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

final class PhotoIndexTests: XCTestCase {
    var dirs: [URL] = []
    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }
    func tempDir() -> URL { let d = makeTempDir(); dirs.append(d); return d }

    /// 快照里每个可用行的特征颜色必须对得上该行映射到的资产（行号重映射正确性的强校验）。
    func assertRowsMatchAssets(_ snap: IndexSnapshot, thumbs: FakeThumbnails, file: StaticString = #filePath, line: UInt = #line) {
        let ex = FeatureExtractor()
        let overrides = thumbs.state.get().colorOverride
        for row in 0..<snap.library.table.count where snap.library.mask[row] {
            guard let id = snap.assetIDsByRow[row] else { XCTFail("行 \(row) 无资产", file: file, line: line); continue }
            let c = overrides[id] ?? color(for: id)
            let expected = try! ex.extract(from: PixelBuffer.solid(width: 8, height: 8, red: c.0, green: c.1, blue: c.2))
            let got = snap.library.table.record(row)
            XCTAssertEqual(got.vector, expected.vector, "行 \(row) ↔ \(id)", file: file, line: line)
        }
    }

    func testFreshScanCountsSkipsAndPersists() async throws {
        let dir = tempDir()
        let lib = FakePhotoLibrary(assetCount: 50)
        let thumbs = FakeThumbnails()
        thumbs.state.update { $0.unavailable = ["a3", "a4", "a5", "a6", "a7"]; $0.failing = ["a10", "a11"] }
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        let outcome = await idx.load()
        XCTAssertEqual(outcome, .fresh)
        let progressLog = Locked<[ScanProgress]>([])
        let summary = try await idx.synchronize { p in progressLog.update { $0.append(p) } }
        XCTAssertEqual(summary.added, 50)
        XCTAssertEqual(summary.processed, 50)
        XCTAssertEqual(summary.newlyAvailable, 43)
        XCTAssertEqual(summary.unavailableLocal, 5)
        XCTAssertEqual(summary.failed, 2)
        let st = await idx.status()
        XCTAssertEqual(st.assetTotal, 50)
        XCTAssertEqual(st.available, 43)
        XCTAssertEqual(st.unavailableLocal, 5)
        XCTAssertFalse(st.wasInterrupted)
        XCTAssertTrue(st.hasCompletedInitialScan)
        XCTAssertEqual(progressLog.get().last?.processed, 50)
        XCTAssertEqual(progressLog.get().last?.skippedUnavailable, 5)
        XCTAssertEqual(progressLog.get().map(\.processed), progressLog.get().map(\.processed).sorted(), "进度单调")
        XCTAssertEqual(LibraryEmptyState.completionNotice(st), .scanSkippedUndownloaded)

        // 缩略图请求参数（QA B-08）：128 / aspectFill / fastFormat / 不联网
        let opt = thumbs.state.get().requestedOptions.first!
        XCTAssertEqual(opt.targetPixelSize, 128)
        XCTAssertTrue(opt.aspectFill && opt.fastFormat && opt.fastResize)
        XCTAssertFalse(opt.isNetworkAccessAllowed)
        XCTAssertGreaterThan(thumbs.state.get().cachingStarted, 0)

        // 重新加载：完好、计数一致
        let idx2 = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        let outcome2 = await idx2.load()
        XCTAssertEqual(outcome2, .intact)
        let st2 = await idx2.status()
        XCTAssertEqual(st2.available, 43)
        let snap = try await idx2.snapshot(for: .allPhotos)
        XCTAssertEqual(snap.availableCount, 43)
        assertRowsMatchAssets(snap, thumbs: thumbs)
        // 宽高比来自 PHAsset 像素尺寸（评审 O3）
        XCTAssertEqual(snap.library.table.aspectRatio[0], Float(4032) / 3024, accuracy: 1e-6)
    }

    func testIncrementalAddModifyDeleteWithTombstones() async throws {
        let dir = tempDir()
        let lib = FakePhotoLibrary(assetCount: 40)
        let thumbs = FakeThumbnails()
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        await idx.load()
        _ = try await idx.synchronize()
        let before = await idx.table.count
        XCTAssertEqual(before, 40)

        lib.delete(["a1", "a2", "a3"])
        lib.modify(["a10", "a11"])
        thumbs.state.update { $0.colorOverride["a10"] = (1, 2, 3); $0.colorOverride["a11"] = (250, 240, 230) }
        lib.add(["n1", "n2", "n3", "n4"])
        let s = try await idx.synchronize()
        XCTAssertEqual(s.added, 4)
        XCTAssertEqual(s.modified, 2)
        XCTAssertEqual(s.deleted, 3)
        XCTAssertEqual(s.processed, 6)
        XCTAssertFalse(s.compacted, "5/46 ≈ 11% < 20%，不压缩")
        let t = await idx.table
        XCTAssertEqual(t.count, 46)
        XCTAssertEqual(t.tombstoneCount, 5)
        let st = await idx.status()
        XCTAssertEqual(st.available, 41)
        let snap = try await idx.snapshot(for: .allPhotos)
        XCTAssertEqual(snap.availableCount, 41)
        XCTAssertFalse(snap.assetIDsByRow.contains("a1"))
        assertRowsMatchAssets(snap, thumbs: thumbs)

        // 无变化时 diff 为空、不扫描
        let s2 = try await idx.synchronize()
        XCTAssertEqual(s2.processed, 0)
        XCTAssertEqual(s2.added + s2.modified + s2.deleted, 0)
    }

    func testCompactionRemapsRows() async throws {
        let dir = tempDir()
        let lib = FakePhotoLibrary(assetCount: 30)
        let thumbs = FakeThumbnails()
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        await idx.load()
        _ = try await idx.synchronize()
        lib.delete(Set((0..<10).map { "a\($0 * 2)" }))   // 删 1/3
        lib.add(["z1"])
        let s = try await idx.synchronize()
        XCTAssertTrue(s.compacted)
        let t = await idx.table
        XCTAssertEqual(t.tombstoneCount, 0)
        XCTAssertEqual(t.count, 21)
        let snap = try await idx.snapshot(for: .allPhotos)
        XCTAssertEqual(snap.availableCount, 21)
        assertRowsMatchAssets(snap, thumbs: thumbs)
        // 重启后仍一致
        let idx2 = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        let o = await idx2.load()
        XCTAssertEqual(o, .intact)
        assertRowsMatchAssets(try await idx2.snapshot(for: .allPhotos), thumbs: thumbs)
    }

    func testCancelMidScanKeepsProgressAndResumes() async throws {
        let dir = tempDir()
        let lib = FakePhotoLibrary(assetCount: 120)
        let taskBox = Locked<Task<ScanSummary, Error>?>(nil)
        let thumbs = FakeThumbnails(onRequest: { n in if n == 50 { taskBox.get()?.cancel() } })
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig(batch: 10, concurrency: 2))
        await idx.load()
        let task = Task { try await idx.synchronize() }
        taskBox.set(task)
        do {
            _ = try await task.value
            XCTFail("应被取消")
        } catch is CancellationError {
        } catch { XCTFail("应抛 CancellationError，实际 \(error)") }
        let st = await idx.status()
        XCTAssertTrue(st.wasInterrupted, "下次显示 scan.resume")
        XCTAssertGreaterThanOrEqual(st.available, 40, "已完成的批次保留")
        XCTAssertLessThan(st.available, 120)
        let kept = st.available

        // 模拟被杀：新实例从磁盘加载继续
        let thumbs2 = FakeThumbnails()
        let idx2 = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs2, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig(batch: 10))
        let o = await idx2.load()
        XCTAssertEqual(o, .intact)
        let st2 = await idx2.status()
        XCTAssertEqual(st2.available, kept)
        XCTAssertTrue(st2.wasInterrupted)
        let first = Locked<ScanProgress?>(nil)
        let s = try await idx2.synchronize { p in first.update { if $0 == nil { $0 = p } } }
        XCTAssertEqual(first.get()?.isResuming, true)
        XCTAssertEqual(s.processed, 120 - kept, "只扫剩下的")
        XCTAssertEqual(thumbs2.state.get().requests, 120 - kept)
        let st3 = await idx2.status()
        XCTAssertEqual(st3.available, 120)
        XCTAssertFalse(st3.wasInterrupted)
        assertRowsMatchAssets(try await idx2.snapshot(for: .allPhotos), thumbs: thumbs2)
    }

    func testFeatureVersionChangeDiscardsAndRebuilds() async throws {
        let dir = tempDir()
        let lib = FakePhotoLibrary(assetCount: 12)
        let thumbs = FakeThumbnails()
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        await idx.load()
        _ = try await idx.synchronize()
        // 篡改清单里的特征版本
        let url = dir.appendingPathComponent("index.json")
        var m = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        m["featureVersion"] = 1
        try JSONSerialization.data(withJSONObject: m).write(to: url)
        let idx2 = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        let o = await idx2.load()
        guard case .rebuilt = o else { return XCTFail("应重建，实际 \(o)") }
        let _st1 = await idx2.status()
        XCTAssertEqual(_st1.available, 0)
        let s = try await idx2.synchronize()
        XCTAssertEqual(s.added, 12)
        let _st2 = await idx2.status()
        XCTAssertEqual(_st2.available, 12)
    }

    func testCorruptManifestRebuilds() async throws {
        let dir = tempDir()
        let lib = FakePhotoLibrary(assetCount: 5)
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: FakeThumbnails(), backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        await idx.load()
        _ = try await idx.synchronize()
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("index.json"))
        let idx2 = PhotoIndex(directory: dir, library: lib, thumbnails: FakeThumbnails(), backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        let o = await idx2.load()
        guard case .rebuilt = o else { return XCTFail("\(o)") }
        XCTAssertEqual(featureFiles(in: dir), [], "丢弃重建时删掉所有 features 文件")
    }

    func testOrphanRowsTombstonedOnLoad() async throws {
        // 模拟崩溃在"features.bin 已写、index.json 未写"之间：文件比清单多出若干行。
        let dir = tempDir()
        let lib = FakePhotoLibrary(assetCount: 6)
        let thumbs = FakeThumbnails()
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        await idx.load()
        _ = try await idx.synchronize()
        let t = await idx.table
        let extra = t.appending([t.record(0), t.record(1)])
        try FeatureFile.write(extra, to: try currentFeaturesURL(dir))
        let idx2 = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        await idx2.load()
        let t2 = await idx2.table
        XCTAssertEqual(t2.count, 8)
        XCTAssertEqual(t2.tombstoneCount, 2)
        let snap = try await idx2.snapshot(for: .allPhotos)
        XCTAssertEqual(snap.availableCount, 6)
    }

    func testTruncatedFeatureFileRecoversPrefix() async throws {
        let dir = tempDir()
        let lib = FakePhotoLibrary(assetCount: 400)
        let thumbs = FakeThumbnails()
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig(batch: 100, minRows: 1000))
        await idx.load()
        _ = try await idx.synchronize()
        let url = try currentFeaturesURL(dir)
        let data = try Data(contentsOf: url)
        try data.prefix(data.count - 500).write(to: url)
        let idx2 = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig(batch: 100))
        let o = await idx2.load()
        guard case .recoveredPrefix(let lost) = o else { return XCTFail("\(o)") }
        XCTAssertGreaterThan(lost, 0)
        let st = await idx2.status()
        XCTAssertEqual(st.available + st.pending, 400)
        _ = try await idx2.synchronize()
        let _st3 = await idx2.status()
        XCTAssertEqual(_st3.available, 400)
        assertRowsMatchAssets(try await idx2.snapshot(for: .allPhotos), thumbs: thumbs)
    }

    func testConcurrencyLimitsAndGenerationThrottle() async throws {
        let lib = FakePhotoLibrary(assetCount: 64)
        let thumbs = FakeThumbnails(delayNanos: 2_000_000)
        var cfg = smallConfig(batch: 64, concurrency: 12)
        cfg.concurrencyWhileGenerating = 3
        let idx = PhotoIndex(directory: tempDir(), library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: cfg)
        await idx.load()
        _ = try await idx.synchronize()
        XCTAssertLessThanOrEqual(thumbs.state.get().maxInFlight, 12)
        XCTAssertGreaterThan(thumbs.state.get().maxInFlight, 3)

        let thumbs2 = FakeThumbnails(delayNanos: 2_000_000)
        let idx2 = PhotoIndex(directory: tempDir(), library: lib, thumbnails: thumbs2, backupExclusion: RecordingBackupExclusion(), configuration: cfg)
        await idx2.load()
        await idx2.setGenerationActive(true)
        _ = try await idx2.synchronize()
        XCTAssertLessThanOrEqual(thumbs2.state.get().maxInFlight, 3, "生成期间降并发")
    }

    func testConfigurationClampedToDesignRanges() {
        var c = PhotoIndex.Configuration()
        c.batchSize = 5000
        c.maxConcurrentRequests = 100
        c.concurrencyWhileGenerating = 64
        let s = c.sanitized
        XCTAssertEqual(s.batchSize, 500)
        XCTAssertEqual(s.maxConcurrentRequests, 32)
        XCTAssertEqual(s.concurrencyWhileGenerating, 32)
        XCTAssertFalse(ThumbnailRequest.scan.allowsCachingHighQualityImages)
    }

    func testAlbumSnapshotAndUnreadableAlbum() async throws {
        let lib = FakePhotoLibrary(assetCount: 20)
        lib.setAlbum("baby", title: "宝宝", members: ["a1", "a2", "a3", "a2", "missing"])
        let thumbs = FakeThumbnails()
        thumbs.state.update { $0.unavailable = ["a3"] }
        let idx = PhotoIndex(directory: tempDir(), library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        await idx.load()
        _ = try await idx.synchronize()
        let snap = try await idx.snapshot(for: .album(id: "baby"))
        XCTAssertEqual(snap.availableCount, 2, "去重、只计可用")
        let n = await idx.availableCount(assetIDs: ["a1", "a2", "a3", "a2"])
        XCTAssertEqual(n, 2)
        do {
            _ = try await idx.snapshot(for: .album(id: "nope"))
            XCTFail()
        } catch let e as PhotoIndexError {
            XCTAssertEqual(e, .albumUnreadable)
        }
    }

    func testAllUnavailableYieldsNotDownloadedEmptyState() async throws {
        let lib = FakePhotoLibrary(assetCount: 8)
        let thumbs = FakeThumbnails()
        thumbs.state.update { $0.unavailable = Set((0..<8).map { "a\($0)" }) }
        let idx = PhotoIndex(directory: tempDir(), library: lib, thumbnails: thumbs, backupExclusion: RecordingBackupExclusion(), configuration: smallConfig())
        await idx.load()
        _ = try await idx.synchronize()
        let st = await idx.status()
        XCTAssertEqual(LibraryEmptyState.evaluate(st), .notDownloaded)
        XCTAssertNil(LibraryEmptyState.completionNotice(st))
        // 「重新检查」：照片下载好了 → 全量 diff 会重试 unavailable
        thumbs.state.update { $0.unavailable = [] }
        let s = try await idx.synchronize()
        XCTAssertEqual(s.retried, 8)
        let _st4 = await idx.status()
        XCTAssertEqual(_st4.available, 8)
        let _st5 = await idx.status()
        XCTAssertNil(LibraryEmptyState.evaluate(_st5))
    }

    func testEmptyLibrary() async throws {
        let idx = PhotoIndex(directory: tempDir(), library: FakePhotoLibrary(assetCount: 0), thumbnails: FakeThumbnails(), backupExclusion: RecordingBackupExclusion(),
                             configuration: smallConfig())
        await idx.load()
        let s = try await idx.synchronize()
        XCTAssertEqual(s.processed, 0)
        let _st6 = await idx.status()
        XCTAssertEqual(LibraryEmptyState.evaluate(_st6), .noPhotos)
        let snap = try await idx.snapshot(for: .allPhotos)
        XCTAssertEqual(snap.availableCount, 0)
    }

    func testPerfSamplesRecordedDuringScan() async throws {
        let perf = PerfRecorder()
        let idx = PhotoIndex(directory: tempDir(), library: FakePhotoLibrary(assetCount: 30), thumbnails: FakeThumbnails(), backupExclusion: RecordingBackupExclusion(),
                             configuration: smallConfig(batch: 10), perf: perf)
        await idx.load()
        _ = try await idx.synchronize()
        let r = perf.report()
        XCTAssertEqual(r.row(.thumbnailFetch)?.totalItems, 30)
        XCTAssertEqual(r.row(.thumbnailFetch)?.count, 3)
        XCTAssertNotNil(r.row(.libraryDiff))
        XCTAssertNotNil(r.row(.indexCommit))
        XCTAssertNotNil(r.row(.featureExtract))
    }
}
