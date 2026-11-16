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
