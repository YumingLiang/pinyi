import Foundation

// MARK: - 选图页 / 来源页共用的相簿列表（photo-picker-v0.1 §3、§5.1；T0 定接口，T1 实现逻辑，T3 实现数据源）
//
// 硬约束（AndyL 16:20，需求 v0.4 §4.8）：隐藏照片任何地方都不出现。
// - 本文件的类型**无法表达**「已隐藏」相簿：`SmartAlbumKind` 只有 8 个白名单成员，没有 allHidden；
//   App 层把 `PHAssetCollectionSubtype` 映射到 `SmartAlbumKind` 时，白名单外的子类型（含 `.smartAlbumAllHidden`）一律丢弃。
// - 所有图片数都只数图片、不含隐藏照片（App 层统一走 `PhotoFetch`）。

/// 智能相簿白名单（photo-picker-v0.1 §1）。**不含** `smartAlbumAllHidden`，也不允许以后加进来。
///
/// `allCases` 的顺序就是相簿列表里「媒体类型」一节的显示顺序。
/// `rawValue` 只用于持久化 / 日志，App 层映射见 `App/Adapters/PhotoFetch.swift` 的 `SmartAlbumKind.photoKitSubtype`。
public enum SmartAlbumKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// 个人收藏（`.smartAlbumFavorites`）
    case favorites
    /// 最近添加（`.smartAlbumRecentlyAdded`）
    case recentlyAdded
    /// 自拍（`.smartAlbumSelfPortraits`）
    case selfPortraits
    /// 人像（`.smartAlbumDepthEffect`）
    case depthEffect
    /// 实况照片（`.smartAlbumLivePhotos`）
    case livePhotos
    /// 全景照片（`.smartAlbumPanoramas`）
    case panoramas
    /// 截屏（`.smartAlbumScreenshots`）
    case screenshots
    /// 连拍快照（`.smartAlbumBursts`；PhotoKit 默认只返回代表张）
    case bursts
}

/// 相簿种类。
public enum AlbumKind: Sendable, Hashable, Codable {
    /// 「全部照片」/ 受限时「已允许访问的照片」。不是 PhotoKit 集合，id 固定为 `AlbumEntry.allPhotosID`。
    case allPhotos
    /// 用户相簿（`PHAssetCollection` `.album` / `.albumRegular`、`.albumSyncedAlbum` 等可读的普通相簿）。
    case userAlbum
    /// 文件夹（`PHCollectionList`）。本身没有照片，子项在 `AlbumEntry.children`。
    case folder
    /// 白名单内的智能相簿。
    case smart(SmartAlbumKind)
    /// iCloud 共享相簿（`.albumCloudShared`）。照片长边约 2048 px，本机不一定有缓存；不提示（§5.2）。
    case cloudShared
}

/// 相簿列表里的一项（值类型；数据源和模型都用它）。
public struct AlbumEntry: Sendable, Hashable, Codable, Identifiable {
    /// 「全部照片」的固定 id（不会与 PhotoKit 的 `localIdentifier`「UUID/L0/0xx」冲突）。
    public static let allPhotosID = "pinyi.allPhotos"

    /// `PHAssetCollection` / `PHCollectionList` 的 `localIdentifier`；「全部照片」为 `allPhotosID`。
    public var id: String
    /// 标题：用户相簿 / 文件夹是用户起的名字（不翻译）；智能相簿、共享相簿用系统 `localizedTitle`。
    /// 「全部照片」为空串，UI 用文案 key（`picker.all` / `source.list.allowed`）。
    public var title: String
    public var kind: AlbumKind
    /// 只数图片、不含隐藏照片（`PhotoFetch.options(imagesOnly: true, ...)` 的 count）。
    /// 文件夹由数据源填 0，是否显示看子项（见 `AlbumCatalog.sections`）。
    public var imageCount: Int
    /// 文件夹的子项（相簿或子文件夹），按 PhotoKit 顺序；非文件夹为空。
    public var children: [AlbumEntry]

    public init(id: String, title: String, kind: AlbumKind, imageCount: Int, children: [AlbumEntry] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.imageCount = imageCount
        self.children = children
    }

    /// 「全部照片」这一项。
    public static func allPhotos(imageCount: Int) -> AlbumEntry {
        AlbumEntry(id: allPhotosID, title: "", kind: .allPhotos, imageCount: imageCount)
    }

    public var isFolder: Bool { kind == .folder }

    /// 对应的来源选择（来源页 / 记住位置用）。文件夹不能被选中，返回 nil。
    public var selection: SourceSelection? {
        switch kind {
        case .allPhotos: return .allPhotos
        case .folder: return nil
        case .userAlbum, .smart, .cloudShared: return .album(id: id)
        }
    }
}

/// 数据源一次读出来的原始相簿（未过滤、未排序）。App 层（T3）实现 `AlbumCatalogProviding` 时产出它。
public struct AlbumCatalogSnapshot: Sendable, Hashable {
    /// 「全部照片」图片数（`includeAssetSourceTypes = PhotoFetch.Sources.library`，不含共享相簿的照片）。
    public var allPhotosCount: Int
    /// 我的相簿：顶层用户相簿和文件夹（文件夹带子树），**PhotoKit 顺序**（即用户在「照片」App 里排的顺序）。
    public var myAlbums: [AlbumEntry]
    /// 白名单里取到的智能相簿（每种至多一个；取不到的不出现）。顺序不要求。
    public var smartAlbums: [AlbumEntry]
    /// 共享相簿。顺序不要求。
    public var sharedAlbums: [AlbumEntry]

    public init(allPhotosCount: Int, myAlbums: [AlbumEntry] = [], smartAlbums: [AlbumEntry] = [],
                sharedAlbums: [AlbumEntry] = []) {
        self.allPhotosCount = allPhotosCount
        self.myAlbums = myAlbums
        self.smartAlbums = smartAlbums
        self.sharedAlbums = sharedAlbums
    }
}

/// 相簿列表数据源（App 层 PhotoKit 适配器实现，T3；测试里用 fake）。
///
/// 实现要求（§5.1）：
/// - 图片数全部用 `PhotoFetch.options(imagesOnly: true, ...)` 计，不含隐藏照片，不允许 `options: nil`。
/// - 智能相簿只取 `SmartAlbumKind.allCases` 对应的子类型；`estimatedAssetCount` 对智能相簿是 `NSNotFound`，必须实数。
/// - 受限访问时，计数只含已允许的照片（PhotoKit 自然行为）。
/// - 只读，不触发网络。
public protocol AlbumCatalogProviding: Sendable {
    /// 读一次完整的原始相簿列表。相册变化后由调用方（共享的变化监听）重新调用。
    func catalogSnapshot() async -> AlbumCatalogSnapshot
}

/// 相簿列表的一节。
public enum AlbumSectionKind: Sendable, Hashable, Codable {
    /// 只含「全部照片」一行。
    case allPhotos
    /// 我的相簿（含文件夹）。
    case myAlbums
    /// 媒体类型（8 个智能相簿白名单）。
    case mediaTypes
    /// 共享相簿。
    case shared
}

public struct AlbumSection: Sendable, Hashable, Identifiable {
    public var id: AlbumSectionKind { kind }
    public var kind: AlbumSectionKind
    public var entries: [AlbumEntry]

    public init(kind: AlbumSectionKind, entries: [AlbumEntry]) {
        self.kind = kind
        self.entries = entries
    }
}

/// 相簿列表纯逻辑（**T1 实现**，Linux 单测：`AlbumCatalogTests`）。`filter` 是 P1，仍是占位。
///
/// T1 要满足的规则：
/// 1. 节顺序：全部照片 → 我的相簿 → 媒体类型 → 共享相簿；空节不输出（「全部照片」节始终输出，哪怕 0 张）。
/// 2. 隐藏空相簿：`imageCount == 0` 的相簿不显示；文件夹在去掉空子项后没有子项就不显示（递归）。
/// 3. 排序：我的相簿保持 PhotoKit 顺序（子项同样）；智能相簿按 `SmartAlbumKind.allCases` 顺序；
///    共享相簿按标题 `localizedStandardCompare` 升序，标题相同按 id。
/// 4. 白名单：智能相簿只保留 `SmartAlbumKind` 白名单（类型层面已保证不含已隐藏）；同一种出现多次只留第一个。
/// 5. 纯函数：同样的输入给同样的输出。
public enum AlbumCatalog {
    /// 智能相簿白名单（8 个，不含已隐藏）。
    public static let smartAlbumWhitelist: [SmartAlbumKind] = SmartAlbumKind.allCases

    /// 原始快照 → 要显示的节（规则见上）。**T1**
    public static func sections(from snapshot: AlbumCatalogSnapshot) -> [AlbumSection] {
        var out: [AlbumSection] = [
            AlbumSection(kind: .allPhotos, entries: [.allPhotos(imageCount: max(0, snapshot.allPhotosCount))]),
        ]
        let mine = visibleMyAlbums(snapshot.myAlbums)
        if !mine.isEmpty { out.append(AlbumSection(kind: .myAlbums, entries: mine)) }
        let smart = visibleSmartAlbums(snapshot.smartAlbums)
        if !smart.isEmpty { out.append(AlbumSection(kind: .mediaTypes, entries: smart)) }
        let shared = visibleSharedAlbums(snapshot.sharedAlbums)
        if !shared.isEmpty { out.append(AlbumSection(kind: .shared, entries: shared)) }
        return out
    }

    /// 某相簿当前是否可见（存在、不空、可被选中），`BrowsePositionStore` 恢复位置时用。
    /// 「全部照片」始终可见；文件夹不算（不能被选中）。会在文件夹子树里找。**T1**
    public static func isSelectable(_ selection: SourceSelection, in sections: [AlbumSection]) -> Bool {
        switch selection {
        case .allPhotos:
            return true
        case .album(let id):
            // `allPhotosID` 不是 PhotoKit 集合，不能当相簿选；文件夹不能选；空相簿不算可见
            // （正常情况下 `sections(from:)` 已经去掉了，这里再兜一次，防止调用方传未过滤的节）。
            guard id != AlbumEntry.allPhotosID, let e = entry(id: id, in: sections) else { return false }
            return !e.isFolder && e.imageCount > 0 && e.selection == selection
        }
    }

    /// 按 id 找一项（含文件夹子树）。**T1**
    public static func entry(id: String, in sections: [AlbumSection]) -> AlbumEntry? {
        for section in sections {
            if let hit = find(id: id, in: section.entries) { return hit }
        }
        return nil
    }

    // MARK: 内部实现（T1）

    /// 深度优先找 id（先比自己再进子树），保持列表顺序，命中第一个即返回。
    private static func find(id: String, in entries: [AlbumEntry]) -> AlbumEntry? {
        for e in entries {
            if e.id == id { return e }
            if let hit = find(id: id, in: e.children) { return hit }
        }
        return nil
    }

    /// 我的相簿：只认用户相簿和文件夹，保持 PhotoKit 顺序，递归去掉空相簿和空文件夹。
    /// 数据源误塞进来的其他种类（智能 / 共享 / 全部照片）直接丢弃，不搬到别的节——各节只信自己的来源。
    private static func visibleMyAlbums(_ entries: [AlbumEntry]) -> [AlbumEntry] {
        entries.compactMap { e -> AlbumEntry? in
            switch e.kind {
            case .userAlbum:
                return e.imageCount > 0 ? leaf(e) : nil
            case .folder:
                let kids = visibleMyAlbums(e.children)
                guard !kids.isEmpty else { return nil }
                var f = e
                f.children = kids
                return f
            case .allPhotos, .smart, .cloudShared:
                return nil
            }
        }
    }

    /// 媒体类型：只认白名单里的智能相簿，按白名单顺序；同一种只留第一个（快照里的先后）；空的不显示。
    private static func visibleSmartAlbums(_ entries: [AlbumEntry]) -> [AlbumEntry] {
        var firstOfKind: [SmartAlbumKind: AlbumEntry] = [:]
        for e in entries {
            guard case .smart(let k) = e.kind, firstOfKind[k] == nil else { continue }
            firstOfKind[k] = e
        }
        return smartAlbumWhitelist.compactMap { k in
            guard let e = firstOfKind[k], e.imageCount > 0 else { return nil }
            return leaf(e)
        }
    }

    /// 共享相簿：单独一组，按标题 `localizedStandardCompare` 升序，标题相同按 id；空的不显示；同 id 只留第一个。
    private static func visibleSharedAlbums(_ entries: [AlbumEntry]) -> [AlbumEntry] {
        var seen = Set<String>()
        let kept = entries.filter { e in
            guard e.kind == .cloudShared, e.imageCount > 0 else { return false }
            return seen.insert(e.id).inserted
        }.map(leaf)
        return kept.sorted { a, b in
            switch a.title.localizedStandardCompare(b.title) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }

    /// 非文件夹不应有子项；清掉，避免 `entry(id:)` 在叶子下面找到不该出现的东西。
    private static func leaf(_ e: AlbumEntry) -> AlbumEntry {
        guard !e.children.isEmpty else { return e }
        var c = e
        c.children = []
        return c
    }

    /// 按名字过滤（P1「搜相簿名」，T0/T1 不做；留签名避免以后改接口）。
    /// 规则（P1 定）：不区分大小写 / 全半角，命中文件夹里的子项时保留其所在文件夹。
    public static func filter(_ sections: [AlbumSection], query: String) -> [AlbumSection] {
        fatalError("P1: AlbumCatalog.filter 未实现")
    }
}
