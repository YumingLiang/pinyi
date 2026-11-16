import Foundation

/// 单张资产在索引里的状态（技术方案 §2.9）。
public enum AssetIndexStatus: String, Sendable, Hashable, Codable {
    /// 待扫描（新增 / 修改过 / 上次被打断）。
    case pending
    /// 已提取特征，`row` 指向 `features.bin` 的行。
    case ok
    /// 本地取不到缩略图（iCloud 未下载）：不计入可用，下次全量 diff 时重试。
    case unavailableLocal
    /// 解码或特征提取失败：不计入可用，下次全量 diff 时重试。
    case failed
}

/// 索引条目（localIdentifier → 状态 / 行号 / 修改时间）。
public struct IndexEntry: Sendable, Hashable, Codable {
    public var modificationDate: Date?
    public var status: AssetIndexStatus
    /// `features.bin` 行号；仅 `.ok` 时非 nil。
    public var row: Int?

    public init(modificationDate: Date?, status: AssetIndexStatus = .pending, row: Int? = nil) {
        self.modificationDate = modificationDate
        self.status = status
        self.row = row
    }
}

/// 资产索引（`index.json`）。
///
/// **偏离技术方案**：方案 §2.3 写的是 `index.sqlite`。为保持零依赖且可在 Linux 上测试，MVP 用一个原子写入的 JSON 文件；
/// 10 万条约 10 MB，写入在扫描批次提交时进行（每批一次）。若真机上批次提交耗时过高，再换 SQLite（只改本文件 + `IndexStore`）。
public struct IndexManifest: Sendable, Hashable, Codable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = IndexManifest.currentFormatVersion
    /// 写入时的特征版本（与 `features.bin` 头一致；不一致时丢弃重建）。
    public var featureVersion: UInt32
    public var entries: [String: IndexEntry] = [:]
    /// 扫描进行中被打断（被杀 / 取消）时为 true：下次进入扫描页显示 `scan.resume`。
    public var scanInProgress = false
    /// 最近一次完成全量 diff 的时间（仅诊断）。
    public var lastFullDiff: Date?

    public init(featureVersion: UInt32) { self.featureVersion = featureVersion }

    public var okCount: Int { entries.values.reduce(0) { $0 + ($1.status == .ok ? 1 : 0) } }
    public func count(_ status: AssetIndexStatus) -> Int { entries.values.reduce(0) { $0 + ($1.status == status ? 1 : 0) } }

    /// 所有被 `.ok` 条目引用的行号。
    public var referencedRows: Set<Int> { Set(entries.values.compactMap { $0.status == .ok ? $0.row : nil }) }

    /// 行号 → localIdentifier（快照 → 渲染时取原图用）。
    public func assetIDsByRow(rowCount: Int) -> [String?] {
        var out = [String?](repeating: nil, count: rowCount)
        for (id, e) in entries where e.status == .ok {
            if let r = e.row, r >= 0, r < rowCount { out[r] = id }
        }
        return out
    }

    /// 压缩后按 `oldToNew` 重映射行号；映射为 nil 的条目回到 `.pending`（理论上不会发生：被引用的行不是 tombstone）。
    public mutating func remapRows(_ oldToNew: [Int?]) {
        for (id, var e) in entries {
            guard e.status == .ok, let r = e.row else { continue }
            if r >= 0, r < oldToNew.count, let n = oldToNew[r] {
                e.row = n
            } else {
                e.row = nil
                e.status = .pending
            }
            entries[id] = e
        }
    }
}

/// 全量元数据 diff 的结果（技术方案 §2.5）。
public struct LibraryDiff: Sendable, Hashable {
    /// 新出现的资产。
    public var added: [String] = []
    /// `modificationDate` 变化的资产（编辑过）：旧行 tombstone，重新扫描。
    public var modified: [String] = []
    /// 已不在相册中的资产：tombstone + 删条目。
    public var deleted: [String] = []
    /// 之前 `unavailableLocal` / `failed`，本次重试。
    public var retried: [String] = []

    public init() {}
    public var isEmpty: Bool { added.isEmpty && modified.isEmpty && deleted.isEmpty && retried.isEmpty }

    /// 计算 diff。`current` 的顺序被保留（新增 / 修改 / 重试按该顺序扫描）。
    /// - Parameter retryUnavailable: 是否把 `unavailableLocal` / `failed` 条目重新放回队列（全量 diff 时 true）。
    public static func compute(manifest: IndexManifest, current: [AssetMetadata], retryUnavailable: Bool = true) -> LibraryDiff {
        var d = LibraryDiff()
        var seen = Set<String>()
        seen.reserveCapacity(current.count)
        for a in current {
            guard seen.insert(a.id).inserted else { continue }   // 防御：重复 id 只算一次
            guard let e = manifest.entries[a.id] else { d.added.append(a.id); continue }
            if e.modificationDate != a.modificationDate {
                d.modified.append(a.id)
            } else if retryUnavailable, e.status == .unavailableLocal || e.status == .failed {
                d.retried.append(a.id)
            }
        }
        for id in manifest.entries.keys where !seen.contains(id) { d.deleted.append(id) }
        d.deleted.sort()   // 字典遍历顺序不稳定，排序保证可复现
        return d
    }
}
