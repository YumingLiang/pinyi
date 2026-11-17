import CoreGraphics
import Foundation
import Photos
import UIKit
import MosaicCore
import MosaicAppCore

/// `LocalResolutionProbing` 的 PhotoKit 实现（「不能略糊」，hd-export-req-v0.2 F5 / 方案 1）。
///
/// - `PHImageManager.default().requestImage`：256×256、`.aspectFill`、`.highQualityFormat`、`.fast`、
///   `isNetworkAccessAllowed = false`（**零网络**：本机没有就直接判不合格，不触发 iCloud 下载）、异步。
/// - `.fast` 让 PhotoKit 直接给本机已有的最接近版本（可能比 256 大），这样短边是否 ≥ 256 才有意义；
///   `.exact` 会把小图缩放到目标尺寸，掩盖「本机只有小图」。
/// - 判定交给 `LocalResolutionPolicy.classify`（Linux 单测覆盖）：有错 / 在 iCloud / 无图 / 降质图 / 短边 < 256 都不合格。
/// - 只回调一次就判定（`.highQualityFormat` 本来就只回调一次；万一先来降质图，按不合格处理，不会挂住）。
/// - Task 取消时 `cancelImageRequest`，回调随后到达并 resume（结果被上层丢弃、不进缓存）。
/// ⚠️ 盲写（Linux 只做 swiftc -parse），需真机验证：见 CHANGES「清晰度探测」。
final class PhotoKitResolutionProbe: LocalResolutionProbing, Sendable {
    private func options() -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = false   // 零网络
        o.isSynchronous = false
        o.version = .current
        return o
    }

    func probe(assetID: String, minPixelSize: Int) async -> LocalResolutionVerdict {
        // 走 PhotoFetch：隐藏 / 删除的照片取不到，判 missing（photo-picker-v0.1 §5.1）。
        guard let asset = PhotoFetch.images(withLocalIdentifiers: [assetID]).firstObject else {
            return .unusable(.missing)
        }
        let size = CGSize(width: minPixelSize, height: minPixelSize)
        let opts = options()
        let requestID = LockedState<PHImageRequestID?>(nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<LocalResolutionVerdict, Never>) in
                let once = ResumeOnce(cont)
                let id = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill,
                                                               options: opts) { @Sendable image, info in
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                    let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                    let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
                    let hasError = info?[PHImageErrorKey] != nil || cancelled
                    let w = image?.cgImage?.width ?? Int((image?.size.width ?? 0) * (image?.scale ?? 1))
                    let h = image?.cgImage?.height ?? Int((image?.size.height ?? 0) * (image?.scale ?? 1))
                    once.resume(LocalResolutionPolicy.classify(hasImage: image != nil, pixelWidth: w, pixelHeight: h,
                                                               isDegraded: degraded, isInCloud: inCloud, hasError: hasError,
                                                               minPixelSize: minPixelSize))
                }
                requestID.set(id)
            }
        } onCancel: {
            if let id = requestID.get() { PHImageManager.default().cancelImageRequest(id) }
        }
    }
}
