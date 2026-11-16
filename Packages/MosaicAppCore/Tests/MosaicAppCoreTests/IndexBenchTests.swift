import Foundation
import XCTest
@testable import MosaicAppCore

/// 索引管线开销基线（fake 缩略图，不含 PhotoKit 解码）：只在 `MOSAIC_BENCH=1` 时运行，只打印不断言。
/// ⚠️ Linux 数字只反映 App 层簿记开销（diff / 提特征 / 提交），不能作为 iPhone 11 首扫 ≤ 90 秒的证据。
final class IndexBenchTests: XCTestCase {
    func testBench10kScan() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MOSAIC_BENCH"] == "1", "设 MOSAIC_BENCH=1 运行")
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let perf = PerfRecorder()
        let idx = PhotoIndex(directory: dir, library: FakePhotoLibrary(assetCount: 10_000), thumbnails: FakeThumbnails(),
                             configuration: PhotoIndex.Configuration(), perf: perf)
        await idx.load()
        let s = try await idx.synchronize()
        let r = perf.report()
        print(String(format: "[bench] index 10k fake scan wall %.0f ms (%.0f 张/秒)", s.wallSeconds * 1000,
                     PerfReport.scanThroughput(processed: s.processed, wallSeconds: s.wallSeconds) ?? 0))
        for row in r.rows {
            print(String(format: "[bench]   %@ n=%d total=%.1f ms median=%.2f ms", row.phase.rawValue as NSString,
                         row.count, row.totalSeconds * 1000, row.medianSeconds * 1000))
        }
        XCTAssertEqual(s.newlyAvailable, 10_000)
    }
}
