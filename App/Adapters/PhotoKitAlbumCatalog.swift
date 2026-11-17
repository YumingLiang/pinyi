import Foundation
import Photos
import MosaicAppCore

/// `AlbumCatalogProviding` 的 PhotoKit 实现（选图页 / 来源页共用的相簿列表，photo-picker-v0.1 §1、§3、§5.1；T3）。
///
/// - 「全部照片」：`PhotoFetch.allImages`（`Sources.library`，不混入共享相簿的照片）。
/// - 我的相簿：`PHCollectionList.fetchTopLevelUserCollections`，保持 PhotoKit 顺序；文件夹递归取子项。
///   顶层结果里如果混进了共享相簿 / 智能相簿，这里跳过（共享相簿单独一节，智能相簿只走白名单）。
/// - 智能相簿：只按 `SmartAlbumKind.allCases` 逐个子类型去取，**从不枚举全部智能相簿**，所以 `.smartAlbumAllHidden`
///   根本不会被请求；取回后再用 `SmartAlbumKind(photoKitSubtype:)` 核一遍。智能相簿的 `estimatedAssetCount` 是
///   `NSNotFound`，所以全部用 `PhotoFetch` 生成的 imagesOnly 选项实数 `count`。
/// - 共享相簿：`.albumCloudShared`，用 `Sources.cloudShared` 数。
/// - 所有计数都只数图片、不含隐藏照片（`PhotoFetch`）；集合本身用 `options: nil` 取（设计 §5.1 允许）。
/// - 只读，不触发网络。PhotoKit 调用是同步的，`catalogSnapshot()` 是 nonisolated async，跑在调用方之外的线程上。
/// ⚠️ 盲写（Linux 只做 swiftc -parse）。
struct PhotoKitAlbumCatalog: AlbumCatalogProviding {
    /// 文件夹最多递归几层（防御异常数据；「照片」App 实际很少超过 3 层）。
    static let maxFolderDepth = 8

    func catalogSnapshot() async -> AlbumCatalogSnapshot {
        Self.readSnapshot()
    }

    /// 同步读一次（测试 / 调试也可直接调）。
    static func readSnapshot() -> AlbumCatalogSnapshot {
        let allCount = PhotoFetch.allImages(order: .unspecified).count
        let top = PhotoKitLibrary.array(PHCollectionList.fetchTopLevelUserCollections(with: nil))
        return AlbumCatalogSnapshot(allPhotosCount: allCount,
                                    myAlbums: entries(top, depth: 0),
                                    smartAlbums: smartAlbums(),
                                    sharedAlbums: sharedAlbums())
    }

    // MARK: 我的相簿

    private static func entries(_ collections: [PHCollection], depth: Int) -> [AlbumEntry] {
        var out: [AlbumEntry] = []
        out.reserveCapacity(collections.count)
        for c in collections {
            if let album = c as? PHAssetCollection {
                guard isMyAlbum(album) else { continue }
                out.append(AlbumEntry(id: album.localIdentifier, title: album.localizedTitle ?? "", kind: .userAlbum,
                                      imageCount: imageCount(album)))
            } else if let folder = c as? PHCollectionList {
                guard depth < maxFolderDepth else { continue }
                let kids = PhotoKitLibrary.array(PHCollection.fetchCollections(in: folder, options: nil))
                out.append(AlbumEntry(id: folder.localIdentifier, title: folder.localizedTitle ?? "", kind: .folder,
                                      imageCount: 0, children: entries(kids, depth: depth + 1)))
            }
        }
        return out
    }

    /// 「我的相簿」一节收哪些集合：普通相簿（含 iTunes 同步、导入的相簿），不收共享相簿 / 我的照片流 / 智能相簿。
    private static func isMyAlbum(_ c: PHAssetCollection) -> Bool {
        guard c.assetCollectionType == .album else { return false }
        switch c.assetCollectionSubtype {
        case .albumCloudShared, .albumMyPhotoStream: return false
        default: return true
        }
    }

    // MARK: 智能相簿（白名单）

    private static func smartAlbums() -> [AlbumEntry] {
        var out: [AlbumEntry] = []
        for kind in SmartAlbumKind.allCases {
            let r = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: kind.photoKitSubtype, options: nil)
            // 同一子类型偶尔会有多个（系统迁移残留），只取第一个；T1 还会再去重。
            guard let c = r.firstObject,
                  SmartAlbumKind(photoKitSubtype: c.assetCollectionSubtype) == kind else { continue }
            out.append(AlbumEntry(id: c.localIdentifier, title: c.localizedTitle ?? "", kind: .smart(kind),
                                  imageCount: imageCount(c)))
        }
        return out
    }

    // MARK: 共享相簿

    private static func sharedAlbums() -> [AlbumEntry] {
        let r = PhotoKitLibrary.array(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared,
                                                                               options: nil))
        return r.map {
            AlbumEntry(id: $0.localIdentifier, title: $0.localizedTitle ?? "", kind: .cloudShared, imageCount: imageCount($0))
        }
    }

    /// 只数图片、不含隐藏照片。
    private static func imageCount(_ c: PHAssetCollection) -> Int {
        PhotoFetch.images(in: c, sources: PhotoFetch.pickerSources(forSubtype: c.assetCollectionSubtype),
                          order: .unspecified).count
    }
}
