import Foundation
import XCTest
@testable import MosaicAppCore

/// 索引目录排除备份（评审 d6fa750 MF-2、QA B-12）。
///
/// 只在**目录**上设 `isExcludedFromBackup`：原子写会替换文件、文件级属性会丢，目录级不会（Apple 文档：
/// 目录被排除时其内容一并排除）。每次启动 `load()` 前幂等地设一次；运行中目录被删、提交时重建，也补设一次。
/// Darwin 上真实读回 `resourceValues` 的测试在 AppTests（`testIndexDirectoryExcludedFromBackup`）。
final class BackupExclusionTests: XCTestCase {
    var dirs: [URL] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(at: d) }; dirs = [] }

    func makeIndex(_ dir: URL, _ rec: RecordingBackupExclusion, assets: Int = 30) -> PhotoIndex {
        PhotoIndex(directory: dir, library: FakePhotoLibrary(assetCount: assets), thumbnails: FakeThumbnails(),
                   backupExclusion: rec, configuration: smallConfig())
    }

    /// B-12：首启建目录后立即排除备份（目录先创建再设置）。
    func testB12FreshDirectoryExcludedOnLaunch() async throws {
        let dir = makeTempDir().appendingPathComponent("Index", isDirectory: true)
        dirs.append(dir.deletingLastPathComponent())
        let rec = RecordingBackupExclusion()
        let idx = makeIndex(dir, rec)
        _ = await idx.load()
        XCTAssertEqual(rec.names(), ["Index"])
        XCTAssertTrue(rec.calls[0].existed, "目录必须先创建再设置")
    }

    /// B-12：每次启动都重新设置（幂等），不依赖上次是否成功；提交不再逐文件设置。
    func testB12EveryLaunchReappliesOnDirectoryOnly() async throws {
        let dir = makeTempDir(); dirs.append(dir)
        let rec = RecordingBackupExclusion()
        let idx = makeIndex(dir, rec)
        _ = await idx.load()
        _ = try await idx.synchronize()
        XCTAssertEqual(rec.names(), [dir.lastPathComponent], "提交期间目录一直存在，不需要再设")
        for _ in 0..<2 {
            rec.reset()
            let again = makeIndex(dir, rec)
            _ = await again.load()
            XCTAssertEqual(rec.names(), [dir.lastPathComponent], "每次启动设一次目录")
        }
    }

    /// 运行中目录被删：提交时重建目录并补设。
    func testDirectoryRecreatedDuringRunIsExcludedAgain() async throws {
        let dir = makeTempDir().appendingPathComponent("Index", isDirectory: true)
        dirs.append(dir.deletingLastPathComponent())
        let rec = RecordingBackupExclusion()
        let lib = FakePhotoLibrary(assetCount: 10)
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: FakeThumbnails(), backupExclusion: rec,
                             configuration: smallConfig())
        _ = await idx.load()
        try FileManager.default.removeItem(at: dir)
        rec.reset()
        _ = try await idx.synchronize()
        XCTAssertEqual(rec.names().first, "Index")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    /// 设置失败不阻断索引，但计数（性能页 / 诊断可见），下次启动再试。
    func testFailureDoesNotBreakIndexAndIsCounted() async throws {
        let dir = makeTempDir().appendingPathComponent("Index", isDirectory: true)
        dirs.append(dir.deletingLastPathComponent())
        let rec = RecordingBackupExclusion()
        rec.failing = ["Index"]
        let idx = makeIndex(dir, rec, assets: 10)
        _ = await idx.load()
        let summary = try await idx.synchronize()
        XCTAssertEqual(summary.processed, 10)
        let failures = await idx.backupExclusionFailures
        XCTAssertEqual(failures, 1)
        let st = await idx.status()
        XCTAssertEqual(st.available, 10)
    }
}
