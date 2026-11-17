import Foundation
import Photos
import MosaicAppCore

/// `PhotoLibraryClient` 的 PhotoKit 实现（薄适配层；逻辑在 MosaicAppCore）。
///
/// G-1：做成 actor——缓存的 `PHFetchResult`（非 Sendable）是 actor 状态，不再需要 `NSLock` + `@unchecked Sendable`。
/// 同步的授权查询是 `nonisolated`（不碰缓存）。
/// ⚠️ 盲写（Linux 上无法编译验证），见 CHANGES「App 层盲写风险」。
actor PhotoKitLibrary: PhotoLibraryClient {
    /// 只取图像；按创建时间升序，顺序稳定（diff 与断点续扫依赖它）。
    /// 走 `PhotoFetch`（photo-picker-v0.1 §5.1）：不含隐藏照片——照片后来被隐藏，下次 diff 时它不在结果里，
    /// `LibraryDiff` 把它判为删除（tombstone），生成时就不会再用到。来源是 `Sources.library`（本机图库 + iTunes 同步）。
    private func fetchAllImages() -> PHFetchResult<PHAsset> {
        PhotoFetch.allImages(order: .oldestFirst)
    }

    /// 缓存同一个 fetch result，分批取元数据时不重复 fetch；每轮 diff 开始（`assetCount()`）时重新 fetch。
    private var cached: PHFetchResult<PHAsset>?

    func invalidate() { cached = nil }

    private func current() -> PHFetchResult<PHAsset> {
        if let c = cached { return c }
        let r = fetchAllImages()
        cached = r
        return r
    }

    nonisolated func authorizationStatus() -> PhotoAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    // MARK: 仅添加（导出保存，T8）

    nonisolated func addOnlyAuthorizationStatus() -> PhotoAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestAddOnlyAuthorization() async -> PhotoAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    /// 写入系统相册（add-only 权限即可）。
    func saveImageToLibrary(fileURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.shouldMoveFile = false
            req.addResource(with: .photo, fileURL: fileURL, options: opts)
        }
    }

    func requestAuthorization() async -> PhotoAuthorization {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        invalidate()
        return Self.map(s)
    }

    nonisolated static func map(_ s: PHAuthorizationStatus) -> PhotoAuthorization {
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
        // Swift 6 region isolation：不用 enumerateObjects 闭包（SDK 里可能标 @Sendable / sending），
        // PHFetchResult 先转数组再 for-in，可变状态只在本函数内。
        // 计数走 PhotoFetch（只数图片、不含隐藏照片）。来源用 `Sources.library`：和素材索引（`fetchAllImages`）一致，
        // 共享相簿里的照片不在索引里，这里也照旧数不到（行为与改动前相同；选图页的相簿列表另用 `PhotoKitAlbumCatalog`）。
        var collections = Self.array(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))  // 用户相簿
        // 少量智能相簿（技术方案 §2.7）：个人收藏、自拍、人像
        for sub in [PHAssetCollectionSubtype.smartAlbumFavorites, .smartAlbumSelfPortraits, .smartAlbumDepthEffect] {
            collections += Self.array(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: sub, options: nil))
        }
        var out: [AlbumInfo] = []
        out.reserveCapacity(collections.count)
        for c in collections {
            let n = PhotoFetch.images(in: c, sources: PhotoFetch.Sources.library, order: .unspecified).count
            out.append(AlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "", assetCount: n))
        }
        return out
    }

    /// `PHFetchResult` → 数组（同步、无闭包）。
    nonisolated static func array<T: AnyObject>(_ r: PHFetchResult<T>) -> [T] {
        guard r.count > 0 else { return [] }
        return r.objects(at: IndexSet(integersIn: 0..<r.count))
    }

    func assetIDs(inAlbum albumID: String) async throws -> [String] {
        let cols = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
        guard let c = cols.firstObject else { throw PhotoIndexError.albumUnreadable }
        // 走 PhotoFetch：只取图片、不含隐藏照片；来源与 `albums()` 计数一致。
        return Self.array(PhotoFetch.images(in: c, sources: PhotoFetch.Sources.library, order: .unspecified))
            .map(\.localIdentifier)
    }
}
