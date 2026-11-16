import Foundation
import Photos
import MosaicAppCore

/// `PhotoLibraryProviding` 的 PhotoKit 实现（薄适配层；逻辑在 MosaicAppCore）。
///
/// ⚠️ 盲写（Linux 上无法编译验证），见 CHANGES「App 层盲写风险」。
final class PhotoKitLibrary: PhotoLibraryProviding, @unchecked Sendable {
    /// 只取图像；按创建时间升序，顺序稳定（diff 与断点续扫依赖它）。
    private func fetchAllImages() -> PHFetchResult<PHAsset> {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.includeHiddenAssets = false
        return PHAsset.fetchAssets(with: opts)
    }

    /// 缓存同一个 fetch result，分批取元数据时不重复 fetch；`invalidate()` 在相册变化后调用。
    private let lock = NSLock()
    private var cached: PHFetchResult<PHAsset>?

    func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    private func current() -> PHFetchResult<PHAsset> {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let r = fetchAllImages()
        cached = r
        return r
    }

    func authorizationStatus() -> PhotoAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAuthorization {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        invalidate()
        return Self.map(s)
    }

    static func map(_ s: PHAuthorizationStatus) -> PhotoAuthorization {
        switch s {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .denied
        }
    }

    func assetCount() async -> Int {
        invalidate()   // 每轮 diff 开始时重新 fetch
        return current().count
    }

    func assetMetadata(in range: Range<Int>) async -> [AssetMetadata] {
        let r = current()
        let lo = max(0, range.lowerBound), hi = min(r.count, range.upperBound)
        guard lo < hi else { return [] }
        let assets = r.objects(at: IndexSet(integersIn: lo..<hi))
        return assets.map {
            AssetMetadata(id: $0.localIdentifier, modificationDate: $0.modificationDate,
                          pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
        }
    }

    func albums() async -> [AlbumInfo] {
        var out: [AlbumInfo] = []
        let imageOnly = PHFetchOptions()
        imageOnly.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        func add(_ c: PHAssetCollection) {
            let n = PHAsset.fetchAssets(in: c, options: imageOnly).count
            out.append(AlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "", assetCount: n))
        }
        // 用户相簿
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        user.enumerateObjects { c, _, _ in add(c) }
        // 少量智能相簿（技术方案 §2.7）：个人收藏、自拍、人像
        for sub in [PHAssetCollectionSubtype.smartAlbumFavorites, .smartAlbumSelfPortraits, .smartAlbumDepthEffect] {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: sub, options: nil).enumerateObjects { c, _, _ in add(c) }
        }
        return out
    }

    func assetIDs(inAlbum albumID: String) async throws -> [String] {
        let cols = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
        guard let c = cols.firstObject else { throw PhotoIndexError.albumUnreadable }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var ids: [String] = []
        PHAsset.fetchAssets(in: c, options: opts).enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        return ids
    }
}
