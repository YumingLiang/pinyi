import Foundation
import Photos
import UIKit
import MosaicAppCore

/// `GridThumbnailLoading<UIImage>` 的 PhotoKit 实现：全 App 共享一个 `PHCachingImageManager`（photo-picker-v0.1 §2、§3；T3）。
///
/// 固定参数：`deliveryMode = .opportunistic`、`resizeMode = .fast`、`isNetworkAccessAllowed = false`（零网络）、
/// `contentMode = .aspectFill`，目标尺寸 `targetPixelSize × targetPixelSize`。startCaching / stopCaching 用同一套参数，
/// 否则 PHCachingImageManager 的缓存命中不了。
///
/// - 回调：`.opportunistic` 可能先给 degraded 再给正式版；都转发给 handler（主线程）。正式版是 nil 而之前已给过图时，
///   不再转发 nil（不把格子清空）。本机没有就是 `image == nil`，不弹任何提示（§5.2）。
/// - 取消：`cancel` 后即使 PhotoKit 还有迟到的回调也不再转发（cell 已复用给别的照片）。
/// - 按 ID 找 `PHAsset` 走 `PhotoFetch.images(withLocalIdentifiers:)`（隐藏照片取不到），结果放一个小缓存；
///   相册一有变化就清空缓存，避免拿着已隐藏 / 已删除照片的旧 `PHAsset` 继续请求图。
/// - 素材扫描的 `PhotoKitThumbnails`（128 px、`.fastFormat`，actor 隔离）仍用它自己的 manager，参数不同，混用只会互相挤缓存。
/// ⚠️ 盲写（Linux 只做 swiftc -parse）。
@MainActor
final class PhotoKitThumbnailLoader: GridThumbnailLoading {
    typealias Image = UIImage

    static let shared = PhotoKitThumbnailLoader()

    /// 按 ID 缓存的 `PHAsset` 上限（约两屏多的缓存窗口 + 余量）。
    static let assetCacheLimit = 1_000

    private let manager: PHCachingImageManager = {
        let m = PHCachingImageManager()
        m.allowsCachingHighQualityImages = false
        return m
    }()

    private var assetCache: [String: PHAsset] = [:]
    private var live: [PHImageRequestID: ThumbnailRequestState] = [:]
    private var listenerToken: UUID?

    private init() {}

    /// 网格缩略图请求选项（AppTests 断言 isNetworkAccessAllowed == false）。
    nonisolated static func requestOptions() -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = false   // 零网络
        o.isSynchronous = false
        o.version = .current
        return o
    }

    private static func size(_ px: Int) -> CGSize { CGSize(width: px, height: px) }

    // MARK: GridThumbnailLoading

    func requestThumbnail(assetID: String, targetPixelSize: Int,
                          handler: @escaping @MainActor (GridThumbnail<UIImage>) -> Void) -> GridThumbnailRequestID? {
        guard let asset = assets([assetID]).first else {
            handler(GridThumbnail(image: nil, isDegraded: false))
            return nil
        }
        let state = ThumbnailRequestState(handler: handler)
        let id = manager.requestImage(for: asset, targetSize: Self.size(targetPixelSize), contentMode: .aspectFill,
                                      options: Self.requestOptions()) { @Sendable image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
            let result = DeliveredThumbnail(image: image, isDegraded: degraded)
            // 缓存命中时 PhotoKit 可能在 requestImage 返回前就在主线程同步回调；其余情况回调线程不保证。
            if Thread.isMainThread {
                MainActor.assumeIsolated { state.deliver(result) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { state.deliver(result) } }
            }
        }
        if !state.finished {
            live[id] = state
            state.onFinish = { [weak self] in self?.live[id] = nil }
        }
        return GridThumbnailRequestID(rawValue: id)
    }

    func cancel(_ id: GridThumbnailRequestID) {
        live.removeValue(forKey: id.rawValue)?.cancel()
        manager.cancelImageRequest(id.rawValue)
    }

    func startCaching(assetIDs: [String], targetPixelSize: Int) {
        let a = assets(assetIDs)
        guard !a.isEmpty else { return }
        manager.startCachingImages(for: a, targetSize: Self.size(targetPixelSize), contentMode: .aspectFill,
                                   options: Self.requestOptions())
    }

    func stopCaching(assetIDs: [String], targetPixelSize: Int) {
        let a = assets(assetIDs)
        guard !a.isEmpty else { return }
        manager.stopCachingImages(for: a, targetSize: Self.size(targetPixelSize), contentMode: .aspectFill,
                                  options: Self.requestOptions())
    }

    func stopCachingAll() {
        manager.stopCachingImagesForAllAssets()
        assetCache.removeAll()
    }

    // MARK: 按 ID 取 PHAsset

    /// 缓存命中的直接用，没命中的一次批量取（走 PhotoFetch，隐藏 / 删除的照片取不到，自然被丢掉）。
    private func assets(_ ids: [String]) -> [PHAsset] {
        observeChangesIfNeeded()
        let missing = ids.filter { assetCache[$0] == nil }
        if !missing.isEmpty {
            if assetCache.count + missing.count > Self.assetCacheLimit { assetCache.removeAll(keepingCapacity: true) }
            for a in PhotoKitLibrary.array(PhotoFetch.images(withLocalIdentifiers: missing)) {
                assetCache[a.localIdentifier] = a
            }
        }
        return ids.compactMap { assetCache[$0] }
    }

    private func observeChangesIfNeeded() {
        guard listenerToken == nil else { return }
        listenerToken = PhotoLibraryObserver.shared.addListener { [weak self] in
            self?.assetCache.removeAll()
        }
    }
}

/// 回调里抄出来的结果。`UIImage` 不可变；这里只做一次后台 → 主线程转交（SDK 若已标 Sendable，这层包装也无害）。
struct DeliveredThumbnail: @unchecked Sendable {
    let image: UIImage?
    let isDegraded: Bool
}

/// 一次缩略图请求的状态（主线程）。`@MainActor` 类自动是 Sendable，可以直接带进 PhotoKit 的 @Sendable 回调，
/// 回调里再回到主线程调用 `deliver`。
@MainActor
final class ThumbnailRequestState {
    private let handler: @MainActor (GridThumbnail<UIImage>) -> Void
    private(set) var cancelled = false
    private(set) var finished = false
    private var deliveredImage = false
    var onFinish: (@MainActor () -> Void)?

    init(handler: @escaping @MainActor (GridThumbnail<UIImage>) -> Void) {
        self.handler = handler
    }

    func cancel() { cancelled = true }

    /// - 取消后 / 正式版之后的回调一律丢掉；
    /// - 非 degraded 的回调算正式版（结束）；
    /// - 正式版是 nil 而之前已经给过图：不转发（不把格子清空）。
    func deliver(_ r: DeliveredThumbnail) {
        guard !cancelled, !finished else { return }
        if !r.isDegraded {
            finished = true
            onFinish?()
            onFinish = nil
        }
        if r.image == nil && deliveredImage { return }
        if r.image != nil { deliveredImage = true }
        handler(GridThumbnail(image: r.image, isDegraded: r.isDegraded))
    }
}
