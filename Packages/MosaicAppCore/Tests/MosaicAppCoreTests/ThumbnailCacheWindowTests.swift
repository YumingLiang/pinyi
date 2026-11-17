import XCTest
@testable import MosaicAppCore

/// T4：缓存窗口（photo-picker-v0.1 §2）：可见区上下各一屏 start；移出两屏外才 stop；快速滑动不扩大。
final class ThumbnailCacheWindowTests: XCTestCase {
    private let screen = 40   // 一屏 40 格
    private let count = 50_000

    private func covered(_ rs: [Range<Int>]) -> Set<Int> { Set(rs.flatMap { Array($0) }) }

    func testFirstUpdateCachesOneScreenEachSideClampedAtTop() {
        var w = ThumbnailCacheWindow()
        let u = w.update(visible: 0..<40, itemsPerScreen: screen, count: count, isFastScrolling: false)
        XCTAssertEqual(u.start, [0..<80])
        XCTAssertEqual(u.stop, [])
        XCTAssertEqual(w.cached, 0..<80)
    }

    func testMiddleWindowIsVisiblePlusMinusOneScreen() {
        var w = ThumbnailCacheWindow()
        let u = w.update(visible: 1000..<1040, itemsPerScreen: screen, count: count, isFastScrolling: false)
        XCTAssertEqual(u.start, [960..<1080])
        XCTAssertEqual(w.cached, 960..<1080)
    }

    func testSmallScrollOnlyStartsNewEdgeAndStopsNothing() {
        var w = ThumbnailCacheWindow()
        _ = w.update(visible: 1000..<1040, itemsPerScreen: screen, count: count, isFastScrolling: false)
        let u = w.update(visible: 1020..<1060, itemsPerScreen: screen, count: count, isFastScrolling: false)
        XCTAssertEqual(u.start, [1080..<1100])
        XCTAssertEqual(u.stop, [], "上边还在两屏内（≥ 940），不 stop")
        XCTAssertEqual(w.cached, 960..<1100)
    }

    func testStopsOnlyBeyondTwoScreens() {
        var w = ThumbnailCacheWindow()
        _ = w.update(visible: 1000..<1040, itemsPerScreen: screen, count: count, isFastScrolling: false)
        // 往下滚 1.5 屏：保留区 = 980..<1140，960..<980 移出两屏。
        let u = w.update(visible: 1060..<1100, itemsPerScreen: screen, count: count, isFastScrolling: false)
        XCTAssertEqual(u.stop, [960..<980])
        XCTAssertEqual(u.start, [1080..<1140])
        XCTAssertEqual(w.cached, 980..<1140)
    }

    func testHysteresisScrollingBackAndForthDoesNotChurn() {
        var w = ThumbnailCacheWindow()
        _ = w.update(visible: 1000..<1040, itemsPerScreen: screen, count: count, isFastScrolling: false)
        _ = w.update(visible: 1020..<1060, itemsPerScreen: screen, count: count, isFastScrolling: false)
        let back = w.update(visible: 1000..<1040, itemsPerScreen: screen, count: count, isFastScrolling: false)
        XCTAssertEqual(back, CacheWindowUpdate(), "回到原位：已缓存的都在两屏内，不 start 也不 stop")
        let again = w.update(visible: 1020..<1060, itemsPerScreen: screen, count: count, isFastScrolling: false)
        XCTAssertEqual(again, CacheWindowUpdate())
    }

    func testJumpFarStopsAllOldAndStartsNew() {
        var w = ThumbnailCacheWindow()
        _ = w.update(visible: 1000..<1040, itemsPerScreen: screen, count: count, isFastScrolling: false)
        let u = w.update(visible: 30_000..<30_040, itemsPerScreen: screen, count: count, isFastScrolling: false)
        XCTAssertEqual(u.stop, [960..<1080])
        XCTAssertEqual(u.start, [29_960..<30_080])
    }

    func testFastScrollingDoesNotExpandBeyondVisible() {
        var w = ThumbnailCacheWindow()
        _ = w.update(visible: 1000..<1040, itemsPerScreen: screen, count: count, isFastScrolling: false)
        // 快速往下：只补可见区，不加前后一屏。
        let u1 = w.update(visible: 1100..<1140, itemsPerScreen: screen, count: count, isFastScrolling: true)
        XCTAssertEqual(u1.start, [1100..<1140])
        XCTAssertEqual(u1.stop, [960..<1080], "旧窗口和可见区之间隔了 1080..<1100：不补空档，窗口只剩可见区")
        XCTAssertEqual(w.cached, 1100..<1140)
        // 快速但相接：两屏内的旧缓存保留，不额外扩。
        let u2 = w.update(visible: 1130..<1170, itemsPerScreen: screen, count: count, isFastScrolling: true)
        XCTAssertEqual(u2.start, [1140..<1170])
        XCTAssertEqual(u2.stop, [])
        XCTAssertEqual(w.cached, 1100..<1170)
        // 连续快速滑：窗口大小不随之变大。
        var maxSize = w.cached.count
        for top in stride(from: 1200, through: 5000, by: 100) {
            _ = w.update(visible: top..<(top + 40), itemsPerScreen: screen, count: count, isFastScrolling: true)
            maxSize = max(maxSize, w.cached.count)
            XCTAssertTrue(w.cached.contains(top) && w.cached.contains(top + 39))
        }
        XCTAssertLessThanOrEqual(maxSize, 5 * screen, "最多 = 保留区（可见 ±2 屏）")
        XCTAssertEqual(w.cached, 5000..<5040, "每步跳 2.5 屏，旧的都在两屏外")
        // 停下来：再扩成 ±1 屏。
        let settle = w.update(visible: 5000..<5040, itemsPerScreen: screen, count: count, isFastScrolling: false)
        XCTAssertEqual(settle.start, [4960..<5000, 5040..<5080])
        XCTAssertEqual(w.cached, 4960..<5080)
    }

    func testStartAndStopNeverOverlapAndMatchCachedDelta() {
        var w = ThumbnailCacheWindow()
        var rng = SystemRandomNumberGenerator()
        var cachedSet = Set<Int>()
        for _ in 0..<500 {
            let n = 300
            let top = Int.random(in: 0..<n, using: &rng)
            let fast = Bool.random(using: &rng)
            let u = w.update(visible: top..<min(n, top + 40), itemsPerScreen: screen, count: n, isFastScrolling: fast)
            let s = covered(u.start), t = covered(u.stop)
            XCTAssertTrue(s.isDisjoint(with: t))
            XCTAssertTrue(s.isDisjoint(with: cachedSet), "不重复 start")
            XCTAssertTrue(t.isSubset(of: cachedSet), "只 stop 已缓存的")
            cachedSet.subtract(t); cachedSet.formUnion(s)
            XCTAssertEqual(cachedSet, Set(w.cached))
            XCTAssertTrue(w.cached.allSatisfy { $0 >= 0 && $0 < n })
            for r in u.start + u.stop { XCTAssertFalse(r.isEmpty) }
        }
    }

    func testClampsToCountAndHandlesEmpty() {
        var w = ThumbnailCacheWindow()
        let u = w.update(visible: 0..<40, itemsPerScreen: screen, count: 10, isFastScrolling: false)
        XCTAssertEqual(u.start, [0..<10])
        XCTAssertEqual(w.cached, 0..<10)
        let empty = w.update(visible: 0..<0, itemsPerScreen: screen, count: 0, isFastScrolling: false)
        XCTAssertEqual(empty.stop, [0..<10])
        XCTAssertEqual(w.cached, 0..<0)
        XCTAssertEqual(w.update(visible: 5..<9, itemsPerScreen: 0, count: 100, isFastScrolling: false).start, [5..<9])
    }

    func testCountShrinkStopsTail() {
        var w = ThumbnailCacheWindow()
        _ = w.update(visible: 40..<80, itemsPerScreen: screen, count: 200, isFastScrolling: false)
        XCTAssertEqual(w.cached, 0..<120)
        let u = w.update(visible: 40..<60, itemsPerScreen: screen, count: 60, isFastScrolling: false)
        XCTAssertEqual(u.stop, [60..<120])
        XCTAssertEqual(w.cached, 0..<60)
    }

    func testResetReturnsCachedAndClears() {
        var w = ThumbnailCacheWindow()
        XCTAssertEqual(w.reset(), CacheWindowUpdate())
        _ = w.update(visible: 100..<140, itemsPerScreen: screen, count: count, isFastScrolling: false)
        XCTAssertEqual(w.reset(), CacheWindowUpdate(stop: [60..<180]))
        XCTAssertEqual(w.cached, 0..<0)
        XCTAssertEqual(w.reset(), CacheWindowUpdate())
    }
}
