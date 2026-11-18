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
            return PhotoFetch.allImages(order: .newestFirst)   // photo-fetch: raw-ok 网格懒加载，VisibleIndexMap 在后台跳过隐藏项
        case .albums:
            return nil   // 多选只用于素材来源，选图页一次只浏览一个相簿
        case .album(let id):
            let cols = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
            guard let c = cols.firstObject, isBrowsable(c) else { return nil }
            return PhotoFetch.images(in: c, sources: PhotoFetch.pickerSources(forSubtype: c.assetCollectionSubtype), order: .newestFirst)   // photo-fetch: raw-ok 网格懒加载，VisibleIndexMap 在后台跳过隐藏项
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
/// isHidden 后置过滤（相簿多选 PR 合并条件）：建 / 换 fetch result 时用 `VisibleIndexMap` 记下隐藏项，网格下标跳过它们；
/// 没有隐藏项（正常情况）是恒等映射。有隐藏项时相册变化按整体重载处理（增量下标对不上）。
///
/// **扫描在后台**（quick-start v1.0 §2f 补充 4）：`VisibleIndexMap.buildInBackground` 在非主线程逐个看 `isHidden`。
/// 表建好之前 `count == 0`（不会先露出未过滤的结果），建好后发一次整体重载。相册变化同理：后台建新表，回主线程时
/// 一起换上 fetch result 和表，再通知网格，保证网格收到通知时 `count` / `assetID(at:)` 已经是新的（`AssetGridDataSource` 的约定）。
/// 连续变化时只认最后一次（`generation`），被跳过的那次改成整体重载。
@MainActor
final class PhotoKitAssetGridDataSource: AssetGridDataSource, PhotoLibraryChangeTarget {
    let album: SourceSelection
    private(set) var fetchResult: PHFetchResult<PHAsset>
    private var changeHandler: (@MainActor (AssetGridChange) -> Void)?

    /// nil = 后台还在建表（此时 count 为 0）。
    private(set) var visibleMap: VisibleIndexMap?
    private var generation = 0
    /// 后台有一次建表还没回来。
    private var rebuildInFlight = false

    init(album: SourceSelection, fetchResult: PHFetchResult<PHAsset>) {
        self.album = album
        self.fetchResult = fetchResult
        generation = 1
        rebuildInFlight = true
        let gen = generation
        Task { [weak self] in
            let map = await Self.map(fetchResult)
            guard let self, self.generation == gen else { return }
            self.rebuildInFlight = false
            self.visibleMap = map
            self.reloadAll(countBefore: 0)
        }
    }

    /// PHFetchResult 只读访问可跨线程（PhotoKit 文档），这里包一层给后台建表用。
    private struct FetchBox: @unchecked Sendable { let result: PHFetchResult<PHAsset> }

    private static func map(_ r: PHFetchResult<PHAsset>) async -> VisibleIndexMap {
        let box = FetchBox(result: r)
        return await VisibleIndexMap.buildInBackground(rawCount: r.count) { box.result.object(at: $0).isHidden }
    }

    var count: Int { visibleMap?.count ?? 0 }

    private func raw(_ index: Int) -> Int { visibleMap?.rawIndex(forVisible: index) ?? index }

    func assetID(at index: Int) -> String { fetchResult.object(at: raw(index)).localIdentifier }

    func isLivePhoto(at index: Int) -> Bool { fetchResult.object(at: raw(index)).mediaSubtypes.contains(.photoLive) }

    /// 先按 ID 取回这张照片（走 PhotoFetch + isHidden 后置过滤，隐藏 / 删除的取不到），再在本 fetch result 里找下标。
    func index(ofAssetID assetID: String) -> Int? {
        guard let map = visibleMap,
              let asset = PhotoFetch.visibleImages(withLocalIdentifiers: [assetID]).first else { return nil }
        let i = fetchResult.index(of: asset)
        return i == NSNotFound ? nil : map.visibleIndex(forRaw: i)
    }

    /// 按下标取 `PHAsset`（缩略图加载器 / 大图预览用，省一次按 ID 查询）。
    func asset(at index: Int) -> PHAsset { fetchResult.object(at: raw(index)) }

    func setChangeHandler(_ handler: (@MainActor (AssetGridChange) -> Void)?) {
        changeHandler = handler
    }

    private func reloadAll(countBefore: Int) {
        changeHandler?(GridChangePlanner.plan(GridChangeDetails(countBefore: countBefore, countAfter: count,
                                                                hasIncrementalChanges: false, removed: IndexSet(),
                                                                inserted: IndexSet(), changed: IndexSet(), moves: [])))
    }

    func photoLibraryDidChange(_ change: PHChange) {
        guard let details = change.changeDetails(for: fetchResult) else { return }
        // 上一次变化的表还没建好就又变了：那次被跳过，这次只能整体重载。
        let superseded = rebuildInFlight
        rebuildInFlight = true
        generation += 1
        let gen = generation
        let wasIdentity = visibleMap?.isIdentity ?? false
        let after = details.fetchResultAfterChanges
        // 增量信息在主线程先取好（PHFetchResultChangeDetails 不跨线程传）。
        let moves = LockedState<[AssetGridMove]>([])
        if details.hasIncrementalChanges && details.hasMoves {
            details.enumerateMoves { from, to in moves.withLock { $0.append(AssetGridMove(from: from, to: to)) } }
        }
        let incremental = details.hasIncrementalChanges
        let removed = details.removedIndexes ?? IndexSet()
        let inserted = details.insertedIndexes ?? IndexSet()
        let changed = details.changedIndexes ?? IndexSet()
        let rawBefore = fetchResult.count
        Task { [weak self] in
            let map = await Self.map(after)
            guard let self, self.generation == gen else { return }
            self.rebuildInFlight = false
            let before = self.count
            self.fetchResult = after
            self.visibleMap = map
            guard !superseded, wasIdentity, map.isIdentity else {
                // 前后有隐藏项，或中间跳过了一次变化：增量下标对不上网格下标，整体重载。
                self.reloadAll(countBefore: before)
                return
            }
            self.changeHandler?(GridChangePlanner.plan(GridChangeDetails(
                countBefore: rawBefore, countAfter: after.count, hasIncrementalChanges: incremental,
                removed: removed, inserted: inserted, changed: changed, moves: moves.get())))
        }
        // 建新表期间网格仍读旧表 + 旧 fetch result（两者配套），直到上面一起换掉。
    }
}
