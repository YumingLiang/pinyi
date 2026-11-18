import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// MF-6（预览按素材分组、有界并发、不留缓存）与 MF-7（峰值内存、SQLite 触发条件）。
final class PreviewPlanAndMemoryTests: XCTestCase {
    func testMF6GroupsCellsByAssetInFirstSeenOrder() {
        let plan = ThumbnailPreviewPlan(cellAssetIDs: ["b", "a", nil, "b", "c", "a", "b"])
        XCTAssertEqual(plan.groups.map(\.assetID), ["b", "a", "c"])
        XCTAssertEqual(plan.groups[0].cells, [0, 3, 6])
        XCTAssertEqual(plan.groups[1].cells, [1, 5])
        XCTAssertEqual(plan.cellCount, 6)
        XCTAssertEqual(ThumbnailPreviewPlan(cellAssetIDs: [], maxConcurrent: 100).maxConcurrent, 16)
        XCTAssertEqual(ThumbnailPreviewPlan(cellAssetIDs: [], maxConcurrent: 1).maxConcurrent, 8)
    }

    /// 每张素材只取一次；并发 ≤ 上限；同时持有的缩略图 ≤ 一个窗口（画完即丢，不缓存全部）。
    func testMF6EachAssetFetchedOnceWithBoundedConcurrencyAndWindow() async throws {
        let ids: [String?] = (0..<2000).map { "a\($0 % 300)" }
        let plan = ThumbnailPreviewPlan(cellAssetIDs: ids, maxConcurrent: 12)
        let thumbs = FakeThumbnails()
        var drawnCells = 0
        var seen = Set<String>()
        var progressCalls: [Int] = []
        let n = try await plan.run(fetch: { id in await thumbs.thumbnail(for: id, request: .scan) },
                                   progressEvery: 100, progress: { progressCalls.append($0) }) { g, _ in
            XCTAssertTrue(seen.insert(g.assetID).inserted)
            drawnCells += g.cells.count
        }
        XCTAssertEqual(n, 300)
        XCTAssertEqual(drawnCells, 2000)
        XCTAssertEqual(thumbs.state.get().requests, 300, "按素材去重")
        XCTAssertLessThanOrEqual(thumbs.state.get().maxInFlight, 12)
        XCTAssertEqual(progressCalls, [100, 200, 300])
    }

    func testMF6UnavailableThumbnailsAreSkippedAndCancellationThrows() async throws {
        let thumbs = FakeThumbnails()
        thumbs.state.update { $0.unavailable = ["a1"] }
        let plan = ThumbnailPreviewPlan(cellAssetIDs: ["a0", "a1", "a2"])
        let n = try await plan.run(fetch: { await thumbs.thumbnail(for: $0, request: .scan) }) { _, _ in }
        XCTAssertEqual(n, 2)

        let big = ThumbnailPreviewPlan(cellAssetIDs: (0..<500).map { "x\($0)" })
        let task = Task { @MainActor in
            try await big.run(fetch: { id in
                if id == "x20" { withUnsafeCurrentTask { $0?.cancel() } }
                return await thumbs.thumbnail(for: id, request: .scan)
            }) { _, _ in }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("应取消") } catch is CancellationError {}
    }

    func testMF7PeakTrackerRecordsPerPhasePeakAndDelta() {
        let reader = FakeMemory(100)
        let t = PeakMemoryTracker(reader: reader)
        XCTAssertFalse(t.isSampling)
        let scan = t.begin(.scan)
        XCTAssertTrue(t.isSampling)
        reader.set(180); t.sample()
        let gen = t.begin(.generate)
        reader.set(400); t.sample()
        reader.set(250)
        let g = t.end(gen)
        XCTAssertEqual(g?.baselineBytes, 180)
        XCTAssertEqual(g?.peakBytes, 400)
        XCTAssertEqual(g?.deltaBytes, 220)
        let s = t.end(scan)
        XCTAssertEqual(s?.peakBytes, 400)
        XCTAssertEqual(s?.deltaBytes, 300)
        XCTAssertFalse(t.isSampling)
        XCTAssertEqual(t.peakByPhase()[.generate]?.peakBytes, 400)
        XCTAssertNil(t.end(scan), "重复 end 无效")
    }

    func testMF7SQLiteTriggersAndProjection() {
        let mb: UInt64 = 1024 * 1024
        var samples: [PerfSample] = [
            PerfSample(phase: .indexLoad, seconds: 0.2, items: 50_000),     // 外推到 10 万 0.4 s → ok
            PerfSample(phase: .indexCommit, seconds: 0.6, items: 50_000),   // 外推 1.2 s → projectedTrigger
            PerfSample(phase: .scanTotal, seconds: 100, items: 50_000, note: PerfNote.initialScan),
            PerfSample(phase: .scanCommitTotal, seconds: 6, items: 50_000, note: PerfNote.initialScan),  // 6% → triggered
            PerfSample(phase: .libraryDiff, seconds: 2.5, items: 120_000),  // 实测 > 2 s → triggered
        ]
        let memory = [PeakMemorySample(phase: .scan, baselineBytes: 100 * mb, peakBytes: 200 * mb, sampleCount: 5)]
        var checks = Dictionary(uniqueKeysWithValues: SQLiteTriggerCheck.evaluate(samples: samples, memory: memory).map { ($0.metric, $0) })
        XCTAssertEqual(checks[.indexLoad]?.verdict, .ok)
        XCTAssertEqual(checks[.indexLoad]?.at100k ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(checks[.indexCommit]?.verdict, .projectedTrigger)
        XCTAssertEqual(checks[.firstScanCommitShare]?.verdict, .triggered)
        XCTAssertEqual(checks[.indexMemoryDelta]?.verdict, .ok, "100 MB < 150 MB")
        XCTAssertEqual(checks[.fullDiff]?.verdict, .triggered)
        XCTAssertEqual(checks[.fullDiff]?.at100k, 2.5, "≥ 10 万不外推")

        samples.removeAll()
        checks = Dictionary(uniqueKeysWithValues: SQLiteTriggerCheck.evaluate(samples: [], memory: []).map { ($0.metric, $0) })
        XCTAssertTrue(checks.values.allSatisfy { $0.verdict == .noData })
        XCTAssertEqual(checks.count, SQLiteTriggerCheck.Metric.allCases.count)
        XCTAssertTrue(SQLiteTriggerCheck.plainText(Array(checks.values)).hasPrefix("sqlite_trigger\t"))
    }
}

final class FakeMemory: MemoryFootprintReading, Sendable {
    private let v: Locked<UInt64>
    init(_ v: UInt64) { self.v = Locked(v) }
    func set(_ x: UInt64) { v.set(x) }
    func physFootprintBytes() -> UInt64? { v.get() }
}
