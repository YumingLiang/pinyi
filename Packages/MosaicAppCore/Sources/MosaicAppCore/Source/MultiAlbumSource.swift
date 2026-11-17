import Foundation

// MARK: - 相簿多选（quick-start v1.0 §1a、§2f、验收 12；design/photo-picker-v0.1 §6.4）

public extension SourceSelection {
    /// 「全部照片」。
    var isAllPhotos: Bool { if case .allPhotos = self { return true }; return false }

    /// 选中的相簿 ID（按勾选顺序）；全部照片为空。
    var albumIDs: [String] {
        switch self {
        case .allPhotos: return []
        case .album(let id): return [id]
        case .albums(let ids): return ids
        }
    }

    /// 规范化（§6.4）：按勾选顺序、去重、去空；含 `AlbumEntry.allPhotosID` → 全部照片；只剩 1 个 → `.album`；
    /// 0 个 → nil（不允许保存：列表一个都没勾时「完成」不可点）。
    static func albums(normalizing ids: [String]) -> SourceSelection? {
        if ids.contains(AlbumEntry.allPhotosID) { return .allPhotos }
        var seen = Set<String>()
        let kept = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        switch kept.count {
        case 0: return nil
        case 1: return .album(id: kept[0])
        default: return .albums(ids: kept)
        }
    }

    /// 恢复 / 相簿列表变化后：只留仍然可选的相簿（存在、非空、不是共享相簿、打得开），**静默去掉**其余的；
    /// 全去掉了回到全部照片（§1a 验收 2、§2f、验收 10）。顺序保持原勾选顺序。
    func keepingSelectable(_ selectable: Set<String>) -> SourceSelection {
        guard !isAllPhotos else { return .allPhotos }
        return SourceSelection.albums(normalizing: albumIDs.filter(selectable.contains)) ?? .allPhotos
    }
}

/// 多选的并集（§6.4）：各相簿的照片 ID 按 localIdentifier 去重，顺序 = 第一次出现的顺序。纯函数。
public enum MaterialUnion {
    public static func union(_ perAlbum: [[String]]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for ids in perAlbum { for id in ids where seen.insert(id).inserted { out.append(id) } }
        return out
    }
}

/// 记住上次的素材来源（§1a，整组相簿）：`SourceSelection` 的合成 Codable JSON 存进偏好，只存相簿 ID，不存图片，零网络。
/// 解不出来（例如新版本写了 `albums` 又装回旧版本，或数据坏了）→ nil，按全部照片处理。
public struct SourceSelectionStore: Sendable {
    /// 偏好 key。改名会丢用户记住的来源，不要改。
    public static let key = "source.selection"
    public let backend: any PreferenceDataStore
    public init(backend: any PreferenceDataStore) { self.backend = backend }

    public func load() -> SourceSelection? {
        guard let data = backend.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(SourceSelection.self, from: data)
    }

    public func save(_ selection: SourceSelection) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(selection) else { return }
        backend.setData(data, forKey: Self.key)
    }

    /// 上次选的相簿名（相簿 ID → 名字），只用于启动时相簿列表加载完之前的素材标签（§2f 补充 3a）。
    public static let namesKey = "source.selection.names"

    public func loadNames() -> [String: String] {
        guard let data = backend.data(forKey: Self.namesKey),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return names
    }

    public func saveNames(_ names: [String: String]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(names) else { return }
        backend.setData(data, forKey: Self.namesKey)
    }
}

/// 相簿列表里正在勾的那组（§2f）。从「全部照片」进列表时一个都不勾；从相簿来源再进时保留上次的勾选。
public struct AlbumSelectionDraft: Sendable, Hashable {
    /// 按勾选顺序。
    public private(set) var ids: [String]

    public init(from selection: SourceSelection) { ids = selection.albumIDs }

    public func isChecked(_ id: String) -> Bool { ids.contains(id) }

    /// 点整行切换。打不开的相簿不能勾（调用方传 `selectable`）。
    public mutating func toggle(_ id: String, selectable: Bool) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i); return }
        guard selectable else { return }
        ids.append(id)
    }

    /// 相簿列表变化：去掉已经不能选的（静默）。
    public mutating func keep(_ selectable: Set<String>) { ids = ids.filter(selectable.contains) }

    /// 「完成」可点：至少勾了 1 个。
    public var canFinish: Bool { !ids.isEmpty }

    /// 点「完成」得到的来源；没勾选为 nil。
    public var selection: SourceSelection? { SourceSelection.albums(normalizing: ids) }
}

/// 相簿列表底部栏 / 确认页用的去重合计（§2f）。
public struct AlbumUnionCount: Sendable, Hashable {
    /// 去重后的张数：扫描完成后是可用张数（已排除不够清楚的），之前是资产总数（「约」）。
    public var count: Int
    /// 扫描还没完成（用 `_pending` 文案）。
    public var pending: Bool
    public init(count: Int, pending: Bool) { self.count = count; self.pending = pending }
}

public enum MultiAlbumText {
    /// 底部栏：没勾选 `source.selection.none`；扫描完成前 `summary_pending`「已选 n 个相簿 · 约 count 张」；之后 `summary`。
    public static func bar(selected n: Int, union: AlbumUnionCount?) -> LocalizedLine {
        guard n > 0 else { return LocalizedLine(.sourceSelectionNone, []) }
        let c = union ?? AlbumUnionCount(count: 0, pending: true)
        return LocalizedLine(c.pending ? .sourceSelectionSummaryPending : .sourceSelectionSummary,
                             [CountFormat.grouped(n), CountFormat.grouped(c.count)])
    }

    /// 确认页摘要（§2f、验收 12）：1 个「素材：{name} · {count} 张」；2 个「素材：{name1}、{name2} · {count} 张」；
    /// 3 个及以上「素材：{name1} 等 {n} 个相簿 · {count} 张」。相簿名按勾选顺序。
    /// 张数位置的「正在统计…」（`source.counting`，§2f 补充 3a）。摘要模板里张数后面带「张」，所以张数参数放这个占位，
    /// 平台层格式化后用 `resolveCounting` 把「占位 张」整体换成「正在统计…」：「素材：旅行 · 正在统计…」。
    public static let countingArgument = "{source.counting}"

    /// 格式化好的摘要里把「{source.counting} 张」换成 `counting`（「正在统计…」）。没有占位就原样返回。
    public static func resolveCounting(in formatted: String, counting: String) -> String {
        guard formatted.contains(countingArgument) else { return formatted }
        var s = formatted
        for unit in [" 张", "张"] { s = s.replacingOccurrences(of: countingArgument + unit, with: counting) }
        return s.replacingOccurrences(of: countingArgument, with: counting)
    }

    /// - Parameter count: nil = 还在统计（相簿列表没加载完），张数位置显示 `source.counting`。
    public static func materialSummary(names: [String], count: Int?) -> LocalizedLine {
        let c = count.map(CountFormat.grouped) ?? countingArgument
        switch names.count {
        case 0, 1: return LocalizedLine(.quickSourceSummary, [names.first ?? "", c])
        case 2: return LocalizedLine(.quickSourceSummaryTwo, [names[0], names[1], c])
        default: return LocalizedLine(.quickSourceSummaryMany, [names[0], CountFormat.grouped(names.count), c])
        }
    }
}
