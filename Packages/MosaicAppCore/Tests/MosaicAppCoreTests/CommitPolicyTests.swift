import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 评审 d6fa750 MF-4：提交频率自适应、首扫提交占空比 ≤ 5%、时间触发也要求 ≥ 300 行。
final class CommitPolicyTests: XCTestCase {
    func testTimedIntervalIsMaxOf8sAnd20xLastCommit() {
        let p = CommitPolicy()
        XCTAssertEqual(p.timedInterval(lastCommitSeconds: 0.1), 8)
        XCTAssertEqual(p.timedInterval(lastCommitSeconds: 0.47), 9.4, accuracy: 1e-9)
        XCTAssertEqual(p.sizeThreshold(tableCount: 500), 1000)
        XCTAssertEqual(p.sizeThreshold(tableCount: 50_000), 5000)
    }

    func testTimedTriggerNeedsAtLeast300Rows() {
        let p = CommitPolicy()
        XCTAssertFalse(p.shouldCommit(uncommitted: 299, tableCount: 90_000, secondsSinceLastCommit: 60, lastCommitSeconds: 0.4, isLastBatch: false))
        XCTAssertTrue(p.shouldCommit(uncommitted: 300, tableCount: 90_000, secondsSinceLastCommit: 60, lastCommitSeconds: 0.4, isLastBatch: false))
        XCTAssertFalse(p.shouldCommit(uncommitted: 5000, tableCount: 90_000, secondsSinceLastCommit: 7.9, lastCommitSeconds: 0.4, isLastBatch: false),
                       "占空比：距上次 < 20 × 0.4 s 不提交，哪怕行数够")
        XCTAssertTrue(p.shouldCommit(uncommitted: 1, tableCount: 0, secondsSinceLastCommit: 0, lastCommitSeconds: 9, isLastBatch: true))
        XCTAssertFalse(p.shouldCommit(uncommitted: 0, tableCount: 0, secondsSinceLastCommit: 100, lastCommitSeconds: 0, isLastBatch: true))
    }

    /// 评审 §1 MF-4 的模拟：10 万张首扫，验收吞吐 111 张/秒，box 实测提交 4.6 µs/行。
    /// 旧规则 112 次、累计重写 56.9× n；新规则须占空比 ≤ 5%、非末次提交都 ≥ 300 行。
    func testSimulated100kFirstScanDutyCycleAtMost5Percent() {
        for (n, rate) in [(100_000, 111.0), (100_000, 300.0), (10_000, 111.0)] {
            let p = CommitPolicy()
            let batch = 300
            var t = 0.0, lastCommitAt = 0.0, lastCost = 0.0, commitTime = 0.0
            var table = 0, pending = 0, commits = 0, rewritten = 0
            var scanned = 0
            while scanned < n {
                let b = min(batch, n - scanned)
                t += Double(b) / rate
                scanned += b
                pending += b
                if p.shouldCommit(uncommitted: pending, tableCount: table, secondsSinceLastCommit: t - lastCommitAt,
                                  lastCommitSeconds: lastCost, isLastBatch: scanned >= n) {
                    if scanned < n { XCTAssertGreaterThanOrEqual(pending, 300) }
                    table += pending
                    pending = 0
                    lastCost = Double(table) * 4.6e-6
                    t += lastCost
                    commitTime += lastCost
                    lastCommitAt = t
                    commits += 1
                    rewritten += table
                }
            }
            let duty = commitTime / t
            XCTAssertLessThanOrEqual(duty, 0.05, "n=\(n) rate=\(rate) duty=\(duty) commits=\(commits)")
            // 占空比是硬约束；累计重写量（写入放大）只记录——它由"间隔 ≥ 20× 提交耗时"间接限住，CPU 占比已 ≤ 5%。
            print(String(format: "[MF-4 sim] n=%d rate=%.0f/s commits=%d rewritten=%.1f×n duty=%.2f%%",
                         n, rate, commits, Double(rewritten) / Double(n), duty * 100))
            XCTAssertLessThanOrEqual(commits, 112, "不多于旧规则（10 万 @111/s 为 112 次）")
        }
    }

    /// PhotoIndex 接入：手动时钟，每张缩略图 0.1 s；行数阈值 1000（不触发）→ 只有时间触发，且每次 ≥ 300 行。
    func testPhotoIndexTimedCommitsRespect300RowsWithManualClock() async throws {
        let manual = ManualClock()
        let perf = PerfRecorder(clock: manual.clock)
        let thumbs = FakeThumbnails(onRequest: { _ in manual.advance(0.1) })
        var c = smallConfig(batch: 50, concurrency: 1, minRows: 1000)
        c.minRowsForTimedCommit = 300
        c.commitDutyFactor = 20
        let store = InMemoryIndexStore()
        let idx = PhotoIndex(store: store, library: FakePhotoLibrary(assetCount: 1000), thumbnails: thumbs,
                             configuration: c, perf: perf)
        await idx.load()
        let summary = try await idx.synchronize()
        XCTAssertEqual(summary.processed, 1000)
        let commits = perf.allSamples().filter { $0.phase == .indexCommit }.map(\.items)
        // scanInProgress 标记(0 行) → 300 → 600 → 900（时间触发，每次 30 s ≥ 8 s）→ 1000（末批）→ 收尾
        XCTAssertEqual(commits, [0, 300, 600, 900, 1000, 1000])
        let scanTotal = try XCTUnwrap(perf.allSamples().first { $0.phase == .scanTotal })
        XCTAssertEqual(scanTotal.note, PerfNote.initialScan)
        XCTAssertNotNil(perf.allSamples().first { $0.phase == .scanCommitTotal })
    }

    /// 提交本身很慢（每次 1 s）⇒ 间隔放大到 20 s，提交次数减少。
    func testSlowCommitsStretchInterval() async throws {
        let manual = ManualClock()
        let perf = PerfRecorder(clock: manual.clock)
        let thumbs = FakeThumbnails(onRequest: { _ in manual.advance(0.1) })
        var c = smallConfig(batch: 50, concurrency: 1, minRows: 100_000)
        c.minRowsForTimedCommit = 300
        c.commitDutyFactor = 20
        let store = SlowStore(inner: InMemoryIndexStore(), advance: { manual.advance(1) })
        let idx = PhotoIndex(store: store, library: FakePhotoLibrary(assetCount: 1000), thumbnails: thumbs,
                             configuration: c, perf: perf, clock: manual.clock)
        await idx.load()
        let s = try await idx.synchronize()
        XCTAssertEqual(s.processed, 1000)
        let commits = perf.allSamples().filter { $0.phase == .indexCommit }.map(\.items)
        // 首个标记提交耗时 1 s ⇒ 间隔 20 s ⇒ 每 200 张时间到但需 ≥ 300 行 → 每 ~300 行一次
        XCTAssertEqual(commits.first, 0)
        for (a, b) in zip(commits.dropFirst(), commits.dropFirst(2)) where b < 1000 { XCTAssertGreaterThanOrEqual(b - a, 300) }
        let commitTotal = try XCTUnwrap(perf.allSamples().first { $0.phase == .scanCommitTotal })
        XCTAssertEqual(commitTotal.seconds, Double(commits.count), accuracy: 1e-9)
    }
}

/// 每次提交推进时钟的包装（模拟慢存储）。
struct SlowStore: IndexStore {
    let inner: InMemoryIndexStore
    let advance: @Sendable () -> Void
    func prepare() throws { try inner.prepare() }
    func load(spec: FeatureSpec) -> IndexStoreLoad { inner.load(spec: spec) }
    func commit(table: FeatureTable, manifest: IndexManifest) throws { advance(); try inner.commit(table: table, manifest: manifest) }
    func discardAll() { inner.discardAll() }
}
