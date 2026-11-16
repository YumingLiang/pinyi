import CoreGraphics
import Foundation
import Photos
import UIKit
import MosaicCore
import MosaicAppCore

/// `ThumbnailProviding` 的 PhotoKit 实现（技术方案 §2.2 / §2.9，QA B-08）。
///
/// - `PHCachingImageManager`，`allowsCachingHighQualityImages = false`；
/// - 128px、`.aspectFill`、`.fastFormat`、`.fast`、`isNetworkAccessAllowed = false`（零网络）；
/// - 结果画到**不透明白底的 sRGB** RGBA8 上下文（评审 O2：P3 与 alpha 一次处理），再交给 MosaicCore 提特征。
/// ⚠️ 盲写，见 CHANGES「App 层盲写风险」R2–R4。
final class PhotoKitThumbnails: ThumbnailProviding, @unchecked Sendable {
    private let manager: PHCachingImageManager = {
        let m = PHCachingImageManager()
        m.allowsCachingHighQualityImages = false
        return m
    }()

    private func options(_ r: ThumbnailRequest) -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = r.fastFormat ? .fastFormat : .highQualityFormat
        o.resizeMode = r.fastResize ? .fast : .exact
        o.isNetworkAccessAllowed = r.isNetworkAccessAllowed   // 恒为 false
        o.isSynchronous = false
        o.version = .current
        return o
    }

    private func assets(_ ids: [String]) -> [PHAsset] {
        var out: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        guard let asset = assets([assetID]).first else { return .failed }
        let size = CGSize(width: request.targetPixelSize, height: request.targetPixelSize)
        let opts = options(request)
        let mode: PHImageContentMode = request.aspectFill ? .aspectFill : .aspectFit
        return await withCheckedContinuation { (cont: CheckedContinuation<ThumbnailResult, Never>) in
            // .fastFormat 只回调一次（不会先给降级图再给高清图）；保险起见用 resumed 标志防止二次 resume。
            let once = ResumeOnce(cont)
            manager.requestImage(for: asset, targetSize: size, contentMode: mode, options: opts) { image, info in
                let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                if let image, let cg = image.cgImage {
                    if degraded && opts.deliveryMode != .fastFormat { return }   // 等最终图
                    once.resume(ImagePixels.opaqueSRGB(cg, maxEdge: request.targetPixelSize).map { .image($0) } ?? .failed)
                } else if inCloud {
                    once.resume(.unavailableLocal)
                } else if info?[PHImageErrorKey] != nil || info?[PHImageCancelledKey] != nil {
                    once.resume(.failed)
                } else {
                    once.resume(.unavailableLocal)
                }
            }
        }
    }

    func startCaching(_ assetIDs: [String], request: ThumbnailRequest) async {
        let size = CGSize(width: request.targetPixelSize, height: request.targetPixelSize)
        manager.startCachingImages(for: assets(assetIDs), targetSize: size, contentMode: .aspectFill, options: options(request))
    }

    func stopCaching(_ assetIDs: [String], request: ThumbnailRequest) async {
        let size = CGSize(width: request.targetPixelSize, height: request.targetPixelSize)
        manager.stopCachingImages(for: assets(assetIDs), targetSize: size, contentMode: .aspectFill, options: options(request))
    }

    /// 进后台时释放预取（决定 5）。
    func stopAll() { manager.stopCachingImagesForAllAssets() }
}

/// 防止 continuation 被 resume 两次。
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ v: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: v)
    }
}
