import Foundation
import XCTest
@testable import MosaicAppCore

/// T3：网格变化规划、目标图取图状态机、隐藏照片在索引 diff 里表现为删除。
final class GridChangePlannerTests: XCTestCase {
    func testNoIncrementalInfoReloads() {
        XCTAssertEqual(GridChangePlanner.plan(GridChangeDetails(countBefore: 10, countAfter: 10, hasIncrementalChanges: false)),
                       .reload)
    }

    func testSmallDeleteIsIncremental() {
        // 一张照片被设为隐藏：PhotoFetch 结果里消失，changeDetails 里是 removed。
        let d = GridChangeDetails(countBefore: 100, countAfter: 99, hasIncrementalChanges: true, removed: IndexSet([5]))
        XCTAssertEqual(GridChangePlanner.plan(d),
                       .incremental(removed: IndexSet([5]), inserted: IndexSet(), changed: IndexSet(), moves: []))
    }

    func testInsertAtTopAndChange() {
        let d = GridChangeDetails(countBefore: 50, countAfter: 52, hasIncrementalChanges: true,
                                  inserted: IndexSet([0, 1]), changed: IndexSet([10]),
                                  moves: [AssetGridMove(from: 3, to: 7)])
        XCTAssertEqual(GridChangePlanner.plan(d),
                       .incremental(removed: IndexSet(), inserted: IndexSet([0, 1]), changed: IndexSet([10]),
                                    moves: [AssetGridMove(from: 3, to: 7)]))
    }

    func testTooManyChangesReload() {
        let d = GridChangeDetails(countBefore: 10_000, countAfter: 10_000 - 301, hasIncrementalChanges: true,
                                  removed: IndexSet(integersIn: 0..<301))
        XCTAssertEqual(GridChangePlanner.plan(d), .reload)
        // 超过 20 项且超过总数一半
        let half = GridChangeDetails(countBefore: 60, countAfter: 30, hasIncrementalChanges: true,
                                     removed: IndexSet(integersIn: 0..<30))
        XCTAssertEqual(GridChangePlanner.plan(half), .reload)
        // 小相簿删光也做增量（≤ 20 项）
        let small = GridChangeDetails(countBefore: 3, countAfter: 0, hasIncrementalChanges: true,
                                      removed: IndexSet(integersIn: 0..<3))
        XCTAssertEqual(GridChangePlanner.plan(small),
                       .incremental(removed: IndexSet(integersIn: 0..<3), inserted: IndexSet(), changed: IndexSet(), moves: []))
    }

    func testInconsistentCountsReload() {
        XCTAssertEqual(GridChangePlanner.plan(GridChangeDetails(countBefore: 10, countAfter: 10, hasIncrementalChanges: true,
                                                                removed: IndexSet([1]))), .reload, "数对不上")
        XCTAssertEqual(GridChangePlanner.plan(GridChangeDetails(countBefore: 10, countAfter: 9, hasIncrementalChanges: true,
                                                                removed: IndexSet([10]))), .reload, "删除下标越界")
        XCTAssertEqual(GridChangePlanner.plan(GridChangeDetails(countBefore: 10, countAfter: 11, hasIncrementalChanges: true,
                                                                inserted: IndexSet([11]))), .reload, "插入下标越界")
        XCTAssertEqual(GridChangePlanner.plan(GridChangeDetails(countBefore: 10, countAfter: 10, hasIncrementalChanges: true,
                                                                changed: IndexSet([10]))), .reload, "changed 越界")
        XCTAssertEqual(GridChangePlanner.plan(GridChangeDetails(countBefore: 10, countAfter: 10, hasIncrementalChanges: true,
                                                                moves: [AssetGridMove(from: 0, to: 10)])), .reload, "移动越界")
    }

    func testEmptyIncremental() {
        XCTAssertEqual(GridChangePlanner.plan(GridChangeDetails(countBefore: 4, countAfter: 4, hasIncrementalChanges: true)),
                       .incremental(removed: IndexSet(), inserted: IndexSet(), changed: IndexSet(), moves: []))
        XCTAssertEqual(GridChangePlanner.plan(GridChangeDetails(countBefore: 4, countAfter: 5, hasIncrementalChanges: true)),
                       .reload)
    }

    /// 隐藏照片在素材索引里的处理：索引取数走 PhotoFetch，隐藏后它不在 `current` 里 → diff 判为删除。
    func testHiddenPhotoDisappearsAsDeletedInLibraryDiff() {
        var m = IndexManifest(featureVersion: 2)
        m.entries["visible"] = IndexEntry(modificationDate: Date(timeIntervalSince1970: 1), status: .ok, row: 0)
        m.entries["nowHidden"] = IndexEntry(modificationDate: Date(timeIntervalSince1970: 1), status: .ok, row: 1)
        let d = LibraryDiff.compute(manifest: m, current: [AssetMetadata(id: "visible", modificationDate: Date(timeIntervalSince1970: 1))])
        XCTAssertEqual(d.deleted, ["nowHidden"])
        XCTAssertTrue(d.added.isEmpty && d.modified.isEmpty)
    }
}

final class TargetImageFetchMachineTests: XCTestCase {
    typealias M = TargetImageFetchMachine<String>

    private func outcome(_ actions: [TargetImageFetchAction<String>]) -> TargetImageOutcome<String>? {
        for a in actions { if case .finish(let o) = a { return o } }
        return nil
    }

    private func timerToken(_ actions: [TargetImageFetchAction<String>]) -> Int? {
        for a in actions { if case .startTimer(let t, _) = a { return t } }
        return nil
    }

    private func requests(_ actions: [TargetImageFetchAction<String>]) -> [TargetImageRequestKind] {
        actions.compactMap { if case .request(let k) = $0 { return k } else { return nil } }
    }

    private func cancels(_ actions: [TargetImageFetchAction<String>]) -> [TargetImageRequestKind] {
        actions.compactMap { if case .cancelRequest(let k) = $0 { return k } else { return nil } }
    }

    func testHighQualityHitFinishesImmediately() {
        var m = M()
        let a0 = m.start()
        XCTAssertEqual(requests(a0), [.highQuality])
        XCTAssertNotNil(timerToken(a0))
        let o = outcome(m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 4096), image: "hq", from: .highQuality))
        XCTAssertEqual(o?.image, "hq")
        XCTAssertEqual(o?.localLongSide, 4096)
        XCTAssertEqual(o?.reason, .highQuality)
        XCTAssertEqual(o?.usedFallback, false)
        XCTAssertTrue(m.isFinished)
        // 之后的回调、定时器、取消都不再产生动作
        XCTAssertTrue(m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 1), image: "x", from: .highQuality).isEmpty)
        XCTAssertTrue(m.timerFired(token: timerToken(a0)!).isEmpty)
        XCTAssertTrue(m.cancel().isEmpty)
    }

    func testHighQualityDegradedIsAccepted() {
        var m = M()
        _ = m.start()
        let o = outcome(m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 900, isDegraded: true),
                                  image: "deg", from: .highQuality))
        XCTAssertEqual(o?.image, "deg")
        XCTAssertEqual(o?.isDegraded, true)
        XCTAssertEqual(o?.localLongSide, 900)
    }

    func testInCloudNilFallsBackToOpportunisticAndTakesLast() {
        var m = M()
        _ = m.start()
        let a1 = m.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0, isInCloud: true), image: nil, from: .highQuality)
        XCTAssertNil(outcome(a1))
        XCTAssertEqual(requests(a1), [.opportunistic])
        XCTAssertEqual(cancels(a1), [], "highQuality 已回调过，不用取消")
        XCTAssertEqual(m.phase, .opportunistic)
        // 先 degraded
        let a2 = m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 120, isDegraded: true), image: "small", from: .opportunistic)
        XCTAssertNil(outcome(a2))
        XCTAssertNotNil(timerToken(a2), "degraded 后开宽限定时器")
        // 再正式版
        let o = outcome(m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 512), image: "mid", from: .opportunistic))
        XCTAssertEqual(o?.image, "mid")
        XCTAssertEqual(o?.localLongSide, 512)
        XCTAssertEqual(o?.isDegraded, false)
        XCTAssertEqual(o?.reason, .opportunisticFinal)
        XCTAssertEqual(o?.usedFallback, true)
        XCTAssertEqual(o?.sawInCloud, true)
    }

    func testFinalNilKeepsEarlierDegraded() {
        var m = M()
        _ = m.start()
        _ = m.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0, isInCloud: true), image: nil, from: .highQuality)
        _ = m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 120, isDegraded: true), image: "small", from: .opportunistic)
        let o = outcome(m.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0, isInCloud: true), image: nil, from: .opportunistic))
        XCTAssertEqual(o?.image, "small", "正式回调是 nil 时用之前那张 degraded")
        XCTAssertEqual(o?.isDegraded, true)
        XCTAssertEqual(o?.localLongSide, 120)
    }

    func testDegradedOnlyThenGraceTimer() {
        var m = M()
        _ = m.start()
        _ = m.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0), image: nil, from: .highQuality)
        let a = m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 200, isDegraded: true), image: "deg", from: .opportunistic)
        let t = timerToken(a)!
        let fired = m.timerFired(token: t)
        XCTAssertEqual(cancels(fired), [.opportunistic])
        let o = outcome(fired)
        XCTAssertEqual(o?.image, "deg")
        XCTAssertEqual(o?.reason, .opportunisticDegradedOnly)
    }

    func testNothingLocalTimesOutWithNil() {
        var m = M()
        _ = m.start()
        let a = m.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0, hasError: true), image: nil, from: .highQuality)
        let o = outcome(m.timerFired(token: timerToken(a)!))
        XCTAssertNil(o?.image)
        XCTAssertEqual(o?.localLongSide, 0)
        XCTAssertEqual(o?.reason, .noLocalImage)
    }

    func testOpportunisticFinalNilWithoutAnyImage() {
        var m = M()
        _ = m.start()
        _ = m.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0, isInCloud: true), image: nil, from: .highQuality)
        let o = outcome(m.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0, isInCloud: true), image: nil, from: .opportunistic))
        XCTAssertNil(o?.image)
        XCTAssertEqual(o?.reason, .noLocalImage)
    }

    func testHighQualityNeverCallsBack() {
        var m = M()
        let t0 = timerToken(m.start())!
        let a = m.timerFired(token: t0)
        XCTAssertEqual(cancels(a), [.highQuality])
        XCTAssertEqual(requests(a), [.opportunistic])
        // 旧定时器 token 再触发无效
        XCTAssertTrue(m.timerFired(token: t0).isEmpty)
        // 迟到的 highQuality 回调被忽略
        XCTAssertTrue(m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 4096), image: "late", from: .highQuality).isEmpty)
        let o = outcome(m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 300), image: "opp", from: .opportunistic))
        XCTAssertEqual(o?.image, "opp")
    }

    func testStaleGraceTimerIgnoredAfterFinal() {
        var m = M()
        _ = m.start()
        _ = m.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0), image: nil, from: .highQuality)
        let t = timerToken(m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 100, isDegraded: true), image: "d", from: .opportunistic))!
        XCTAssertNotNil(outcome(m.receive(TargetImageCallback(hasImage: true, pixelLongSide: 400), image: "f", from: .opportunistic)))
        XCTAssertTrue(m.timerFired(token: t).isEmpty)
    }

    func testCancelInEachPhase() {
        var idle = M()
        XCTAssertEqual(outcome(idle.cancel())?.reason, .cancelled)
        XCTAssertTrue(idle.start().isEmpty, "取消后不能再开始")

        var hq = M()
        _ = hq.start()
        let a = hq.cancel()
        XCTAssertEqual(cancels(a), [.highQuality])
        XCTAssertEqual(outcome(a)?.reason, .cancelled)
        XCTAssertNil(outcome(a)?.image)

        var opp = M()
        _ = opp.start()
        _ = opp.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0), image: nil, from: .highQuality)
        _ = opp.receive(TargetImageCallback(hasImage: true, pixelLongSide: 100, isDegraded: true), image: "d", from: .opportunistic)
        let b = opp.cancel()
        XCTAssertEqual(cancels(b), [.opportunistic])
        XCTAssertEqual(outcome(b)?.reason, .cancelled)
        XCTAssertNil(outcome(b)?.image, "取消时不交图")
        // 取消后系统回来的 cancelled 回调忽略
        XCTAssertTrue(opp.receive(TargetImageCallback(hasImage: false, pixelLongSide: 0, isCancelled: true), image: nil, from: .opportunistic).isEmpty)
    }

    func testExactlyOneFinishAcrossRandomEventOrders() {
        // 乱序事件下 finish 恰好一次
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var m = M(timing: .init(highQualityTimeout: 1, opportunisticTimeout: 1, degradedGrace: 1))
            var finishes = 0
            var tokens: [Int] = []
            func run(_ a: [TargetImageFetchAction<String>]) {
                for x in a {
                    if case .finish = x { finishes += 1 }
                    if case .startTimer(let t, _) = x { tokens.append(t) }
                }
            }
            run(m.start())
            for _ in 0..<8 {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: run(m.receive(TargetImageCallback(hasImage: Bool.random(using: &rng), pixelLongSide: 100,
                                                          isDegraded: Bool.random(using: &rng)), image: "i", from: .highQuality))
                case 1: run(m.receive(TargetImageCallback(hasImage: Bool.random(using: &rng), pixelLongSide: 100,
                                                          isDegraded: Bool.random(using: &rng)), image: "i", from: .opportunistic))
                case 2: if let t = tokens.randomElement(using: &rng) { run(m.timerFired(token: t)) }
                case 3: if let t = tokens.last { run(m.timerFired(token: t)) }
                default: if Int.random(in: 0..<4, using: &rng) == 0 { run(m.cancel()) }
                }
            }
            // 最后无论如何：最新定时器到点或取消，一定结束
            if let t = tokens.last { run(m.timerFired(token: t)) }
            if let t = tokens.last { run(m.timerFired(token: t)) }
            run(m.cancel())
            XCTAssertEqual(finishes, 1)
            XCTAssertTrue(m.isFinished)
        }
    }
}
