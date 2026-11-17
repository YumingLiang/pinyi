import Foundation
import Photos
import MosaicCore
import MosaicAppCore

/// `AssetGridSourceProviding` 的 PhotoKit 实现（photo-picker-v0.1 §2、§3；T3）。
///
/// - 「全部照片」：`PhotoFetch.allImages(order: .newestFirst)`。
/// - 相簿：按 localIdentifier 取集合，再 `PhotoFetch.images(in:)`（共享相簿用 `Sources.cloudShared`），创建时间倒序。
/// - 智能相簿只接受白名单里的子类型：传进来的 id 如果是「已隐藏」等白名单外的智能相簿，返回 nil（调用方回到全部照片）。
/// ⚠️ 盲写（Linux 只做 swiftc -parse）。
@MainActor
final class PhotoKitAssetGridSourceProvider: AssetGridSourceProviding {
    private let observer: PhotoLibraryObserver

    init(observer: PhotoLibraryObserver = .shared) {
        self.observer = observer
    }

    func dataSource(for album: SourceSelection) -> (any AssetGridDataSource)? {
        guard let fetch = Self.fetchResult(for: album) else { return nil }
        let source = PhotoKitAssetGridDataSource(album: album, fetchResult: fetch)
        observer.register(source)
        return source
    }

    /// 某个来源的图片，创建时间倒序（下标 0 = 最新）。相簿不存在 / 不允许显示时返回 nil。
    static func fetchResult(for album: SourceSelection) -> PHFetchResult<PHAsset>? {
        switch album {
        case .allPhotos:
            return PhotoFetch.allImages(order: .newestFirst)
        case .album(let id):
            let cols = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
            guard let c = cols.firstObject, isBrowsable(c) else { return nil }
            return PhotoFetch.images(in: c, sources: PhotoFetch.pickerSources(forSubtype: c.assetCollectionSubtype),
                                     order: .newestFirst)
        }
    }

    /// 允许打开的集合：普通相簿、共享相簿、白名单智能相簿。`.smartAlbumAllHidden` 等白名单外的智能相簿一律不行。
    static func isBrowsable(_ c: PHAssetCollection) -> Bool {
        switch c.assetCollectionType {
        case .album: return true
        case .smartAlbum: return SmartAlbumKind(photoKitSubtype: c.assetCollectionSubtype) != nil
        default: return false
        }
    }
}

/// 一个相簿的网格数据源：包一个 `PHFetchResult`（懒加载，不转数组）。
///
/// 收到相册变化时先换成 `fetchResultAfterChanges`，再把 `GridChangePlanner.plan` 的结果交给网格，
/// 保证网格收到通知时 `count` / `assetID(at:)` 已经是新的（`AssetGridDataSource` 的约定）。
@MainActor
final class PhotoKitAssetGridDataSource: AssetGridDataSource, PhotoLibraryChangeTarget {
    let album: SourceSelection
    private(set) var fetchResult: PHFetchResult<PHAsset>
    private var changeHandler: (@MainActor (AssetGridChange) -> Void)?

    init(album: SourceSelection, fetchResult: PHFetchResult<PHAsset>) {
        self.album = album
        self.fetchResult = fetchResult
    }

    var count: Int { fetchResult.count }

    func assetID(at index: Int) -> String { fetchResult.object(at: index).localIdentifier }

    func isLivePhoto(at index: Int) -> Bool { fetchResult.object(at: index).mediaSubtypes.contains(.photoLive) }

    /// 先按 ID 取回这张照片（走 PhotoFetch，隐藏 / 删除的取不到），再在本 fetch result 里找下标。
    func index(ofAssetID assetID: String) -> Int? {
        guard let asset = PhotoFetch.visibleImages(withLocalIdentifiers: [assetID]).first else { return nil }
        let i = fetchResult.index(of: asset)
        return i == NSNotFound ? nil : i
    }

    /// 按下标取 `PHAsset`（缩略图加载器 / 大图预览用，省一次按 ID 查询）。
    func asset(at index: Int) -> PHAsset { fetchResult.object(at: index) }

    func setChangeHandler(_ handler: (@MainActor (AssetGridChange) -> Void)?) {
        changeHandler = handler
    }

    func photoLibraryDidChange(_ change: PHChange) {
        guard let details = change.changeDetails(for: fetchResult) else { return }
        let before = fetchResult.count
        fetchResult = details.fetchResultAfterChanges
        // 用 LockedState 收集：不管 SDK 把这个 block 标成 escaping / @Sendable 与否都能编译（同步调用，锁无竞争）。
        let moves = LockedState<[AssetGridMove]>([])
        if details.hasIncrementalChanges && details.hasMoves {
            details.enumerateMoves { from, to in moves.withLock { $0.append(AssetGridMove(from: from, to: to)) } }
        }
        let raw = GridChangeDetails(countBefore: before, countAfter: fetchResult.count,
                                    hasIncrementalChanges: details.hasIncrementalChanges,
                                    removed: details.removedIndexes ?? IndexSet(),
                                    inserted: details.insertedIndexes ?? IndexSet(),
                                    changed: details.changedIndexes ?? IndexSet(),
                                    moves: moves.get())
        changeHandler?(GridChangePlanner.plan(raw))
    }
}
