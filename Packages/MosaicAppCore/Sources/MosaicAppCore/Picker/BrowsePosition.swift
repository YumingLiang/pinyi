import Foundation

// MARK: - 记住浏览位置（photo-picker-v0.1 §3；需求 v0.4 1b / 4b；T0 定接口，T2 实现）
//
// 存「相簿 + 锚点照片 + 锚点在屏幕里的偏移」，不存原始 contentOffset：新拍照片插到顶部、列数变化时
// offset 会错位，锚点不会，误差在一屏内。

/// 哪个页面的位置（两页各存各的）。
public enum BrowsePage: String, Sendable, Hashable, Codable, CaseIterable {
    /// 素材来源页（1b）。
    case source
    /// 选目标图的选图页（4b）。
    case target

    /// 在 `PreferenceDataStore` 里的 key。改名会丢用户已存的位置，不要改。
    public var preferenceKey: String { "browse.position.\(rawValue)" }
}

/// 一次浏览位置（值类型，JSON 存进偏好）。
public struct BrowsePosition: Sendable, Hashable, Codable {
    /// 存储格式版本。字段有不兼容改动时 +1，T2 读到不认识的版本按「没存过」处理。
    public static let currentVersion = 1

    public var version: Int
    /// 在看哪个相簿（`.allPhotos` 或 `.album(id: PHAssetCollection.localIdentifier)`）。
    public var album: SourceSelection
    /// 锚点照片的 `PHAsset.localIdentifier`：可见区里第一个（最上面一行最左边）完整或部分可见的格子。
    public var anchorAssetID: String
    /// 锚点格子的上边缘相对可见区上边缘（已扣掉 safe area / contentInset）的距离，单位 pt。
    /// 格子被顶部遮住一部分时为负数。恢复时 `contentOffset.y = 锚点格子 minY - anchorOffset - 顶部 inset`。
    public var anchorOffset: Double

    public init(album: SourceSelection, anchorAssetID: String, anchorOffset: Double,
                version: Int = BrowsePosition.currentVersion) {
        self.version = version
        self.album = album
        self.anchorAssetID = anchorAssetID
        self.anchorOffset = anchorOffset
    }
}

/// 回到「全部照片」顶部的原因（日志 / 测试用，UI 不提示：需求 v0.4 §4.4 第 2 条「不报错」）。
public enum BrowseFallbackReason: String, Sendable, Hashable, Codable {
    /// 没存过（或存的数据读不出 / 版本不认识）。
    case noSavedPosition
    /// 相簿已不存在、受限访问下不可见、或已变空（`AlbumCatalog.isSelectable` 为 false）。
    case albumUnavailable
    /// 相簿还在，但锚点照片已不在里面（删除、被隐藏、受限访问移出）。
    case anchorMissing
}

/// 恢复结果。
public enum BrowseRestoreResult: Sendable, Hashable {
    /// 打开 `album`，滚到 `anchorIndex`（数据源里的下标），并让该格上边缘距可见区上边缘 `anchorOffset` pt。
    case anchor(album: SourceSelection, anchorIndex: Int, anchorOffset: Double)
    /// 打开「全部照片」，滚到顶部。
    case allPhotosTop(reason: BrowseFallbackReason)
}

/// 偏好里存二进制值的抽象（`PreferenceStore` 只存布尔）。App 里用 `UserDefaults.data(forKey:)`，测试用内存字典。
public protocol PreferenceDataStore: Sendable {
    func data(forKey key: String) -> Data?
    /// 传 nil 删除。
    func setData(_ data: Data?, forKey key: String)
}

/// 浏览位置存取（**T2 实现**）。
public protocol BrowsePositionStoring: Sendable {
    /// 读某页上次的位置；没存过 / 解不开 / 版本不认识返回 nil。
    func position(for page: BrowsePage) -> BrowsePosition?
    /// 存某页的位置（滚动停止、离开页面、进后台时调用；调用方负责节流）。
    func save(_ position: BrowsePosition, for page: BrowsePage)
    /// 清掉某页的位置。
    func clear(_ page: BrowsePage)
    /// 决定怎么恢复（纯逻辑，规则见 `BrowsePositionStore`）。
    ///
    /// - Parameters:
    ///   - page: 哪一页。
    ///   - isSelectable: 相簿当前是否可见（调用方用 `AlbumCatalog.isSelectable` 填）。
    ///   - indexOfAnchor: 在该相簿当前的数据源里找锚点照片的下标（`AssetGridDataSource.index(ofAssetID:)`），找不到返回 nil。
    ///     只在相簿可见时调用。
    func restore(for page: BrowsePage,
                 isSelectable: (SourceSelection) -> Bool,
                 indexOfAnchor: (BrowsePosition) -> Int?) -> BrowseRestoreResult
}

/// `BrowsePositionStoring` 的生产实现，存进 `PreferenceDataStore`（key 见 `BrowsePage.preferenceKey`，值为 `BrowsePosition` 的 JSON）。
///
/// **T2 实现**（Linux 单测：`BrowsePositionStoreTests`）。恢复规则：
/// 1. 没存过 → `.allPhotosTop(.noSavedPosition)`。
/// 2. 相簿不可见 → `.allPhotosTop(.albumUnavailable)`（「全部照片」始终可见）。
/// 3. 锚点找不到（或给出负下标）→ `.allPhotosTop(.anchorMissing)`（不停在原相簿顶部：设计 §3）。
/// 4. 否则 → `.anchor(album, index, offset)`。
/// 两页互不影响。
public struct BrowsePositionStore: BrowsePositionStoring {
    public let backend: any PreferenceDataStore

    public init(backend: any PreferenceDataStore) { self.backend = backend }

    public func position(for page: BrowsePage) -> BrowsePosition? {
        guard let data = backend.data(forKey: page.preferenceKey) else { return nil }
        return Self.decode(data)
    }

    /// 存不下的值（锚点 id 为空、偏移不是有限数）不写，保留上一次存的位置——
    /// 这种值只可能来自调用方的瞬时状态（比如布局还没算完），不值得覆盖一个好的旧位置。
    public func save(_ position: BrowsePosition, for page: BrowsePage) {
        guard Self.isStorable(position), let data = Self.encode(position) else { return }
        backend.setData(data, forKey: page.preferenceKey)
    }

    public func clear(_ page: BrowsePage) {
        backend.setData(nil, forKey: page.preferenceKey)
    }

    public func restore(for page: BrowsePage,
                        isSelectable: (SourceSelection) -> Bool,
                        indexOfAnchor: (BrowsePosition) -> Int?) -> BrowseRestoreResult {
        guard let saved = position(for: page) else { return .allPhotosTop(reason: .noSavedPosition) }
        // 「全部照片」始终可见，不问调用方。
        if saved.album != .allPhotos, !isSelectable(saved.album) {
            return .allPhotosTop(reason: .albumUnavailable)
        }
        guard let index = indexOfAnchor(saved), index >= 0 else {
            return .allPhotosTop(reason: .anchorMissing)
        }
        return .anchor(album: saved.album, anchorIndex: index, anchorOffset: saved.anchorOffset)
    }

    // MARK: 编解码（T2）

    /// 当前格式：`BrowsePosition` 的 JSON（键名即属性名，`album` 用 `SourceSelection` 的合成 Codable）。
    static func encode(_ position: BrowsePosition) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(position)
    }

    /// 解不开、版本不是 `currentVersion`（含将来的新版本和旧的 0）、或内容不合法 → nil（按「没存过」处理）。
    static func decode(_ data: Data) -> BrowsePosition? {
        guard let p = try? JSONDecoder().decode(BrowsePosition.self, from: data),
              p.version == BrowsePosition.currentVersion,
              isStorable(p)
        else { return nil }
        return p
    }

    static func isStorable(_ p: BrowsePosition) -> Bool {
        guard !p.anchorAssetID.isEmpty, p.anchorOffset.isFinite else { return false }
        if case .album(let id) = p.album, id.isEmpty || id == AlbumEntry.allPhotosID { return false }
        return true
    }
}
