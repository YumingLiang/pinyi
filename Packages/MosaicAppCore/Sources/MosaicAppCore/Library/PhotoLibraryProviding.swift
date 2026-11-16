import Foundation
import MosaicCore

/// 一张图像资产的元数据（全量元数据 diff 用，决定 11：TF1 只做全量 diff）。
public struct AssetMetadata: Sendable, Hashable, Codable {
    /// `PHAsset.localIdentifier`。
    public var id: String
    /// `PHAsset.modificationDate`（编辑过会变）。
    public var modificationDate: Date?
    /// 原图像素尺寸（`PHAsset.pixelWidth/Height`，评审 O3：用来覆盖特征里的宽高比）。
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(id: String, modificationDate: Date?, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.id = id
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var aspectRatio: Float {
        pixelWidth > 0 && pixelHeight > 0 ? Float(pixelWidth) / Float(pixelHeight) : 1
    }
}

/// 相簿（技术方案 §2.7：用户相簿 + 少量智能相簿）。
public struct AlbumInfo: Sendable, Hashable, Codable, Identifiable {
    /// `PHAssetCollection.localIdentifier`。
    public var id: String
    /// 相簿名（用户起的名字，不翻译）。
    public var title: String
    /// 资产总数（扫描未完成时显示「约 N 张」）。
    public var assetCount: Int

    public init(id: String, title: String, assetCount: Int) {
        self.id = id
        self.title = title
        self.assetCount = assetCount
    }
}

/// 相册来源的抽象（App 里是 PhotoKit 适配器，测试里是 fake）。
///
/// 实现须遵守技术方案 §5：枚举按索引区间分批（`assetMetadata(in:)`），**不要**把全部 `PHAsset` 转成数组。
public protocol PhotoLibraryProviding: Sendable {
    /// 当前读取授权（`PHPhotoLibrary.authorizationStatus(for: .readWrite)`）。
    func authorizationStatus() -> PhotoAuthorization
    /// 请求授权（`requestAuthorization(for: .readWrite)`）。
    func requestAuthorization() async -> PhotoAuthorization
    /// 图像资产总数（`PHAsset.fetchAssets(with: .image)` 的 count；受限时只含已授权的）。
    func assetCount() async -> Int
    /// 按索引区间取元数据（区间越界部分忽略）。顺序必须稳定（例如按创建时间）。
    func assetMetadata(in range: Range<Int>) async -> [AssetMetadata]
    /// 用户相簿 + 选定的智能相簿。
    func albums() async -> [AlbumInfo]
    /// 相簿内图像资产的 localIdentifier。相簿已不存在 / 打不开时抛错（→ `source.album.unreadable`）。
    func assetIDs(inAlbum albumID: String) async throws -> [String]
}

/// 缩略图请求参数（技术方案 §2.2 / QA B-08，平台层原样映射到 `PHImageRequestOptions`）。
public struct ThumbnailRequest: Sendable, Hashable {
    /// 目标像素边长（正方形，`.aspectFill`）。
    public var targetPixelSize: Int = 128
    /// `PHImageContentMode.aspectFill`。
    public var aspectFill = true
    /// `PHImageRequestOptionsDeliveryMode.fastFormat`。
    public var fastFormat = true
    /// `PHImageRequestOptionsResizeMode.fast`。
    public var fastResize = true
    /// `isNetworkAccessAllowed` —— **永远 false**（零网络）。
    public let isNetworkAccessAllowed = false
    /// `PHCachingImageManager.allowsCachingHighQualityImages` —— false。
    public let allowsCachingHighQualityImages = false
    /// 取回后按短边居中裁成正方形（预览 / 导出绘制用）。扫描建索引必须为 false：
    /// 14ac550 的扫描路径是 `opaqueSRGB(maxEdge:)` 按长边等比缩小（结果可非方），再由 `FeatureExtractor` 取中心正方形；先裁方再缩小会改变特征，与已建索引不一致。
    public var centerCropToSquare = false

    public init(targetPixelSize: Int = 128) { self.targetPixelSize = targetPixelSize }
    public static let scan = ThumbnailRequest()
    /// 预览 / 导出绘制：128px 扫描缩略图，但居中裁方，避免画进格子时拉伸。
    public static var scanDisplay: ThumbnailRequest {
        var r = ThumbnailRequest.scan
        r.centerCropToSquare = true
        return r
    }
}

/// 取缩略图的结果（技术方案 §2.9）。
public enum ThumbnailResult: Sendable {
    /// 成功：已画到**不透明白底的 sRGB** 上下文（评审 O2：同时处理 P3 与 alpha），RGBA8。
    case image(PixelBuffer)
    /// 本地取不到（`requestImage` 返回 nil，或 `PHImageResultIsInCloudKey = true`）。内部状态 `unavailableLocal`。
    case unavailableLocal
    /// 解码失败等其他错误。
    case failed
}

/// 缩略图来源的抽象。
public protocol ThumbnailProviding: Sendable {
    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult
    /// 预取下一批（`startCachingImages`）；默认不做。
    func startCaching(_ assetIDs: [String], request: ThumbnailRequest) async
    /// 停止预取（`stopCachingImages`）。
    func stopCaching(_ assetIDs: [String], request: ThumbnailRequest) async
    /// 进后台时释放全部预取（`stopCachingImagesForAllAssets`，决定 5）。
    func stopAllCaching() async
}

public extension ThumbnailProviding {
    func startCaching(_ assetIDs: [String], request: ThumbnailRequest) async {}
    func stopCaching(_ assetIDs: [String], request: ThumbnailRequest) async {}
    func stopAllCaching() async {}
}
