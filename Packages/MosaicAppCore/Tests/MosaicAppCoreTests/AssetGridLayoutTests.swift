import XCTest
@testable import MosaicAppCore

/// T4：网格几何、锚点换算、快速滑动判定、变化 → batch / reload 判定。
final class AssetGridLayoutTests: XCTestCase {
    // MARK: 列数 / cell / targetSize

    func testColumnsAndCellSizeOnIPhones() {
        let pm = AssetGridLayout(containerWidth: 440, scale: 3)          // 17 Pro Max
        XCTAssertEqual(pm.columns, 4)
        XCTAssertEqual(pm.cellSide, 108.333, accuracy: 0.001)            // (440 − 6) / 4 = 108.5 → 向下取到 1/3 pt
        XCTAssertLessThanOrEqual(Double(pm.columns) * pm.cellSide + 3 * pm.spacing, 440)
        XCTAssertEqual(pm.targetPixelSize, 325)
        XCTAssertEqual(AssetGridLayout(containerWidth: 375, scale: 2).columns, 4)
        XCTAssertEqual(AssetGridLayout(containerWidth: 320, scale: 2).columns, 3)
        XCTAssertEqual(AssetGridLayout(containerWidth: 1000, scale: 2).columns, 10)
    }

    func testCellSideIsWholePixelsAndRowFits() {
        for w in stride(from: 300.0, through: 460, by: 0.5) {
            for scale in [2.0, 3.0] {
                let l = AssetGridLayout(containerWidth: w, scale: scale)
                XCTAssertEqual((l.cellSide * scale).rounded(), l.cellSide * scale, accuracy: 1e-6)
                XCTAssertLessThan(Double(l.columns) * l.cellSide + Double(l.columns - 1) * l.spacing, w, "严格小于，留浮点余量")
                XCTAssertEqual(l.targetPixelSize, Int((l.cellSide * scale).rounded()))
            }
        }
    }

    func testExactFitGivesUpOnePixel() {
        let e = AssetGridLayout(containerWidth: 430, scale: 3)   // (430 − 6) / 4 = 106 整
        XCTAssertEqual(e.cellSide, 106 - 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(e.targetPixelSize, 317)
    }

    func testDegenerateInputsDoNotCrash() {
        let z = AssetGridLayout(containerWidth: 0, scale: 0)
        XCTAssertEqual(z.columns, AssetGridLayout.minColumns)
        XCTAssertEqual(z.cellSide, 0)
        XCTAssertEqual(z.targetPixelSize, 1)
        XCTAssertEqual(z.itemsPerScreen(viewportHeight: 800), 0)
        XCTAssertEqual(z.visibleRange(visibleTop: 0, viewportHeight: 800, count: 10), 0..<0)
        XCTAssertNil(AssetGridLayout(containerWidth: 400, scale: 3).anchor(visibleTop: 0, count: 0))
    }

    private let l = AssetGridLayout(containerWidth: 405, scale: 2, spacing: 2, minCellSide: 90)  // 4 列，cell 99.5，pitch 101.5

    func testGeometryBasics() {
        XCTAssertEqual(l.columns, 4)
        XCTAssertEqual(l.cellSide, 99.5)
        XCTAssertEqual(l.rowPitch, 101.5)
        XCTAssertEqual(l.rowCount(count: 0), 0)
        XCTAssertEqual(l.rowCount(count: 1), 1)
        XCTAssertEqual(l.rowCount(count: 50_000), 12_500)
        XCTAssertEqual(l.contentHeight(count: 5), 2 * 99.5 + 2)
        XCTAssertEqual(l.minY(ofIndex: 0), 0)
        XCTAssertEqual(l.minY(ofIndex: 3), 0)
        XCTAssertEqual(l.minY(ofIndex: 4), 101.5)
        XCTAssertEqual(l.itemsPerScreen(viewportHeight: 812), 4 * (8 + 1))
    }

    func testVisibleRange() {
        XCTAssertEqual(l.visibleRange(visibleTop: 0, viewportHeight: 101.5, count: 100), 0..<4)
        XCTAssertEqual(l.visibleRange(visibleTop: 0, viewportHeight: 101.6, count: 100), 0..<8)
        // 顶部正好卡在第 0 行的行间距里：第 0 行不可见。
        XCTAssertEqual(l.visibleRange(visibleTop: 100, viewportHeight: 50, count: 100), 4..<8)
        XCTAssertEqual(l.visibleRange(visibleTop: 99, viewportHeight: 50, count: 100), 0..<8)
        // 越过末尾截到 count。
        XCTAssertEqual(l.visibleRange(visibleTop: 0, viewportHeight: 10_000, count: 10), 0..<10)
        // 下拉回弹（负偏移）。
        XCTAssertEqual(l.visibleRange(visibleTop: -80, viewportHeight: 100, count: 100), 0..<4)
        XCTAssertEqual(l.visibleRange(visibleTop: -200, viewportHeight: 100, count: 100), 0..<0)
    }

    // MARK: 锚点

    func testAnchorAtTopAndPartiallyHidden() {
        XCTAssertEqual(l.anchor(visibleTop: 0, count: 100), GridAnchor(index: 0, offset: 0))
        XCTAssertEqual(l.anchor(visibleTop: 30, count: 100), GridAnchor(index: 0, offset: -30))
        let gap = try! XCTUnwrap(l.anchor(visibleTop: 99.6, count: 100))
        XCTAssertEqual(gap.index, 4, "落在行间距 → 下一行")
        XCTAssertEqual(gap.offset, 1.9, accuracy: 1e-9)
        XCTAssertEqual(l.anchor(visibleTop: 101.5 * 10 + 5, count: 100), GridAnchor(index: 40, offset: -5))
        XCTAssertEqual(l.anchor(visibleTop: -40, count: 100), GridAnchor(index: 0, offset: 40), "下拉回弹")
        XCTAssertEqual(l.anchor(visibleTop: 1_000_000, count: 9)?.index, 8, "越过末尾 → 最后一行第一格")
    }

    func testContentOffsetForAnchorAndClamping() {
        let vp = 800.0, top = 100.0, bottom = 34.0, n = 50_000
        XCTAssertEqual(l.contentOffsetY(for: GridAnchor(index: 0, offset: 0), count: n, topInset: top,
                                        bottomInset: bottom, viewportHeight: vp), -top)
        XCTAssertEqual(l.contentOffsetY(for: GridAnchor(index: 401, offset: -12), count: n, topInset: top,
                                        bottomInset: bottom, viewportHeight: vp), 100 * 101.5 + 12 - top)
        // 夹到顶部
        XCTAssertEqual(l.contentOffsetY(for: GridAnchor(index: 0, offset: 50), count: n, topInset: top,
                                        bottomInset: bottom, viewportHeight: vp), -top)
        // 夹到底部
        let maxY = l.contentHeight(count: n) + bottom - vp
        XCTAssertEqual(l.contentOffsetY(for: GridAnchor(index: n - 1, offset: 0), count: n, topInset: top,
                                        bottomInset: bottom, viewportHeight: vp), maxY)
        XCTAssertEqual(l.contentOffsetY(for: GridAnchor(index: n + 100, offset: 0), count: n, topInset: top,
                                        bottomInset: bottom, viewportHeight: vp), maxY, "下标越界按最后一格")
        // 内容不满一屏
        XCTAssertEqual(l.contentOffsetY(for: GridAnchor(index: 3, offset: 0), count: 4, topInset: top,
                                        bottomInset: bottom, viewportHeight: vp), -top)
        XCTAssertEqual(l.contentOffsetY(for: GridAnchor(index: 3, offset: 0), count: 0, topInset: top,
                                        bottomInset: bottom, viewportHeight: vp), -top)
    }

    func testAnchorRoundTripAtManyOffsets() {
        let top = 91.0, bottom = 34.0, vp = 932.0, n = 50_000
        let maxY = l.contentHeight(count: n) + bottom - vp
        for y in stride(from: -top, through: maxY, by: 37.25) {
            let a = try! XCTUnwrap(l.anchor(visibleTop: y + top, count: n))
            XCTAssertEqual(a.index % l.columns, 0)
            XCTAssertGreaterThan(a.offset, -l.cellSide - 1e-9)
            XCTAssertLessThanOrEqual(a.offset, l.spacing + 1e-9)
            let back = l.contentOffsetY(for: a, count: n, topInset: top, bottomInset: bottom, viewportHeight: vp)
            XCTAssertEqual(back, y, accuracy: 1e-6)
        }
    }

    func testAnchorSurvivesColumnChangeWithinOneScreen() {
        // 4 列存的锚点，换成 3 列恢复：锚点格子仍在可见区（误差在一屏内，§3）。
        let four = l, three = AssetGridLayout(containerWidth: 320, scale: 2)
        let vp = 800.0, n = 50_000
        let a = four.anchor(visibleTop: 101.5 * 300 + 20, count: n)!
        let y = three.contentOffsetY(for: a, count: n, topInset: 0, bottomInset: 0, viewportHeight: vp)
        XCTAssertTrue(three.visibleRange(visibleTop: y, viewportHeight: vp, count: n).contains(a.index))
    }

    // MARK: 快速滑动

    func testScrollSpeedMeter() {
        var m = GridScrollSpeedMeter(fastScreensPerSecond: 4)
        XCTAssertFalse(m.sample(offsetY: 0, time: 0, viewportHeight: 800), "第一帧没有速度")
        XCTAssertFalse(m.sample(offsetY: 50, time: 1.0 / 60, viewportHeight: 800), "3.75 屏/秒")
        XCTAssertTrue(m.sample(offsetY: 110, time: 2.0 / 60, viewportHeight: 800), "4.5 屏/秒")
        XCTAssertTrue(m.sample(offsetY: 999, time: 2.0 / 60, viewportHeight: 800), "同一时刻：沿用")
        XCTAssertTrue(m.sample(offsetY: 50, time: 3.0 / 60, viewportHeight: 800), "往上快滑也算（与 110 比，|Δ|=60）")
        XCTAssertFalse(m.sample(offsetY: 51, time: 4.0 / 60, viewportHeight: 800))
        m.stop()
        XCTAssertFalse(m.isFast)
        XCTAssertFalse(m.sample(offsetY: 5000, time: 5.0 / 60, viewportHeight: 800), "stop 后重新起算")
        XCTAssertFalse(m.sample(offsetY: 9000, time: 6.0 / 60, viewportHeight: 0), "视口为 0 不判快")
    }

    // MARK: 变化 → 更新方案

    private func inc(_ r: [Int] = [], _ i: [Int] = [], _ c: [Int] = [], _ m: [AssetGridMove] = []) -> AssetGridChange {
        .incremental(removed: IndexSet(r), inserted: IndexSet(i), changed: IndexSet(c), moves: m)
    }

    func testAppendAtEndIsValidInsert() {
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([], [10]), oldCount: 10, newCount: 11),
                       .batch(deletes: [], inserts: [10], moves: [], reloads: []))
    }

    func testReloadAlwaysReloads() {
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: .reload, oldCount: 10, newCount: 10), .reloadData)
    }

    func testNewPhotosAtTopBecomeInserts() {
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([], [0, 1]), oldCount: 10, newCount: 12),
                       .batch(deletes: [], inserts: [0, 1], moves: [], reloads: []))
    }

    func testHiddenPhotoBecomesDelete() {
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([3]), oldCount: 10, newCount: 9),
                       .batch(deletes: [3], inserts: [], moves: [], reloads: []))
    }

    func testMixedChangeKeepsOrderAndFiltersReloads() {
        let p = AssetGridUpdatePlan.plan(for: inc([5, 7], [0], [0, 2, 4, 9], [AssetGridMove(from: 8, to: 2)]),
                                         oldCount: 10, newCount: 9)
        XCTAssertEqual(p, .batch(deletes: [5, 7], inserts: [0], moves: [AssetGridMove(from: 8, to: 2)], reloads: [4]),
                       "changed 里已插入的 0、移动目标 2、越界的 9 不再 reload")
    }

    func testEmptyIncrementalIsNothing() {
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc(), oldCount: 10, newCount: 10), .nothing)
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([], [], [10]), oldCount: 10, newCount: 10), .nothing)
    }

    func testInconsistentIndicesFallBackToReload() {
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([10]), oldCount: 10, newCount: 9), .reloadData, "删越界")
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([], [11]), oldCount: 10, newCount: 11), .reloadData, "插越界")
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([1]), oldCount: 10, newCount: 10), .reloadData, "数量对不上")
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([], [], [], [AssetGridMove(from: 12, to: 0)]),
                                                oldCount: 10, newCount: 10), .reloadData, "移动越界")
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([1], [], [], [AssetGridMove(from: 1, to: 0)]),
                                                oldCount: 10, newCount: 9), .reloadData, "同一格既删又移")
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([], [], [], [AssetGridMove(from: 1, to: 0),
                                                                       AssetGridMove(from: 2, to: 0)]),
                                                oldCount: 10, newCount: 10), .reloadData, "两次移到同一格")
    }

    func testFirstPhotosIntoEmptyGridOrOffscreenReload() {
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([], [0]), oldCount: 0, newCount: 1), .reloadData)
        XCTAssertEqual(AssetGridUpdatePlan.plan(for: inc([], [0]), oldCount: 5, newCount: 6, isOnScreen: false),
                       .reloadData)
    }

    func testLargeChangeReloads() {
        let p = AssetGridUpdatePlan.plan(for: inc([], Array(0..<301)), oldCount: 1000, newCount: 1301)
        XCTAssertEqual(p, .reloadData)
        let q = AssetGridUpdatePlan.plan(for: inc([], Array(0..<300)), oldCount: 1000, newCount: 1300)
        XCTAssertEqual(q, .batch(deletes: [], inserts: Array(0..<300), moves: [], reloads: []))
    }
}
