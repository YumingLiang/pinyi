#if INTERNAL_TOOLS
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import MosaicCore
import MosaicAppCore

/// 「马赛克测试」相簿写入 / 删除（PhotoKit 薄适配；计划与合成图在 MosaicAppCore，已测）。⚠️ 盲写。
/// 需要相册读写权限（`.readWrite`，主流程已申请）。
struct TestAlbumWriter: Sendable {
    enum WriterError: Error { case notAuthorized, encodeFailed, albumCreateFailed }

    func create(plan: TestAlbumPlan, progress: @escaping @Sendable (TestAlbumProgress) -> Void) async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw WriterError.notAuthorized }
        // performChanges 的闭包是 @Sendable：只捕获 Sendable 值（相簿 localIdentifier、[Data]），在闭包里重新取 PHAssetCollection。
        let albumID = try await findOrCreateAlbumID()
        var p = TestAlbumProgress()
        p.phase = .writing
        p.total = plan.count
        progress(p)
        for batch in plan.batches {
            try Task.checkCancellation()
            var datas: [Data] = []
            for i in batch {
                guard let d = Self.jpeg(SyntheticImage.make(index: i)) else { throw WriterError.encodeFailed }
                datas.append(d)
            }
            let batchData = datas
            try await PHPhotoLibrary.shared().performChanges {
                var placeholders: [PHObjectPlaceholder] = []
                for d in batchData {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: d, options: nil)
                    if let ph = req.placeholderForCreatedAsset { placeholders.append(ph) }
                }
                guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
                else { return }
                PHAssetCollectionChangeRequest(for: album)?.addAssets(placeholders as NSArray)
            }
            p.written = batch.upperBound
            progress(p)
        }
        p.phase = .done
        progress(p)
    }

    func deleteAlbum(progress: @escaping @Sendable (TestAlbumProgress) -> Void) async throws {
        guard let album = Self.fetchAlbum() else { var p = TestAlbumProgress(); p.phase = .done; progress(p); return }
        var p = TestAlbumProgress()
        p.phase = .deleting
        p.total = PHAsset.fetchAssets(in: album, options: nil).count
        progress(p)
        let albumID = album.localIdentifier
        // 系统会弹一次删除确认；删除资产和相簿放同一事务。闭包是 @Sendable，只捕获 localIdentifier，在闭包里重新取。
        try await PHPhotoLibrary.shared().performChanges {
            guard let a = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
            else { return }
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(in: a, options: nil))
            PHAssetCollectionChangeRequest.deleteAssetCollections([a] as NSArray)
        }
        p.written = p.total
        p.phase = .done
        progress(p)
    }

    // MARK: 隐藏照片验收（需求 v0.4 §4.8 验收 1 / 8 / 9；photo-picker-v0.1 §6.2 第 6 条）

    /// 把「马赛克测试」相簿里的一张照片设为隐藏（`PHAssetChangeRequest.isHidden`），优先选 `preferring` 里的（例如最新作品用到的）。
    /// 只动本工具写入的测试相簿。返回被隐藏照片在相簿里的序号（不返回 / 不显示 localIdentifier）；相簿没有可隐藏的照片时返回 nil。
    func hideOne(preferring: Set<String>) async throws -> Int? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw WriterError.notAuthorized }
        guard let album = Self.fetchAlbum() else { return nil }
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let visible = PHAsset.fetchAssets(in: album, options: opts)
        guard visible.count > 0 else { return nil }
        var pick = 0
        for i in 0..<visible.count where preferring.contains(visible.object(at: i).localIdentifier) { pick = i; break }
        let id = visible.object(at: pick).localIdentifier
        try await PHPhotoLibrary.shared().performChanges {
            guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            PHAssetChangeRequest(for: a).isHidden = true
        }
        return pick
    }

    /// 取消隐藏「马赛克测试」相簿里所有被隐藏的照片（验收 5b「取消隐藏后作品不改回去」用）。返回取消的张数。
    /// 内部工具里唯一一处 includeHiddenAssets = true，且只限测试相簿。
    func unhideAll() async throws -> Int {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw WriterError.notAuthorized }
        guard let album = Self.fetchAlbum() else { return 0 }
        let albumID = album.localIdentifier
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = true
        opts.predicate = NSPredicate(format: "isHidden == YES")
        let n = PHAsset.fetchAssets(in: album, options: opts).count
        guard n > 0 else { return 0 }
        try await PHPhotoLibrary.shared().performChanges {
            guard let a = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
            else { return }
            let o = PHFetchOptions()
            o.includeHiddenAssets = true
            o.predicate = NSPredicate(format: "isHidden == YES")
            let hidden = PHAsset.fetchAssets(in: a, options: o)
            for i in 0..<hidden.count { PHAssetChangeRequest(for: hidden.object(at: i)).isHidden = false }
        }
        return n
    }

    private func findOrCreateAlbumID() async throws -> String {
        if let a = Self.fetchAlbum() { return a.localIdentifier }
        // 闭包是 @Sendable，不能写外层 var；用 LockedState 带出 placeholder 的 localIdentifier。
        let created = LockedState<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: TestAlbumPolicy.albumTitle)
            let id = req.placeholderForCreatedAssetCollection.localIdentifier
            created.withLock { $0 = id }
        }
        guard let id = created.withLock({ $0 }),
              PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject != nil
        else { throw WriterError.albumCreateFailed }
        return id
    }

    private static func fetchAlbum() -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title == %@", TestAlbumPolicy.albumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    static func jpeg(_ p: PixelBuffer) -> Data? {
        guard let cg = ImagePixels.cgImage(p) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
#endif
