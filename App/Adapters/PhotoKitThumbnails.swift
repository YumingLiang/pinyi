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
/// G-1：做成 actor（`PHCachingImageManager` 是 actor 状态），去掉 `@unchecked Sendable`。请求本身是回调式，
/// actor 只在发请求时短暂占用，等待结果期间不阻塞其他请求（扫描并发 ≤ 24 仍成立）。
/// ⚠️ 盲写，见 CHANGES「App 层盲写风险」R2–R4。
actor PhotoKitThumbnails: ThumbnailProviding {
    private let manager: PHCachingImageManager = {
        let m = PHCachingImageManager()
        m.allowsCachingHighQualityImages = false
        return m
    }()

    private nonisolated func options(_ r: ThumbnailRequest) -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = r.fastFormat ? .fastFormat : .highQualityFormat
        o.resizeMode = r.fastResize ? .fast : .exact
        o.isNetworkAccessAllowed = r.isNetworkAccessAllowed   // 恒为 false
        o.isSynchronous = false
        o.version = .current
        return o
    }

    private nonisolated func assets(_ ids: [String]) -> [PHAsset] {
        PhotoKitLibrary.array(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))   // 不用 enumerateObjects 闭包
    }

    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        guard let asset = assets([assetID]).first else { return .failed }
        let size = CGSize(width: request.targetPixelSize, height: request.targetPixelSize)
        let opts = options(request)
        let mode: PHImageContentMode = request.aspectFill ? .aspectFill : .aspectFit
        return await withCheckedContinuation { (cont: CheckedContinuation<ThumbnailResult, Never>) in
            // .fastFormat 只回调一次（不会先给降级图再给高清图）；保险起见用 resumed 标志防止二次 resume。
            let once = ResumeOnce(cont)
            // 显式 @Sendable：回调在 PhotoKit 的队列上，不能被推断成 actor 隔离（否则 Swift 6 运行时隔离检查会崩）
            let fast = opts.deliveryMode == .fastFormat
            manager.requestImage(for: asset, targetSize: size, contentMode: mode, options: opts) { @Sendable image, info in
                let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                if let image, let cg = image.cgImage {
                    if degraded && !fast { return }   // 等最终图
                    // 预览 / 导出绘制才居中裁方；扫描建索引保持 14ac550 的按长边缩小（特征不变）。
                    let pixels = request.centerCropToSquare
                        ? ImagePixels.opaqueSRGBCenteredSquare(cg, maxEdge: request.targetPixelSize)
                        : ImagePixels.opaqueSRGB(cg, maxEdge: request.targetPixelSize)
                    once.resume(pixels.map { .image($0) } ?? .failed)
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
    func stopAllCaching() async { manager.stopCachingImagesForAllAssets() }
}

/// 防止 continuation 被 resume 两次（G-1：基于 LockedState，编译器检查 Sendable）。
final class ResumeOnce<T: Sendable>: Sendable {
    private let cont: LockedState<CheckedContinuation<T, Never>?>
    init(_ c: CheckedContinuation<T, Never>) { cont = LockedState(c) }
    func resume(_ v: T) {
        let c = cont.withLock { slot -> CheckedContinuation<T, Never>? in
            let c = slot
            slot = nil
            return c
        }
        c?.resume(returning: v)
    }
}
