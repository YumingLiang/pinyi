import Foundation
import MosaicCore

// MARK: - 协议（MF-3）

/// 存储层读出的原始内容（未做一致性修复；修复在 `IndexRepair`，与存储实现无关）。
public struct StoredIndex: Sendable {
    public var table: FeatureTable
    public var manifest: IndexManifest
    /// features 文件局部损坏、只保留了前缀时丢掉的行数（0 = 完好）。
    public var lostPrefixRows: Int

    public init(table: FeatureTable, manifest: IndexManifest, lostPrefixRows: Int = 0) {
        self.table = table
        self.manifest = manifest
        self.lostPrefixRows = lostPrefixRows
    }
}

/// `IndexStore.load` 的结果。
public enum IndexStoreLoad: Sendable {
    /// 没有旧索引（首启）。
    case fresh
    case loaded(StoredIndex)
    /// 不可用（格式 / 特征版本变化、清单损坏、features 头损坏）：调用方应 `discardAll()` 后从空索引重建。
    case unusable(reason: String)
}

/// 索引持久化边界（评审 d6fa750 MF-3）。`PhotoIndex` 只依赖本协议，不直接读写文件；
/// TF1 实现为 `JSONIndexStore`（features-<epoch>.bin + index.json），1.0 前若触发 SQLite 条件只换实现。
///
/// 约定：
/// - `commit` 必须是**崩溃原子**的：任何时刻被杀，下次 `load` 读到的 table 与 manifest 要么是旧的一对、要么是新的一对，
///   不会出现"新特征 + 旧行号"（MF-1）。
/// - `prepare()` 每次启动调用一次：建目录、设"不进备份"（MF-2），清理上次崩溃留下的孤儿文件。
public protocol IndexStore: Sendable {
    func prepare() throws
    func load(spec: FeatureSpec) -> IndexStoreLoad
    func commit(table: FeatureTable, manifest: IndexManifest) throws
    func discardAll()
}

// MARK: - JSON 实现

public enum IndexStoreError: Error, Sendable, Equatable {
    case directoryUnavailable(String)
    case backupExclusionFailed(String)
}

/// `JSONIndexStore` 提交过程中的步骤（测试用故障注入：在某步之后"被杀"）。
public enum IndexCommitStep: Sendable, Hashable, CaseIterable {
    /// 新的 features-<epoch>.bin 已原子写好（清单还指向旧文件）。
    case featuresWritten
    /// index.json 已原子替换为指向新文件的版本。
    case manifestWritten
    /// 旧 features 文件已删除。
    case oldFeaturesRemoved
}

/// 目录布局：
/// - `features-<epoch>.bin`：特征表（MosaicCore `FeatureFile`，原子写）。**每次提交都写一个新 epoch 的文件**，
///   所以 index.json 原子 rename 之前，旧清单指向的旧文件始终完好——两文件靠文件名绑定（MF-1 推荐方案）。
/// - `index.json`：清单（formatVersion 2，数组行格式），记录 `featuresFile`。
/// - 清单 rename 成功后才删旧文件；`prepare()` / `load()` 删除未被清单引用的 features 文件和临时文件（孤儿）。
///
/// 备份：只在**目录**上设 `isExcludedFromBackup`（MF-2）——原子写会替换文件、文件级属性会丢，目录级不会。
public struct JSONIndexStore: IndexStore {
    public static let manifestName = "index.json"
    /// v1（d6fa750）的固定文件名；升级时作为孤儿删除。
    public static let legacyFeaturesName = "features.bin"

    public let directory: URL
    public let backupExclusion: any BackupExclusionApplying
    /// 测试用：在某步完成后抛错，模拟进程在该点被杀（之后的步骤不执行）。
    let faultAfter: (@Sendable (IndexCommitStep) throws -> Void)?

    public init(directory: URL, backupExclusion: any BackupExclusionApplying) {
        self.init(directory: directory, backupExclusion: backupExclusion, faultAfter: nil)
    }

    init(directory: URL, backupExclusion: any BackupExclusionApplying,
         faultAfter: (@Sendable (IndexCommitStep) throws -> Void)?) {
        self.directory = directory
        self.backupExclusion = backupExclusion
        self.faultAfter = faultAfter
    }

    public var manifestURL: URL { directory.appendingPathComponent(Self.manifestName) }
    public func featuresURL(epoch: Int) -> URL { directory.appendingPathComponent(Self.featuresName(epoch: epoch)) }
    public static func featuresName(epoch: Int) -> String { "features-\(epoch).bin" }

    static func epoch(ofFeaturesName name: String) -> Int? {
        guard name.hasPrefix("features-"), name.hasSuffix(".bin") else { return nil }
        return Int(name.dropFirst("features-".count).dropLast(".bin".count))
    }

    // MARK: prepare

    /// 建目录并在目录上设"不进备份"（MF-2）。目录建不出来抛 `IndexStoreError.directoryUnavailable`；
    /// 排除备份失败时目录已建好，抛 `IndexStoreError.backupExclusionFailed`（调用方计数后继续，不阻断索引）。
    public func prepare() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw IndexStoreError.directoryUnavailable(String(describing: error))
        }
        do {
            try backupExclusion.excludeFromBackup(directory)
        } catch {
            throw IndexStoreError.backupExclusionFailed(String(describing: error))
        }
    }

    // MARK: load

    public func load(spec: FeatureSpec) -> IndexStoreLoad {
        let fm = FileManager.default
        guard fm.fileExists(atPath: manifestURL.path) else {
            let leftovers = featureFileNames()
            removeOrphans(keeping: nil)
            return leftovers.isEmpty ? .fresh : .unusable(reason: "index.json 缺失")
        }
        let envelope: ManifestEnvelope
        do {
            let data = try Data(contentsOf: manifestURL)
            envelope = try JSONDecoder().decode(ManifestEnvelope.self, from: data)
        } catch let e as ManifestEnvelope.VersionError {
            return .unusable(reason: "索引格式 v\(e.found) → v\(IndexManifest.currentFormatVersion)")
        } catch {
            return .unusable(reason: "index.json 缺失或损坏")
        }
        var manifest = envelope.manifest
        guard manifest.featureVersion == spec.featureVersion else {
            return .unusable(reason: "特征版本变化 \(manifest.featureVersion) → \(spec.featureVersion)")
        }
        removeOrphans(keeping: envelope.featuresFile)

        guard let name = envelope.featuresFile else {
            // 还没写过特征（例如只有 pending 条目）
            manifest.clearRowsBeyond(0)
            return .loaded(StoredIndex(table: FeatureTable(records: [], spec: spec), manifest: manifest))
        }
        let url = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else {
            // 清单指向的文件不在了：所有 ok 条目回到 pending（不会错配，只是重扫）
            let lost = manifest.okCount
            return .loaded(StoredIndex(table: FeatureTable(records: [], spec: spec), manifest: manifest, lostPrefixRows: lost))
        }
        do {
            let r = try FeatureFile.read(from: url, recovery: .keepValidPrefix, expectedSpec: spec)
            var lost = 0
            if case .recoveredPrefix(_, let declared) = r.status { lost = max(1, declared - r.table.count) }
            return .loaded(StoredIndex(table: r.table, manifest: manifest, lostPrefixRows: lost))
        } catch let e as FeatureFileError where e.recommendedRecovery == .discardAndRebuild {
            return .unusable(reason: "features 不可用：\(e)")
        } catch {
            return .unusable(reason: "features 读取失败：\(error)")
        }
    }

    // MARK: commit

    public func commit(table: FeatureTable, manifest: IndexManifest) throws {
        // 目录可能在运行中被删：重建并补设排除备份（失败不阻断提交；下次启动 prepare 会再设）。
        if !FileManager.default.fileExists(atPath: directory.path) {
            do { try prepare() } catch IndexStoreError.backupExclusionFailed { }
        }
        let previous = currentFeaturesFile()
        let nextEpoch = (featureFileNames().compactMap(Self.epoch(ofFeaturesName:)).max() ?? 0) + 1
        let newName = Self.featuresName(epoch: nextEpoch)
        try FeatureFile.write(table, to: directory.appendingPathComponent(newName))
        try faultAfter?(.featuresWritten)

        let data = try JSONEncoder().encode(ManifestEnvelope(manifest: manifest, featuresFile: newName))
        try data.write(to: manifestURL, options: .atomic)
        try faultAfter?(.manifestWritten)

        if let previous, previous != newName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous))
        }
        removeOrphans(keeping: newName)
        try faultAfter?(.oldFeaturesRemoved)
    }

    public func discardAll() {
        try? FileManager.default.removeItem(at: manifestURL)
        removeOrphans(keeping: nil)
    }

    // MARK: 内部

    /// 当前清单指向的 features 文件名（读不出则 nil）。
    func currentFeaturesFile() -> String? {
        guard let data = try? Data(contentsOf: manifestURL),
              let e = try? JSONDecoder().decode(ManifestEnvelope.self, from: data) else { return nil }
        return e.featuresFile
    }

    func featureFileNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0 == Self.legacyFeaturesName || Self.epoch(ofFeaturesName: $0) != nil }
    }

    /// 删除未被引用的 features 文件、v1 遗留的 features.bin、原子写残留的临时文件。
    func removeOrphans(keeping keep: String?) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for n in names {
            let isFeatures = n == Self.legacyFeaturesName || Self.epoch(ofFeaturesName: n) != nil
            let isTemp = n.hasPrefix(".features") || n.hasPrefix(".dat.nosync") || n.hasPrefix(".index.json")
            if (isFeatures && n != keep) || isTemp {
                try? fm.removeItem(at: directory.appendingPathComponent(n))
            }
        }
    }
}

// MARK: - index.json v2（数组行格式）

/// index.json 外层（formatVersion 2）。
///
/// 条目改为数组行 `{"i": id, "d": 秒, "s": 状态, "r": 行}`（评审 §2：10 万条约快 2×）。
/// 修改时间存 `timeIntervalSinceReferenceDate` 的 Double——JSON 的 Double 往返是精确的，
/// 不依赖 Date 的编码策略，消除 R19（Darwin 上小数秒往返不一致会导致每次启动全量重扫）。
struct ManifestEnvelope: Codable {
    struct VersionError: Error { let found: Int }

    var manifest: IndexManifest
    var featuresFile: String?

    init(manifest: IndexManifest, featuresFile: String?) {
        self.manifest = manifest
        self.featuresFile = featuresFile
    }

    private enum Keys: String, CodingKey {
        case formatVersion, featureVersion, featuresFile, scanInProgress, lastFullDiff, entries
    }
    private struct Row: Codable {
        var i: String
        var d: Double?
        var s: String
        var r: Int?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let v = try c.decode(Int.self, forKey: .formatVersion)
        guard v == IndexManifest.currentFormatVersion else { throw VersionError(found: v) }
        var m = IndexManifest(featureVersion: try c.decode(UInt32.self, forKey: .featureVersion))
        m.scanInProgress = try c.decodeIfPresent(Bool.self, forKey: .scanInProgress) ?? false
        m.lastFullDiff = try c.decodeIfPresent(Double.self, forKey: .lastFullDiff).map(Date.init(timeIntervalSinceReferenceDate:))
        let rows = try c.decode([Row].self, forKey: .entries)
        m.entries.reserveCapacity(rows.count)
        for row in rows {
            guard let st = AssetIndexStatus(code: row.s) else {
                throw DecodingError.dataCorruptedError(forKey: .entries, in: c, debugDescription: "未知状态 \(row.s)")
            }
            m.entries[row.i] = IndexEntry(modificationDate: row.d.map(Date.init(timeIntervalSinceReferenceDate:)),
                                          status: st, row: row.r)
        }
        manifest = m
        featuresFile = try c.decodeIfPresent(String.self, forKey: .featuresFile)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(manifest.formatVersion, forKey: .formatVersion)
        try c.encode(manifest.featureVersion, forKey: .featureVersion)
        try c.encodeIfPresent(featuresFile, forKey: .featuresFile)
        try c.encode(manifest.scanInProgress, forKey: .scanInProgress)
        try c.encodeIfPresent(manifest.lastFullDiff?.timeIntervalSinceReferenceDate, forKey: .lastFullDiff)
        // 按 id 排序：输出稳定、便于比对
        let rows = manifest.entries.sorted { $0.key < $1.key }.map { id, e in
            Row(i: id, d: e.modificationDate?.timeIntervalSinceReferenceDate, s: e.status.code, r: e.row)
        }
        try c.encode(rows, forKey: .entries)
    }
}

extension AssetIndexStatus {
    /// 单字符编码（数组行格式）。
    var code: String {
        switch self {
        case .pending: return "p"
        case .ok: return "o"
        case .unavailableLocal: return "u"
        case .failed: return "f"
        }
    }
    init?(code: String) {
        switch code {
        case "p": self = .pending
        case "o": self = .ok
        case "u": self = .unavailableLocal
        case "f": self = .failed
        default: return nil
        }
    }
}

// MARK: - 与存储无关的一致性修复

/// 加载后的一致性修复（与 `IndexStore` 实现无关，SQLite 实现复用）：
/// - 清单引用了超出文件 / 已 tombstone 的行 → 条目回到 `.pending`；
/// - 文件里没有被任何 `.ok` 条目引用的行 → tombstone。
/// 由于每次提交 features 与 manifest 通过文件名绑定，这里不会遇到"行号整体错位"的情况（MF-1）。
public enum IndexRepair {
    public static func repair(_ stored: StoredIndex) -> (table: FeatureTable, manifest: IndexManifest, outcome: IndexLoadOutcome) {
        var table = stored.table
        var manifest = stored.manifest
        var lost = 0
        for (id, var e) in manifest.entries where e.status == .ok {
            if let r = e.row, r >= 0, r < table.count, !table.flags[r].contains(.deleted) { continue }
            e.status = .pending
            e.row = nil
            manifest.entries[id] = e
            lost += 1
        }
        let referenced = manifest.referencedRows
        for row in 0..<table.count where !referenced.contains(row) && !table.flags[row].contains(.deleted) {
            table.markDeleted(row)
        }
        let outcome: IndexLoadOutcome = (stored.lostPrefixRows > 0 || lost > 0) ? .recoveredPrefix(lostRows: lost) : .intact
        return (table, manifest, outcome)
    }
}
