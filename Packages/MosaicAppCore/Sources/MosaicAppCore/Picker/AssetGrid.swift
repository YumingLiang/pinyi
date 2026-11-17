import Foundation

// MARK: - 照片网格的数据源与缩略图加载（photo-picker-v0.1 §2、§3；T0 定接口）
//
// - T3 用 `PHFetchResult` 实现 `AssetGridDataSource` / `AssetGridSourceProviding`，用共享的 `PHCachingImageManager`
//   实现 `GridThumbnailLoading`（App 层，`Image == UIImage`）。
// - T4 的 `AssetGridViewController`（UICollectionView）只依赖这里的协议，先用假数据源开发。
// - 都在主线程用（UICollectionView 的数据源回调在主线程），所以标 `@MainActor`。

/// 一次相册变化（对应 `PHFetchResultChangeDetails`）。
public enum AssetGridChange: Sendable, Hashable {
    /// 增量变化，按 `performBatchUpdates` 的顺序应用：先删 `removed`（旧下标），再插 `inserted`（新下标），
    /// 再做 `moves`；`changed`（新下标）在批量更新之后单独 reload。
    /// 照片后来被隐藏也表现为删除（`includeHiddenAssets = false`，§5.1）。
    case incremental(removed: IndexSet, inserted: IndexSet, changed: IndexSet, moves: [AssetGridMove])
    /// 没有增量信息或变化太大：整体 `reloadData`。
    case reload
}

/// 一次移动（旧下标 → 新下标）。
public struct AssetGridMove: Sendable, Hashable {
    public var from: Int
    public var to: Int
    public init(from: Int, to: Int) { self.from = from; self.to = to }
}

/// 网格的数据源：一个相簿（或「全部照片」）里的图片，**按创建时间倒序**（下标 0 = 最新，需求 4e）。
///
/// 实现要求：
/// - 懒加载，不要把 5 万张转成数组（`PHFetchResult` 本身是懒的）。
/// - 只含图片、不含隐藏照片（取数走 `PhotoFetch`）。
/// - `count` / `assetID(at:)` 在一次变化通知之前保持一致；收到 `PHChange` 后先换成新 fetch result 再发通知。
@MainActor
public protocol AssetGridDataSource: AnyObject {
    /// 对应的来源（记住位置时存它）。
    var album: SourceSelection { get }
    var count: Int { get }
    /// `PHAsset.localIdentifier`。`index` 越界是调用方错误。
    func assetID(at index: Int) -> String
    /// 是否实况照片（`mediaSubtypes.contains(.photoLive)`），网格右上角角标用。
    func isLivePhoto(at index: Int) -> Bool
    /// 找某张照片的下标（恢复位置用）；不在此数据源里返回 nil。
    func index(ofAssetID assetID: String) -> Int?
    /// 订阅变化。只保留最后一次设置的 handler；传 nil 取消。
    func setChangeHandler(_ handler: (@MainActor (AssetGridChange) -> Void)?)
}

/// 按来源打开网格数据源（T3 实现）。
@MainActor
public protocol AssetGridSourceProviding: AnyObject {
    /// 相簿不存在 / 打不开返回 nil（调用方回到「全部照片」）。
    func dataSource(for album: SourceSelection) -> (any AssetGridDataSource)?
}

/// 缩略图请求 id（PhotoKit 的 `PHImageRequestID` 是 Int32）。
public struct GridThumbnailRequestID: Sendable, Hashable {
    public var rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
}

/// 一次缩略图回调。`.opportunistic` 会先回低清（`isDegraded == true`）再回正式版，可能回调两次。
public struct GridThumbnail<Image> {
    /// nil = 本机没有（零网络，不下载）；格子显示占位。
    public var image: Image?
    /// `PHImageResultIsDegradedKey`。
    public var isDegraded: Bool

    public init(image: Image?, isDegraded: Bool) {
        self.image = image
        self.isDegraded = isDegraded
    }
}

/// 网格缩略图加载（T3 用全 App 共享的 `PHCachingImageManager` 实现；T4 用假实现开发）。
///
/// 固定参数（§2）：`deliveryMode = .opportunistic`、`resizeMode = .fast`、`isNetworkAccessAllowed = false`、
/// `contentMode = .aspectFill`；`targetPixelSize` = cell 边长 × 屏幕 scale（约 300 px）。
/// 不弹任何「iCloud / 低清」提示（§5.2）。
@MainActor
public protocol GridThumbnailLoading<Image>: AnyObject {
    associatedtype Image
    /// 发请求，结果在主线程回调（可能两次，见 `GridThumbnail`）。照片已不存在时直接回调一次 `image == nil` 并返回 nil。
    func requestThumbnail(assetID: String, targetPixelSize: Int,
                          handler: @escaping @MainActor (GridThumbnail<Image>) -> Void) -> GridThumbnailRequestID?
    /// cell 复用 / 移出时取消（`cancelImageRequest`）。
    func cancel(_ id: GridThumbnailRequestID)
    /// 缓存窗口进入的照片（`startCachingImages`），参数须与 `requestThumbnail` 一致。
    func startCaching(assetIDs: [String], targetPixelSize: Int)
    /// 缓存窗口移出的照片（`stopCachingImages`）。
    func stopCaching(assetIDs: [String], targetPixelSize: Int)
    /// 进后台 / 离开页面（`stopCachingImagesForAllAssets`）。
    func stopCachingAll()
}

/// 缓存窗口一次更新的结果：要开始 / 停止缓存的下标区间（已与 `0..<count` 求交、互不重叠）。
public struct CacheWindowUpdate: Sendable, Hashable {
    public var start: [Range<Int>]
    public var stop: [Range<Int>]
    public init(start: [Range<Int>] = [], stop: [Range<Int>] = []) {
        self.start = start
        self.stop = stop
    }
}

/// 缓存窗口纯逻辑（**T4 实现**，Linux 单测）：可见区上下各一屏 `startCaching`；移出可见区两屏外才 `stopCaching`；
/// 快速滑动时不扩大窗口（只缓存可见区）。T0 只有占位，调用会崩溃。
public struct ThumbnailCacheWindow: Sendable, Hashable {
    /// 当前已在缓存的区间。
    public private(set) var cached: Range<Int> = 0..<0

    public init() {}

    /// - Parameters:
    ///   - visible: 当前可见的下标区间。
    ///   - itemsPerScreen: 一屏大约多少格（列数 × 可见行数）。
    ///   - count: 数据源总数。
    ///   - isFastScrolling: 是否快速滑动（由 T4 按滚动速度判定）。
    public mutating func update(visible: Range<Int>, itemsPerScreen: Int, count: Int,
                                isFastScrolling: Bool) -> CacheWindowUpdate {
        fatalError("T4: ThumbnailCacheWindow.update 未实现")
    }

    /// 数据源整体变化 / reload 后清空，返回需要 stop 的区间。
    public mutating func reset() -> CacheWindowUpdate {
        fatalError("T4: ThumbnailCacheWindow.reset 未实现")
    }
}
