import Foundation
import XCTest
@testable import MosaicAppCore

/// 结果页预览清晰层的纯逻辑（feat/preview-detail-layer）。PhotoKit 取图和 CG 合成在 App 层，Linux 只做 parse 检查。
final class DetailLayerTests: XCTestCase {
    typealias V = ZoomState.Vector

    /// 390×600 pt 视口、@3x，80×60 网格 scaledToFit：fitted 390×292.5，每格 4.875 pt。
    func geo(scale: Double, offset: V = .zero, columns: Int = 80, rows: Int = 60,
             viewport: V = V(x: 390, y: 600), displayScale: Double = 3) -> DetailGeometry {
        let aspect = Double(columns) / Double(rows)
        let fitted = viewport.x / viewport.y > aspect ? V(x: viewport.y * aspect, y: viewport.y)
                                                      : V(x: viewport.x, y: viewport.x / aspect)
        return DetailGeometry(viewport: viewport, fittedSize: fitted, scale: scale, offset: offset,
                              displayScale: displayScale, columns: columns, rows: rows)
    }

    // MARK: 几何 / 可见格子

    func testScale1ShowsAllCellsCenteredVertically() {
        let g = geo(scale: 1)
        let c = g.contentRect
        XCTAssertEqual(c.x, 0, accuracy: 1e-9)
        XCTAssertEqual(c.width, 1170, accuracy: 1e-9)
        XCTAssertEqual(c.height, 877.5, accuracy: 1e-9)
        let expectedY: Double = 461.25   // (1800 − 877.5) / 2
        XCTAssertEqual(c.y, expectedY, accuracy: 1e-9)
        XCTAssertEqual(g.cellScreenPixels, 14.625, accuracy: 1e-9)
        let r = try! XCTUnwrap(g.visibleRange)
        XCTAssertEqual(r.columns, 0...79)
        XCTAssertEqual(r.rows, 0...59)
        XCTAssertEqual(g.visibleCellCount, 4800)
        XCTAssertEqual(g.viewportPixels.width, 1170)
        XCTAssertEqual(g.viewportPixels.height, 1800)
    }

    func testZoomedCenterVisibleCellsAndRects() {
        // 放大 16 倍：每格 78 pt = 234 px，视口宽 1170 px = 5 格
        let g = geo(scale: 16)
        XCTAssertEqual(g.cellScreenPixels, 234, accuracy: 1e-9)
        let r = try! XCTUnwrap(g.visibleRange)
        // 内容中心 = 视口中心：列 40 的左边缘正好在中心 585 px
        XCTAssertEqual(g.cellRect(column: 40, row: 30).x, 585, accuracy: 1e-6)
        XCTAssertEqual(g.cellRect(column: 40, row: 30).y, 900, accuracy: 1e-6)
        // 585 / 234 = 2.5 格 → 左边可见到列 37（部分），右边到列 42（部分）
        XCTAssertEqual(r.columns, 37...42)
        // 900 / 234 = 3.85 → 行 26...33
        XCTAssertEqual(r.rows, 26...33)
        // 每个可见格子都和视口相交，范围外一格都不相交
        for col in (r.columns.lowerBound - 1)...(r.columns.upperBound + 1) {
            let rect = g.cellRect(column: col, row: 30)
            let intersects = rect.maxX > 0 && rect.x < 1170
            XCTAssertEqual(intersects, r.columns.contains(col), "col \(col)")
        }
    }

    func testOffsetShiftsVisibleRangeAndEdgeOnGridLine() {
        // 平移到最左：offset.x = (fitted × scale − viewport) / 2
        let scale = 8.0
        let fittedW = 390.0
        let contentW: Double = fittedW * scale
        let offX: Double = (contentW - 390) / 2
        let g = geo(scale: scale, offset: V(x: offX, y: 0))
        XCTAssertEqual(g.contentRect.x, 0, accuracy: 1e-6)
        let r = try! XCTUnwrap(g.visibleRange)
        XCTAssertEqual(r.columns.lowerBound, 0)
        // 每格 39 pt，视口 390 pt 正好 10 格：右边缘落在格线上，不算第 11 格
        XCTAssertEqual(r.columns, 0...9)
    }

    func testVisibleRangeNilWhenContentOffscreenOrInvalid() {
        XCTAssertNil(geo(scale: 2, offset: V(x: 5000, y: 0)).visibleRange)
        XCTAssertNil(geo(scale: 2, columns: 0).visibleRange)
        XCTAssertNil(DetailGeometry(viewport: .zero, fittedSize: .zero, scale: 1, offset: .zero,
                                    displayScale: 3, columns: 10, rows: 10).visibleRange)
        XCTAssertFalse(geo(scale: .nan).isValid)
    }

    func testCenterOutOrderStartsAtCenterAndCoversAll() {
        let g = geo(scale: 16)
        let cells = g.visibleCellsCenterOut()
        XCTAssertEqual(cells.count, g.visibleCellCount)
        XCTAssertEqual(Set(cells).count, cells.count)
        // 视口中心 (585, 900) 是列 40 / 行 30 的左上角，最近的四格之一排第一
        let nearest: [Int] = [2439, 2440, 2359, 2360]   // 行 29/30 × 列 39/40
        XCTAssertTrue(nearest.contains(cells[0]))
        // 角上的格子排在后面
        let r = g.visibleRange!
        let corner = r.rows.lowerBound * 80 + r.columns.lowerBound
        XCTAssertGreaterThan(cells.firstIndex(of: corner)!, cells.count / 2)
    }

    func testGeometryFromZoomStateMatchesContainer() {
        var z = ZoomState()
        let vp = V(x: 390, y: 600)
        z.updateLayout(viewport: vp, fittedSize: V(x: 390, y: 292.5), columns: 80, rows: 60)
        z.pinchChanged(4)
        z.pinchEnded()
        z.panChanged(V(x: 100, y: -50))
        z.panEnded()
        let g = DetailGeometry(zoom: z, displayScale: 3, columns: 80, rows: 60)
        XCTAssertEqual(g.scale, 4, accuracy: 1e-9)
        XCTAssertEqual(g.offset, z.offset)
        // 视口中心对应的内容点：(viewport/2 − offset) 相对内容中心
        let c = g.contentRect
        let halfContent: Double = 780        // 390 × 4 / 2
        let originPt: Double = 195 - halfContent + z.offset.x
        let expectedX: Double = originPt * 3
        XCTAssertEqual(c.x, expectedX, accuracy: 1e-6)
    }

    func testRingExpansionClampedToGrid() {
        let g = geo(scale: 16)
        let r = g.visibleRange(ring: 1)!
        XCTAssertEqual(r.columns, 36...43)
        XCTAssertEqual(r.rows, 25...34)
        XCTAssertEqual(g.visibleRange(ring: 0)!.columns, g.visibleRange!.columns)
        // 平移到最左上角：外扩不越过 0
        let maxOffX: Double = 2925           // (390 × 16 − 390) / 2
        let maxOffY: Double = 2040           // (292.5 × 16 − 600) / 2
        let corner = geo(scale: 16, offset: V(x: maxOffX, y: maxOffY))
        let rc = corner.visibleRange(ring: 1)!
        XCTAssertEqual(rc.columns.lowerBound, 0)
        XCTAssertEqual(rc.rows.lowerBound, 0)
        XCTAssertEqual(corner.visibleRange!.columns.upperBound + 1, rc.columns.upperBound)
        // 1 倍看全图：外扩后仍是整个网格
        XCTAssertEqual(geo(scale: 1).visibleRange(ring: 1)!.columns, 0...79)
        // 外扩圈排在可见格子之后
        let all = g.cellsCenterOut(ring: 1)
        XCTAssertEqual(all.count, 8 * 10)
        XCTAssertEqual(Set(all.prefix(g.visibleCellCount)), Set(g.visibleCellsCenterOut()))
    }

    func testUnscaledCellFrameMatchesScaledRect() {
        // scaleEffect 之内的摆放，经 (viewport/2 + (p − viewport/2) × scale + offset) × displayScale 变换后
        // 必须和 cellRect 一致
        let g = geo(scale: 7, offset: V(x: 120, y: -40))
        for (col, row) in [(0, 0), (40, 30), (79, 59), (13, 51)] {
            let f = g.unscaledCellFrame(column: col, row: row)
            let r = g.cellRect(column: col, row: row)
            let dxPt: Double = (f.centerX - 195) * 7
            let dyPt: Double = (f.centerY - 300) * 7
            let sxPt: Double = 195 + dxPt + 120
            let syPt: Double = 300 + dyPt - 40
            let sx: Double = sxPt * 3
            let sy: Double = syPt * 3
            XCTAssertEqual(sx, r.x + r.width / 2, accuracy: 1e-6)
            XCTAssertEqual(sy, r.y + r.height / 2, accuracy: 1e-6)
            let scaledW: Double = f.width * 21
            XCTAssertEqual(scaledW, r.width, accuracy: 1e-6)
            XCTAssertEqual(f.width, f.height, accuracy: 1e-9)   // 方格，不拉伸
        }
    }

    // MARK: 档位

    func testTierByVisibleCellCount() {
        XCTAssertEqual(DetailTier.select(visibleCells: 1), .p1024)
        XCTAssertEqual(DetailTier.select(visibleCells: 4), .p1024)
        XCTAssertEqual(DetailTier.select(visibleCells: 5), .p512)
        XCTAssertEqual(DetailTier.select(visibleCells: 64), .p512)
        XCTAssertEqual(DetailTier.select(visibleCells: 65), .p256)
        XCTAssertEqual(DetailTier.select(visibleCells: 300), .p256)
        XCTAssertEqual(DetailTier.select(visibleCells: 0), .p1024)
        XCTAssertEqual(DetailTier.p256.byteCost, 262_144)
        XCTAssertEqual(DetailTier.p1024.byteCost, 4 * 1_048_576)
    }

    // MARK: 启用条件

    func testTriggerNeedsGainOverBase() {
        let base = PreviewImageLimits.cellPixels(columns: 40, rows: 30)   // 64
        // 40 列 @1x：每格 9.75 pt × 3 = 29 px → 底图够用
        XCTAssertEqual(DetailLayerTrigger.decide(geo(scale: 1, columns: 40, rows: 30), baseCellPixels: base),
                       .baseIsSharpEnough)
        // @3x：87.75 px ≤ 96 → 不启用；@4x：117 px > 96 → 启用
        XCTAssertEqual(DetailLayerTrigger.decide(geo(scale: 3, columns: 40, rows: 30), baseCellPixels: base),
                       .baseIsSharpEnough)
        guard case .activate(_, _, let tier) = DetailLayerTrigger.decide(geo(scale: 4, columns: 40, rows: 30),
                                                                          baseCellPixels: base) else {
            return XCTFail("应启用")
        }
        XCTAssertEqual(tier, .p256)   // 可见约 10×16 = 160 格
    }

    func testTriggerActivateRangeIsRingExpandedAndTierByCount() {
        let g = geo(scale: 16)   // 可见 6×8 = 48 格
        XCTAssertEqual(g.visibleCellCount, 48)
        XCTAssertEqual(DetailLayerTrigger.decide(g, baseCellPixels: 64),
                       .activate(columns: 36...43, rows: 25...34, tier: .p512))
        // 一格铺满屏幕
        let one = geo(scale: 80)
        XCTAssertLessThanOrEqual(one.visibleCellCount, 4)
        guard case .activate(_, _, let t) = DetailLayerTrigger.decide(one, baseCellPixels: 64) else { return XCTFail() }
        XCTAssertEqual(t, .p1024)
    }

    func testTriggerTooManyCellsAndInvalid() {
        // 细档 120×90，底图每格 34 px：@4x 每格 39 px 不够；@6x 58.5 px > 51，可见约 600 格，上限 960 下应启用。
        let base = PreviewImageLimits.cellPixels(columns: 120, rows: 90)
        XCTAssertEqual(DetailLayerTrigger.decide(geo(scale: 4, columns: 120, rows: 90), baseCellPixels: base),
                       .baseIsSharpEnough)
        guard case .activate(_, _, let tier) = DetailLayerTrigger.decide(geo(scale: 6, columns: 120, rows: 90),
                                                                          baseCellPixels: base) else {
            return XCTFail("细档 6x 可见约 600 格，应启用清晰层")
        }
        XCTAssertEqual(tier, .p256)
        // 上限本身仍然生效（自定义 300 时，600 格走 tooManyCells）
        var tight = DetailLayerPolicy.standard
        tight.maxVisibleCells = 300
        XCTAssertEqual(DetailLayerTrigger.decide(geo(scale: 6, columns: 120, rows: 90), baseCellPixels: base, policy: tight),
                       .tooManyCells)
        XCTAssertEqual(DetailLayerTrigger.decide(geo(scale: 16, columns: 0), baseCellPixels: 64), .invalidGeometry)
        XCTAssertEqual(DetailLayerTrigger.decide(geo(scale: 2, offset: V(x: 5000, y: 0)), baseCellPixels: 64),
                       .invalidGeometry)
    }

    // MARK: 状态机：手势结束 150 ms 后更新、代次作废、清空

    func testDebounceOnlyLatestGenerationUpdates() {
        var s = DetailLayerState()
        for i in 1...10 { XCTAssertEqual(s.zoomChanged(), [.scheduleSettle(generation: i, delay: 0.15)]) }
        for g in 1..<10 { XCTAssertEqual(s.settled(generation: g, geometry: geo(scale: 16), baseCellPixels: 64), []) }
        XCTAssertEqual(s.settled(generation: 10, geometry: geo(scale: 16), baseCellPixels: 64),
                       [.update(columns: 36...43, rows: 25...34, tier: .p512)])
        XCTAssertTrue(s.isActive)
        // 同一代次重复到点、或集合没变：不重复更新
        XCTAssertEqual(s.settled(generation: 10, geometry: geo(scale: 16), baseCellPixels: 64), [])
        _ = s.zoomChanged()
        XCTAssertEqual(s.settled(generation: 11, geometry: geo(scale: 16), baseCellPixels: 64), [])
    }

    func testPanChangesSetAndZoomOutClears() {
        var s = DetailLayerState()
        _ = s.zoomChanged()
        _ = s.settled(generation: 1, geometry: geo(scale: 16), baseCellPixels: 64)
        _ = s.zoomChanged()
        let moved = s.settled(generation: 2, geometry: geo(scale: 16, offset: V(x: 300, y: 0)), baseCellPixels: 64)
        guard case .update(let cols, _, _) = moved.first else { return XCTFail("\(moved)") }
        XCTAssertNotEqual(cols, 36...43)
        _ = s.zoomChanged()
        XCTAssertEqual(s.settled(generation: 3, geometry: geo(scale: 1), baseCellPixels: 64), [.clear])
        XCTAssertFalse(s.isActive)
        _ = s.zoomChanged()
        XCTAssertEqual(s.settled(generation: 4, geometry: geo(scale: 1.2), baseCellPixels: 64), [])   // 已清，不重复
    }

    func testResetClearsPurgesAndInvalidatesTimers() {
        var s = DetailLayerState()
        _ = s.zoomChanged()
        XCTAssertEqual(s.reset(), [.clear, .purgeCache])
        XCTAssertEqual(s.settled(generation: 1, geometry: geo(scale: 16), baseCellPixels: 64), [])
        XCTAssertFalse(s.isActive)
    }

    func testStandardPolicy() {
        let p = DetailLayerPolicy.standard
        XCTAssertEqual(p.minGainOverBase, 1.5)
        XCTAssertEqual(p.maxVisibleCells, 960)
        XCTAssertEqual(p.ring, 1)
        XCTAssertEqual(p.settleDelay, 0.15)
        XCTAssertEqual(p.maxConcurrentRequests, 6)
        XCTAssertEqual(p.cacheByteLimit, 64 * 1_048_576)
    }

    // MARK: 取图计划

    func testLoadPlanGroupsByAssetCenterFirstAndSkipsEmpty() {
        let g = geo(scale: 16)
        // 每 3 格同一张照片；第 0 列没有素材
        var ids: [String?] = (0..<(80 * 60)).map { "a\($0 / 3)" }
        for row in 0..<60 { ids[row * 80] = nil }
        let plan = DetailLoadPlan(geometry: g, cellAssetIDs: ids, tier: .p512)
        XCTAssertEqual(plan.cellCount, (8 * 10))   // 可见 + 外扩 1 圈，不含第 0 列
        XCTAssertEqual(Set(plan.items.map(\.assetID)).count, plan.items.count)
        XCTAssertLessThan(plan.items.count, plan.cellCount)
        let first = g.cellsCenterOut(ring: 1)[0]
        XCTAssertEqual(plan.items[0].assetID, ids[first]!)
        for item in plan.items { for c in item.cells { XCTAssertEqual(ids[c], item.assetID) } }

        let edgeOffX: Double = 2925          // (390 × 16 − 390) / 2
        let edge = geo(scale: 16, offset: V(x: edgeOffX, y: 0))
        let plan2 = DetailLoadPlan(geometry: edge, cellAssetIDs: ids, tier: .p512)
        let rr = edge.visibleRange(ring: 1)!
        XCTAssertEqual(plan2.cellCount, (rr.columns.count - 1) * rr.rows.count)   // 第 0 列没有素材
        // 素材数组比格子少（异常）：越界格子跳过，不崩
        XCTAssertEqual(DetailLoadPlan(geometry: g, cellAssetIDs: [], tier: .p256).items, [])
    }

    func testLoadPlanByteBudgetKeepsCenterFirst() {
        let g = geo(scale: 16)
        let ids: [String?] = (0..<(80 * 60)).map { "a\($0)" }
        let full = DetailLoadPlan(geometry: g, cellAssetIDs: ids, tier: .p512)
        XCTAssertEqual(full.items.count, 80)
        let budget: Int = 10 * DetailTier.p512.byteCost
        let cut = full.limited(toBytes: budget)
        XCTAssertEqual(cut.items.count, 10)
        XCTAssertEqual(cut.truncatedCount, 70)
        XCTAssertEqual(cut.items, Array(full.items.prefix(10)))
        // 64 MB 预算：256 档最多 256 张、512 档 64 张、1024 档 16 张
        let mb64: Int = 64 * 1_048_576
        XCTAssertEqual(full.limited(toBytes: mb64).items.count, 64)
        XCTAssertEqual(full.limited(toBytes: 0), full)
        XCTAssertEqual(DetailLoadPlan(geometry: g, cellAssetIDs: ids, tier: .p256).limited(toBytes: mb64).items.count, 80)
    }

    // MARK: 请求差分（取消旧请求）

    /// QA P2-1：iPhone 17 Pro Max（440×600 pt @3x）上，原先因 maxVisibleCells=300 而不启用的缩放区间现在应启用，
    /// 且取图计划按 64 MB 截断后字节数不超过预算。分档阈值不改（>64 仍用 256 px）。
    func testTriggerEnablesFormerGapZoomsAndBudgetCapsBytes() {
        let viewport = V(x: 440, y: 600)
        let displayScale: Double = 3
        let budget: Int = 64 * 1_048_576

        func fitted(columns: Int, rows: Int) -> V {
            let aspect = Double(columns) / Double(rows)
            if viewport.x / viewport.y > aspect {
                return V(x: viewport.y * aspect, y: viewport.y)
            }
            return V(x: viewport.x, y: viewport.x / aspect)
        }

        func geometry(columns: Int, rows: Int, scale: Double) -> DetailGeometry {
            return DetailGeometry(viewport: viewport, fittedSize: fitted(columns: columns, rows: rows),
                                  scale: scale, offset: .zero, displayScale: displayScale,
                                  columns: columns, rows: rows)
        }

        // (列, 行, 缩放)：细档 4:3 原缺口 4.65–8.55x，中档 4:3 原缺口 4.65–5.70x；
        // 细档 3:4 原缺口 3.50–6.40x，中档 3:4 原缺口 3.50–4.25x。
        let columnsList: [Int] = [120, 120, 120, 80, 80, 90, 90, 60, 60]
        let rowsList: [Int]    = [ 90,  90,  90, 60, 60, 120, 120, 80, 80]
        let scaleList: [Double] = [4.65, 6.0, 8.55, 4.65, 5.7, 3.50, 6.40, 3.50, 4.25]
        XCTAssertEqual(columnsList.count, scaleList.count)
        XCTAssertEqual(rowsList.count, scaleList.count)

        for i in 0..<scaleList.count {
            let columns = columnsList[i]
            let rows = rowsList[i]
            let scale = scaleList[i]
            let base = PreviewImageLimits.cellPixels(columns: columns, rows: rows)
            let g = geometry(columns: columns, rows: rows, scale: scale)
            let decision = DetailLayerTrigger.decide(g, baseCellPixels: base)
            guard case .activate(_, _, let tier) = decision else {
                return XCTFail("\(columns)×\(rows) @\(scale)x 应启用，实际 \(decision)，可见格 \(g.visibleCellCount)")
            }
            XCTAssertEqual(tier, .p256, "\(columns)×\(rows) @\(scale)x 可见格 \(g.visibleCellCount) > 64，应为 256 档")
            XCTAssertLessThanOrEqual(g.visibleCellCount, DetailLayerPolicy.standard.maxVisibleCells)
            let cellCount = columns * rows
            var ids: [String?] = []
            ids.reserveCapacity(cellCount)
            for n in 0..<cellCount { ids.append("a\(n)") }
            let plan = DetailLoadPlan(geometry: g, cellAssetIDs: ids, tier: tier)
                .limited(toBytes: budget)
            let plannedBytes: Int = plan.items.count * tier.byteCost
            XCTAssertLessThanOrEqual(plannedBytes, budget, "\(columns)×\(rows) @\(scale)x 计划 \(plannedBytes) 字节")
            XCTAssertGreaterThan(plan.items.count, 0)
        }
    }

    func testRequestDiff() {
        let d = DetailRequestDiff.diff(inFlight: ["a", "b", "c"], needed: ["c", "d", "e", "d", "f"],
                                       cached: { $0 == "e" })
        XCTAssertEqual(d.cancel, ["a", "b"])
        XCTAssertEqual(d.start, ["d", "f"])   // c 在飞、e 已缓存、d 去重
        let none = DetailRequestDiff.diff(inFlight: ["a"], needed: [], cached: { _ in false })
        XCTAssertEqual(none.cancel, ["a"])
        XCTAssertEqual(none.start, [])
    }

    func testDetailCacheKeyIncludesFillAndInvalidateDropsEntries() {
        let photo = DetailCacheKey(assetID: "abc", fill: nil)
        XCTAssertEqual(photo.cacheToken, "id:abc|fc:-")
        XCTAssertTrue(photo.cacheToken.contains("fc:"))
        XCTAssertTrue(photo.fetchesPhoto)
        let red = DetailCacheKey(assetID: "abc", fill: CellColor(r: 1, g: 2, b: 3))
        XCTAssertEqual(red.cacheToken, "id:|fc:1,2,3")
        XCTAssertFalse(red.fetchesPhoto, "纯色格不取照片")
        XCTAssertNotEqual(photo, red)
        let fromCell = DetailCacheKey(cell: .init(localIdentifier: "abc", fill: CellColor(r: 1, g: 2, b: 3)))
        XCTAssertEqual(fromCell, red)
        let other = DetailCacheKey(assetID: "abc", fill: CellColor(r: 1, g: 2, b: 4))
        XCTAssertNotEqual(red.cacheToken, other.cacheToken)
        let cache = DetailTileCache<Int>()
        cache.set(1, for: photo)
        cache.set(2, for: red)
        XCTAssertEqual(cache.get(photo), 1)
        XCTAssertEqual(cache.get(red), 2)
        cache.invalidate()
        XCTAssertNil(cache.get(photo))
        XCTAssertNil(cache.get(red))
    }
}
