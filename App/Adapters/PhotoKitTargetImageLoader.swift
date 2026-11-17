import Foundation
import Photos
import UIKit
import MosaicAppCore

/// 目标图取图结果（photo-picker-v0.1 §5.2、§6.1）。
/// `@unchecked Sendable`：字段都是值类型，`UIImage` 本身不可变；要经过 continuation 交回调用方。
struct TargetImageFetchResult: @unchecked Sendable {
    /// 拿到的图；nil = 照片已不存在（隐藏 / 删除 / 受限移出）或本机没有任何版本，调用方按 §5.2 用网格缩略图兜底。
    var image: UIImage?
    /// 拿到的图的像素长边（本机版本）。给以后算叠加降级系数 `OverlayDegrade.factor(effectiveLongSide:)` 和性能页用。
    var localLongSide: Int
    var isDegraded: Bool
    var sawInCloud: Bool
    /// 照片按 ID 取不到（隐藏 / 删除 / 受限访问移出）。
    var assetMissing: Bool
    var reason: TargetImageFinishReason?
    var usedFallback: Bool

    static let missing = TargetImageFetchResult(image: nil, localLongSide: 0, isDegraded: false, sawInCloud: false,
                                                assetMissing: true, reason: nil, usedFallback: false)
}

/// 选图页点开一张照片作为目标图时取图（photo-picker-v0.1 §2「大图预览」、§5.2、§6.1；T3）。
///
/// - `isNetworkAccessAllowed = false`（零网络），`targetSize` 长边 4096（和作品里存的目标图一致），不请求 MaximumSize。
/// - 先 `.highQualityFormat`；拿到 nil（常带 InCloud）就改 `.opportunistic`，取最后一张，degraded 也收。
///   判定全部在 `TargetImageFetchMachine`（MosaicAppCore，Linux 单测覆盖回调多次 / 不回调 / 超时 / 取消）。
/// - **不弹任何低清提示**（§5.2 去掉 picker.low_res）；本机长边放在结果里。
/// - Task 取消：取消正在进行的 PhotoKit 请求并立刻返回（`reason == .cancelled`）。
/// - 用 `PHImageManager.default()`，不用网格的 PHCachingImageManager（4096 的大图不该进缩略图缓存）。
/// ⚠️ 盲写（Linux 只做 swiftc -parse）。
@MainActor
final class PhotoKitTargetImageLoader {
    /// 目标图请求的长边（px）。
    nonisolated static let targetLongSide = 4096

    init() {}

    func load(assetID: String, timing: TargetImageFetchMachine<UIImage>.Timing = .init()) async -> TargetImageFetchResult {
        guard let asset = PhotoFetch.images(withLocalIdentifiers: [assetID]).firstObject else { return .missing }
        if Task.isCancelled {
            return TargetImageFetchResult(image: nil, localLongSide: 0, isDegraded: false, sawInCloud: false,
                                          assetMissing: false, reason: .cancelled, usedFallback: false)
        }
        let run = TargetImageRun(asset: asset, timing: timing)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<TargetImageFetchResult, Never>) in
                run.start(cont)
            }
        } onCancel: {
            Task { @MainActor in run.cancel() }
        }
    }

    /// 目标图请求选项（AppTests 断言 isNetworkAccessAllowed == false）。
    nonisolated static func requestOptions(_ kind: TargetImageRequestKind) -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = kind == .highQuality ? .highQualityFormat : .opportunistic
        o.resizeMode = .fast              // 本机有多大给多大（不超过 targetSize），长边才有意义
        o.isNetworkAccessAllowed = false  // 零网络
        o.isSynchronous = false
        o.version = .current
        return o
    }

    /// 按照片宽高比算 targetSize：长边 4096，不超过原图。
    nonisolated static func targetSize(pixelWidth: Int, pixelHeight: Int) -> CGSize {
        let w = max(1, pixelWidth), h = max(1, pixelHeight)
        let long = max(w, h)
        let scale = min(1, Double(targetLongSide) / Double(long))
        return CGSize(width: max(1, (Double(w) * scale).rounded()), height: max(1, (Double(h) * scale).rounded()))
    }

    nonisolated static func pixelLongSide(_ image: UIImage?) -> Int {
        guard let image else { return 0 }
        if let cg = image.cgImage { return max(cg.width, cg.height) }
        return Int((max(image.size.width, image.size.height) * image.scale).rounded())
    }
}

/// 一次取图过程（主线程）：驱动 `TargetImageFetchMachine`，执行它给的动作。被 `load` 的栈帧、PhotoKit 回调和定时器持有，都结束后释放。
@MainActor
private final class TargetImageRun {
    private let asset: PHAsset
    private var machine: TargetImageFetchMachine<UIImage>
    private var continuation: CheckedContinuation<TargetImageFetchResult, Never>?
    private var requestIDs: [TargetImageRequestKind: PHImageRequestID] = [:]
    private var timer: Task<Void, Never>?
    /// 动作队列：PhotoKit 可能在 `requestImage` 返回前同步回调（重入），所以动作排队按序执行，
    /// 保证「最后一个 startTimer」确实是状态机最后要的那个。
    private var pending: [TargetImageFetchAction<UIImage>] = []
    private var draining = false
    /// 已结束但 continuation 还没设上（取消先于 start）时暂存结果。
    private var finishedResult: TargetImageFetchResult?

    init(asset: PHAsset, timing: TargetImageFetchMachine<UIImage>.Timing) {
        self.asset = asset
        self.machine = TargetImageFetchMachine(timing: timing)
    }

    func start(_ cont: CheckedContinuation<TargetImageFetchResult, Never>) {
        if let r = finishedResult {   // 取消先于开始到达：直接交回结果，不发请求
            cont.resume(returning: r)
            return
        }
        continuation = cont
        perform(machine.start())
    }

    func cancel() { perform(machine.cancel()) }

    private func received(_ r: TargetImageDelivery, from kind: TargetImageRequestKind) {
        perform(machine.receive(r.callback, image: r.image, from: kind))
    }

    private func timerFired(_ token: Int) { perform(machine.timerFired(token: token)) }

    private func perform(_ actions: [TargetImageFetchAction<UIImage>]) {
        pending.append(contentsOf: actions)
        guard !draining else { return }
        draining = true
        while !pending.isEmpty { execute(pending.removeFirst()) }
        draining = false
    }

    private func execute(_ a: TargetImageFetchAction<UIImage>) {
        switch a {
        case .request(let kind): request(kind)
        case .cancelRequest(let kind):
            if let id = requestIDs.removeValue(forKey: kind) { PHImageManager.default().cancelImageRequest(id) }
        case .startTimer(let token, let seconds):
            timer?.cancel()
            // 强引用 self：定时器在 finish 时取消，旧定时器靠 token 作废。
            timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.timerFired(token)
            }
        case .finish(let o):
            timer?.cancel()
            timer = nil
            let result = TargetImageFetchResult(image: o.image, localLongSide: o.localLongSide, isDegraded: o.isDegraded,
                                                sawInCloud: o.sawInCloud, assetMissing: false, reason: o.reason,
                                                usedFallback: o.usedFallback)
            if let c = continuation {
                c.resume(returning: result)
                continuation = nil
            } else {
                finishedResult = result
            }
        }
    }

    private func request(_ kind: TargetImageRequestKind) {
        let size = PhotoKitTargetImageLoader.targetSize(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
        let id = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit,
                                                       options: PhotoKitTargetImageLoader.requestOptions(kind)) {
            @Sendable image, info in
            let delivery = TargetImageDelivery(
                image: image,
                callback: TargetImageCallback(
                    hasImage: image != nil,
                    pixelLongSide: PhotoKitTargetImageLoader.pixelLongSide(image),
                    isDegraded: (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false,
                    isInCloud: (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false,
                    isCancelled: (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false,
                    hasError: info?[PHImageErrorKey] != nil))
            // 强引用 self（@MainActor 类是 Sendable）：PhotoKit 在最后一次回调后释放这个闭包。
            if Thread.isMainThread {
                MainActor.assumeIsolated { self.received(delivery, from: kind) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.received(delivery, from: kind) } }
            }
        }
        requestIDs[kind] = id
    }
}

/// 回调里抄出来的结果，后台 → 主线程转交一次。
private struct TargetImageDelivery: @unchecked Sendable {
    let image: UIImage?
    let callback: TargetImageCallback
}
