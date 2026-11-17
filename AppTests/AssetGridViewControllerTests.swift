#if INTERNAL_TOOLS
import UIKit
import XCTest
import MosaicAppCore
@testable import PhotoMosaic

/// T4：共用照片网格用 5 万张假数据源跑（不碰相册）。不依赖 cell 是否真的被创建（无 window 时 UIKit 行为不保证），
/// 只看数据源条目数、缓存窗口调用、锚点设置 / 读回、点选回调、相册变化后的位置保持。
final class AssetGridViewControllerTests: XCTestCase {
    @MainActor
    private func makeGrid(count: Int = 50_000) -> (AssetGridViewController, FakeAssetGridDataSource, FakeGridThumbnailLoader) {
        let ds = FakeAssetGridDataSource(count: count)
        let loader = FakeGridThumbnailLoader(latency: 0)
        let vc = AssetGridViewController(dataSource: ds, loader: loader, selectionMode: .single)
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 440, height: 956)   // 17 Pro Max 逻辑尺寸
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        return (vc, ds, loader)
    }

    @MainActor
    func testFiftyThousandItemsAndCacheWindowStarted() throws {
        let (vc, _, loader) = makeGrid()
        let cv = try XCTUnwrap(vc.collectionView)
        XCTAssertEqual(cv.numberOfItems(inSection: 0), 50_000)
        let layout = try XCTUnwrap(vc.gridLayout)
        XCTAssertEqual(layout.columns, 4)
        XCTAssertFalse(loader.caching.isEmpty, "布局好后缓存窗口应 start 可见区 + 下一屏")
        XCTAssertLessThanOrEqual(loader.caching.count, 3 * layout.itemsPerScreen(viewportHeight: 956))
        XCTAssertTrue(loader.caching.contains("fake-49999"), "最新一张在顶部")
    }

    @MainActor
    func testScrollToAnchorAndReadBack() throws {
        let (vc, ds, loader) = makeGrid()
        vc.scroll(to: GridAnchor(index: 20_000, offset: -12))
        let a = try XCTUnwrap(vc.currentAnchor())
        XCTAssertEqual(a.assetID, ds.assetID(at: 20_000))
        XCTAssertEqual(a.offset, -12, accuracy: 0.5)
        XCTAssertEqual(a.album, .allPhotos)
        XCTAssertTrue(loader.caching.contains(ds.assetID(at: 20_000)))
        XCTAssertFalse(loader.caching.contains("fake-49999"), "跳走后顶部的缓存在两屏外，已 stop")
    }

    @MainActor
    func testSingleSelectionCallsBack() throws {
        let (vc, ds, _) = makeGrid(count: 100)
        var got: [AssetGridSelection] = []
        vc.onSelect = { got.append($0) }
        let cv = try XCTUnwrap(vc.collectionView)
        vc.collectionView(cv, didSelectItemAt: IndexPath(item: 5, section: 0))
        XCTAssertEqual(got, [AssetGridSelection(assetID: ds.assetID(at: 5), index: 5)])
        vc.selectionMode = .none
        vc.collectionView(cv, didSelectItemAt: IndexPath(item: 6, section: 0))
        XCTAssertEqual(got.count, 1)
    }

    @MainActor
    func testInsertAtTopKeepsAnchorPhotoInPlace() throws {
        let (vc, ds, _) = makeGrid()
        vc.scroll(to: GridAnchor(index: 400, offset: 0))
        let before = try XCTUnwrap(vc.currentAnchor())
        ds.insertNewest(4)   // 正好一行：锚点照片下标 +4，同一列
        XCTAssertEqual(try XCTUnwrap(vc.collectionView).numberOfItems(inSection: 0), 50_004)
        let after = try XCTUnwrap(vc.currentAnchor())
        XCTAssertEqual(after.assetID, before.assetID, "新照片插到顶部，正在看的那张不动")
        XCTAssertEqual(after.offset, before.offset, accuracy: 0.5)
    }

    @MainActor
    func testRemoveAndReloadUpdateCount() throws {
        let (vc, ds, _) = makeGrid(count: 1000)
        ds.removeNewest(3)
        XCTAssertEqual(try XCTUnwrap(vc.collectionView).numberOfItems(inSection: 0), 997)
        ds.emitReload()
        XCTAssertEqual(try XCTUnwrap(vc.collectionView).numberOfItems(inSection: 0), 997)
        XCTAssertEqual(vc.currentAnchor()?.assetID, ds.assetID(at: 0))
    }

    @MainActor
    func testSwitchDataSourceGoesToTopAndStopsOldCaching() throws {
        let (vc, _, loader) = makeGrid()
        vc.scroll(to: GridAnchor(index: 10_000, offset: 0))
        let other = FakeAssetGridDataSource(count: 30, album: .album(id: "A"))
        vc.setDataSource(other)
        XCTAssertEqual(try XCTUnwrap(vc.collectionView).numberOfItems(inSection: 0), 30)
        XCTAssertEqual(vc.currentAnchor()?.album, .album(id: "A"))
        XCTAssertEqual(vc.currentAnchor()?.assetID, other.assetID(at: 0))
        // 新旧 ID 都是 fake-<序号>：旧数据源 1 万附近的 ID 都应已 stop。
        XCTAssertFalse(loader.caching.contains("fake-39999"))
    }
}
#endif
