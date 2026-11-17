import Photos
import XCTest
import MosaicAppCore
@testable import PhotoMosaic

/// 隐藏照片守护第二层（photo-picker-v0.1 §6.2）：PhotoFetch 生成的选项永远不含隐藏照片。
/// 第一层是 Linux job 里的 scripts/check-photo-fetch.sh（所有 fetchAssets 都必须走 PhotoFetch）。
/// 同时断言 T3 的几个 PhotoKit 请求选项都不联网。
final class PhotoFetchTests: XCTestCase {
    private let allSources: [PHAssetSourceType] = [PhotoFetch.Sources.library, PhotoFetch.Sources.cloudShared,
                                                   PhotoFetch.Sources.any]
    private let allOrders: [PhotoFetch.Order] = [.unspecified, .oldestFirst, .newestFirst]

    func testOptionsNeverIncludeHiddenAssets() {
        for imagesOnly in [true, false] {
            for sources in allSources {
                for order in allOrders {
                    let o = PhotoFetch.options(imagesOnly: imagesOnly, sources: sources, order: order)
                    XCTAssertFalse(o.includeHiddenAssets, "imagesOnly=\(imagesOnly) sources=\(sources.rawValue)")
                    XCTAssertFalse(o.includeAllBurstAssets)
                    XCTAssertEqual(o.includeAssetSourceTypes, sources, "来源必须显式设置")
                    XCTAssertEqual(o.predicate != nil, imagesOnly)
                    XCTAssertEqual(o.sortDescriptors?.isEmpty ?? true, order == .unspecified)
                }
            }
        }
    }

    func testSourcePresets() {
        XCTAssertEqual(PhotoFetch.Sources.library, [.typeUserLibrary, .typeiTunesSynced])
        XCTAssertFalse(PhotoFetch.Sources.library.contains(.typeCloudShared), "全部照片不混入共享相簿的照片")
        XCTAssertEqual(PhotoFetch.pickerSources(forSubtype: .albumCloudShared), PhotoFetch.Sources.cloudShared)
        XCTAssertEqual(PhotoFetch.pickerSources(forSubtype: .albumRegular), PhotoFetch.Sources.library)
        XCTAssertEqual(PhotoFetch.pickerSources(forSubtype: .smartAlbumFavorites), PhotoFetch.Sources.library)
    }

    func testSmartAlbumWhitelistExcludesHidden() {
        XCTAssertNil(SmartAlbumKind(photoKitSubtype: .smartAlbumAllHidden))
        XCTAssertNil(SmartAlbumKind(photoKitSubtype: .smartAlbumUserLibrary))
        for k in SmartAlbumKind.allCases {
            XCTAssertEqual(SmartAlbumKind(photoKitSubtype: k.photoKitSubtype), k)
            XCTAssertNotEqual(k.photoKitSubtype, .smartAlbumAllHidden)
        }
    }

    func testRequestOptionsNeverUseNetwork() {
        let grid = PhotoKitThumbnailLoader.requestOptions()
        XCTAssertFalse(grid.isNetworkAccessAllowed)
        XCTAssertEqual(grid.deliveryMode, .opportunistic)
        XCTAssertEqual(grid.resizeMode, .fast)
        for kind in [TargetImageRequestKind.highQuality, .opportunistic] {
            let o = PhotoKitTargetImageLoader.requestOptions(kind)
            XCTAssertFalse(o.isNetworkAccessAllowed)
            XCTAssertEqual(o.deliveryMode, kind == .highQuality ? .highQualityFormat : .opportunistic)
        }
    }

    func testTargetSizeLongSide4096() {
        let s = PhotoKitTargetImageLoader.targetSize(pixelWidth: 8064, pixelHeight: 6048)   // 48MP
        XCTAssertEqual(max(s.width, s.height), 4096)
        XCTAssertEqual(s.height, 3072)
        let small = PhotoKitTargetImageLoader.targetSize(pixelWidth: 1200, pixelHeight: 1600)
        XCTAssertEqual(small, CGSize(width: 1200, height: 1600), "不放大")
    }
}
