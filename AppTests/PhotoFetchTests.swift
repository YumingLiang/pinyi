import Photos
import XCTest
import MosaicAppCore
@testable import PhotoMosaic

/// 隐藏照片守护第二层（photo-picker-v0.1 §6.2）：PhotoFetch 生成的选项永远不含隐藏照片。
/// 第一层是 Linux job 里的 scripts/check-photo-fetch.sh（所有 fetchAssets / fetchKeyAssets 都必须走 PhotoFetch）。
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

    /// `keyAssets(in:sources:)` 用同一套 `options`（imagesOnly、显式来源、不设排序），同样写死不含隐藏照片。
    func testKeyAssetOptionsNeverIncludeHiddenAssets() {
        for sources in allSources {
            let o = PhotoFetch.options(imagesOnly: true, sources: sources, order: .unspecified)
            XCTAssertFalse(o.includeHiddenAssets, "sources=\(sources.rawValue)")
            XCTAssertFalse(o.includeAllBurstAssets)
            XCTAssertEqual(o.includeAssetSourceTypes, sources, "来源必须显式设置")
            XCTAssertNotNil(o.predicate)
            XCTAssertTrue(o.sortDescriptors?.isEmpty ?? true)
        }
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

    /// 源码守卫（模拟器 CI）：按 ID 取图走 visibleImages（取回后再滤 isHidden）；导出按 decision 处理 missing。
    func testVisibleImagesAndExportSourceGuards() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fetch = try String(contentsOf: root.appendingPathComponent("App/Adapters/PhotoFetch.swift"), encoding: .utf8)
        let thumbs = try String(contentsOf: root.appendingPathComponent("App/Adapters/PhotoKitThumbnails.swift"), encoding: .utf8)
        let exp = try String(contentsOf: root.appendingPathComponent("App/Export/LiveMosaicExporter.swift"), encoding: .utf8)
        let loader = try String(contentsOf: root.appendingPathComponent("App/Adapters/PhotoKitThumbnailLoader.swift"), encoding: .utf8)
        XCTAssertTrue(fetch.contains("func visibleImages(withLocalIdentifiers"))
        XCTAssertTrue(fetch.contains("VisibleAssetFilter.accepting"))
        XCTAssertTrue(fetch.contains("isHidden"))
        XCTAssertTrue(thumbs.contains("PhotoFetch.visibleImages(withLocalIdentifiers:"))
        XCTAssertTrue(thumbs.contains("return .missing"))
        XCTAssertTrue(exp.contains("ExportFillStats.decision(afterHighQuality:"))
        XCTAssertTrue(loader.contains("PhotoFetch.visibleImages(withLocalIdentifiers:"))
        XCTAssertTrue(loader.contains("!a.isHidden"))
        XCTAssertTrue(fetch.contains("func isPickedAssetAvailable"))
        XCTAssertTrue(fetch.contains("!visibleImages(withLocalIdentifiers: [id]).isEmpty"),
                      "isPickedAssetAvailable 应走 visibleImages，不单独 images + isHidden")
    }
}
