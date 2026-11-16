import Foundation
import MosaicCore

/// 素材来源选择（T4：UI 单选；引擎保留并集能力 `BitMask.union`）。
public enum SourceSelection: Sendable, Hashable, Codable {
    /// 「全部照片」/「已允许访问的照片」（受限模式）。
    case allPhotos
    /// 单个相簿。
    case album(id: String)
}

/// 扫描进度（`scan.progress`：已整理 %1$@ / %2$@ 张）。
public struct ScanProgress: Sendable, Hashable {
    /// 本轮已处理（含跳过 / 失败）。
    public var processed: Int
    /// 本轮待处理总数。
    public var total: Int
    /// 当前可用（`.ok`）总张数——渐进可用阈值据此判断。
    public var availableCount: Int
    /// 本轮因 iCloud 未下载而跳过的张数。
    public var skippedUnavailable: Int
    /// 是否从上次中断处继续（`scan.resume`）。
    public var isResuming: Bool

    public init(processed: Int, total: Int, availableCount: Int, skippedUnavailable: Int, isResuming: Bool) {
        self.processed = processed
        self.total = total
        self.availableCount = availableCount
        self.skippedUnavailable = skippedUnavailable
        self.isResuming = isResuming
    }

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }
}

/// 一轮同步的结果。
public struct ScanSummary: Sendable, Hashable {
    public var added = 0
    public var modified = 0
    public var deleted = 0
    public var retried = 0
    /// 本轮处理的张数（含跳过 / 失败）。
    public var processed = 0
    public var newlyAvailable = 0
    public var unavailableLocal = 0
    public var failed = 0
    public var compacted = false
    public var wallSeconds: Double = 0
    public init() {}
}

/// 加载索引的结果。
public enum IndexLoadOutcome: Sendable, Hashable {
    /// 没有旧索引（首启）。
    case fresh
    /// 完好。
    case intact
    /// features.bin 局部损坏：保留前缀，`lostRows` 行对应的资产回到待扫描。
    case recoveredPrefix(lostRows: Int)
    /// 必须丢弃重建（特征版本变化 / 头损坏 / 清单损坏）。决定 (5)：重建流程在 App 层，即本类型。
    case rebuilt(reason: String)
}

/// 索引当前状态（来源页 / 空状态判断用）。
public struct IndexStatus: Sendable, Hashable {
    /// 最近一次 diff 看到的资产总数（diff 前为 nil）。
    public var assetTotal: Int?
    public var available: Int
    public var pending: Int
    public var unavailableLocal: Int
    public var failed: Int
    public var isScanning: Bool
    /// 上次扫描被打断，下次进入扫描显示 `scan.resume`。
    public var wasInterrupted: Bool
    /// 至少完成过一次全量 diff + 扫描。
    public var hasCompletedInitialScan: Bool

    public init(assetTotal: Int?, available: Int, pending: Int, unavailableLocal: Int, failed: Int,
                isScanning: Bool, wasInterrupted: Bool, hasCompletedInitialScan: Bool) {
        self.assetTotal = assetTotal
        self.available = available
        self.pending = pending
        self.unavailableLocal = unavailableLocal
        self.failed = failed
        self.isScanning = isScanning
        self.wasInterrupted = wasInterrupted
        self.hasCompletedInitialScan = hasCompletedInitialScan
    }
}

/// 生成用的快照：`LibrarySnapshot` + 行号 → localIdentifier（渲染时按行取原图 / 缩略图）。
public struct IndexSnapshot: Sendable {
    public var library: LibrarySnapshot
    public var assetIDsByRow: [String?]
    public var availableCount: Int { library.availableCount }
}

public enum PhotoIndexError: Error, Sendable, Equatable {
    /// 相簿已不存在 / 无法读取（`source.album.unreadable`）。
    case albumUnreadable
}

/// 照片索引：全量 diff（T5）→ 分批取缩略图 + 提特征 → features.bin 追加 / tombstone → 原子提交。
///
/// - 修改过的资产：旧行 tombstone，重新扫描后追加新行。
/// - 删除的资产：tombstone + 删条目。空洞率 > 20% 时压缩并重映射行号。
/// - 被打断（取消 / 被杀）：已提交的批次保留，下次从剩余的 `.pending` 继续。
/// - 崩溃一致性：先写 features.bin 再写 index.json。加载时，清单里引用不到的行 → tombstone（孤儿行）；
///   清单引用了超出文件长度的行 → 条目回到 `.pending`。
public actor PhotoIndex {
    public struct Configuration: Sendable, Hashable {
        /// 每批张数（方案 §5：200–500）。
        public var batchSize: Int = 300
        /// 缩略图请求并发上限（方案 §5：16–32）。
        public var maxConcurrentRequests: Int = 24
        /// 生成进行中时的并发上限（方案 §5：降到 4，把 CPU 让给生成）。
        public var concurrencyWhileGenerating: Int = 4
        /// 两次落盘之间至少累计的新行数；整表重写是 O(n)，太频繁会放大写入。
        public var minRowsPerCommit: Int = 1000
        /// 距上次落盘超过该秒数也会落盘（被杀时最多丢这么多进度）。
        public var maxSecondsBetweenCommits: Double = 8
        public var request: ThumbnailRequest = .scan
        public init() {}

        /// 把参数夹到方案给出的范围内。
        public var sanitized: Configuration {
            var c = self
            c.batchSize = min(max(c.batchSize, 1), 500)
            c.maxConcurrentRequests = min(max(c.maxConcurrentRequests, 1), 32)
            c.concurrencyWhileGenerating = min(max(c.concurrencyWhileGenerating, 1), c.maxConcurrentRequests)
            c.minRowsPerCommit = max(1, c.minRowsPerCommit)
            return c
        }
    }

    public nonisolated let directory: URL
    public nonisolated var featuresURL: URL { directory.appendingPathComponent("features.bin") }
    public nonisolated var manifestURL: URL { directory.appendingPathComponent("index.json") }

    private let library: any PhotoLibraryProviding
    private let thumbnails: any ThumbnailProviding
    private let extractor: FeatureExtractor
    private let configuration: Configuration
    private let perf: PerfRecorder?

    public private(set) var table: FeatureTable
    public private(set) var manifest: IndexManifest
    private var generationActive = false
    private var scanning = false
    private var assetTotal: Int?
    private var orderedIDs: [String] = []
    private var metadataByID: [String: AssetMetadata] = [:]
    private var hasCompletedInitialScan = false

    public init(directory: URL, library: any PhotoLibraryProviding, thumbnails: any ThumbnailProviding,
                extractor: FeatureExtractor = FeatureExtractor(), configuration: Configuration = Configuration(),
                perf: PerfRecorder? = nil) {
        self.directory = directory
        self.library = library
        self.thumbnails = thumbnails
        self.extractor = extractor
        self.configuration = configuration.sanitized
        self.perf = perf
        self.table = FeatureTable(records: [], spec: extractor.spec)
        self.manifest = IndexManifest(featureVersion: extractor.spec.featureVersion)
    }

    // MARK: 加载

    /// 读取磁盘上的索引。任何不可恢复的问题都转成"丢弃重建"，不抛错。
    @discardableResult
    public func load() -> IndexLoadOutcome {
        let t0 = perf?.clock.now()
        defer { if let t0, let perf { perf.record(.indexLoad, seconds: perf.clock.now() - t0, items: table.count) } }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fm = FileManager.default
        let hasFeatures = fm.fileExists(atPath: featuresURL.path)
        let hasManifest = fm.fileExists(atPath: manifestURL.path)
        if !hasFeatures && !hasManifest { return .fresh }

        let spec = extractor.spec
        var loadedManifest: IndexManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            loadedManifest = try JSONDecoder().decode(IndexManifest.self, from: data)
        } catch {
            return discardAll(reason: "index.json 缺失或损坏")
        }
        guard loadedManifest.formatVersion == IndexManifest.currentFormatVersion,
              loadedManifest.featureVersion == spec.featureVersion else {
            return discardAll(reason: "特征版本变化 \(loadedManifest.featureVersion) → \(spec.featureVersion)")
        }

        var outcome = IndexLoadOutcome.intact
        var loadedTable = FeatureTable(records: [], spec: spec)
        if hasFeatures {
            do {
                let r = try FeatureFile.read(from: featuresURL, recovery: .keepValidPrefix, expectedSpec: spec)
                loadedTable = r.table
                if case .recoveredPrefix = r.status { outcome = .recoveredPrefix(lostRows: r.rowsToRebuild.count) }
            } catch let e as FeatureFileError where e.recommendedRecovery == .discardAndRebuild {
                return discardAll(reason: "features.bin 不可用：\(e)")
            } catch {
                return discardAll(reason: "features.bin 读取失败：\(error)")
            }
        }

        // 一致性修复：超出文件的引用 → pending；未被引用的行 → tombstone。
        var lost = 0
        for (id, var e) in loadedManifest.entries where e.status == .ok {
            if let r = e.row, r >= 0, r < loadedTable.count, !loadedTable.flags[r].contains(.deleted) { continue }
            e.status = .pending
            e.row = nil
            loadedManifest.entries[id] = e
            lost += 1
        }
        let referenced = loadedManifest.referencedRows
        for row in 0..<loadedTable.count where !referenced.contains(row) && !loadedTable.flags[row].contains(.deleted) {
            loadedTable.markDeleted(row)
        }
        if case .intact = outcome, lost > 0 { outcome = .recoveredPrefix(lostRows: lost) }
        table = loadedTable
        manifest = loadedManifest
        return outcome
    }

    private func discardAll(reason: String) -> IndexLoadOutcome {
        try? FileManager.default.removeItem(at: featuresURL)
        try? FileManager.default.removeItem(at: manifestURL)
        table = FeatureTable(records: [], spec: extractor.spec)
        manifest = IndexManifest(featureVersion: extractor.spec.featureVersion)
        return .rebuilt(reason: reason)
    }

    // MARK: 状态

    public func status() -> IndexStatus {
        IndexStatus(assetTotal: assetTotal, available: manifest.okCount, pending: manifest.count(.pending),
                    unavailableLocal: manifest.count(.unavailableLocal), failed: manifest.count(.failed),
                    isScanning: scanning, wasInterrupted: manifest.scanInProgress,
                    hasCompletedInitialScan: hasCompletedInitialScan)
    }

    /// 生成开始 / 结束时调用：扫描并发随之在 `maxConcurrentRequests` 与 `concurrencyWhileGenerating` 间切换（下一批生效）。
    public func setGenerationActive(_ active: Bool) { generationActive = active }

    /// 某相簿内当前可用张数（来源页第二行）。
    public func availableCount(assetIDs: [String]) -> Int {
        var n = 0
        for id in Set(assetIDs) where manifest.entries[id]?.status == .ok { n += 1 }
        return n
    }

    // MARK: diff

    /// 全量元数据 diff（决定 11），并把结果应用到索引：删除 → tombstone；修改 → tombstone + pending；新增 / 重试 → pending。
    @discardableResult
    public func applyFullDiff() async -> LibraryDiff {
        let t0 = perf?.clock.now()
        let total = await library.assetCount()
        var current: [AssetMetadata] = []
        current.reserveCapacity(total)
        var start = 0
        let step = 2000
        while start < total {
            current += await library.assetMetadata(in: start..<min(total, start + step))
            start += step
        }
        assetTotal = total
        orderedIDs = current.map(\.id)
        metadataByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let diff = LibraryDiff.compute(manifest: manifest, current: current)
        for id in diff.deleted {
            if let e = manifest.entries[id], e.status == .ok, let r = e.row, r < table.count { table.markDeleted(r) }
            manifest.entries[id] = nil
        }
        for id in diff.modified {
            if let e = manifest.entries[id], e.status == .ok, let r = e.row, r < table.count { table.markDeleted(r) }
            manifest.entries[id] = IndexEntry(modificationDate: metadataByID[id]?.modificationDate)
        }
        for id in diff.added + diff.retried {
            manifest.entries[id] = IndexEntry(modificationDate: metadataByID[id]?.modificationDate)
        }
        manifest.lastFullDiff = Date()
        if !diff.deleted.isEmpty || !diff.modified.isEmpty {
            try? commit()   // tombstone 先落盘；失败时下次 diff 会重新得出同样结论
        }
        if let t0, let perf { perf.record(.libraryDiff, seconds: perf.clock.now() - t0, items: total) }
        return diff
    }

    // MARK: 扫描

    /// diff + 扫描全部待处理资产。Task 被取消时提交已完成部分后抛 `CancellationError`。
    public func synchronize(progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanSummary {
        let diff = await applyFullDiff()
        var s = try await scanPending(progress: progress)
        s.added = diff.added.count
        s.modified = diff.modified.count
        s.deleted = diff.deleted.count
        s.retried = diff.retried.count
        return s
    }

    /// 扫描所有 `.pending` 条目。
    public func scanPending(progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanSummary {
        let clock = perf?.clock ?? MonotonicClock.system
        let wall0 = clock.now()
        var summary = ScanSummary()
        let queue = pendingQueue()
        let isResuming = manifest.scanInProgress
        guard !queue.isEmpty else {
            if manifest.scanInProgress { manifest.scanInProgress = false; try? commit() }
            hasCompletedInitialScan = true
            progress?(ScanProgress(processed: 0, total: 0, availableCount: manifest.okCount,
                                   skippedUnavailable: 0, isResuming: false))
            return summary
        }
        scanning = true
        defer { scanning = false }
        manifest.scanInProgress = true
        try? commit()

        var uncommitted: [(String, FeatureRecord)] = []
        var lastCommit = clock.now()
        var processed = 0
        var skipped = 0
        progress?(ScanProgress(processed: 0, total: queue.count, availableCount: manifest.okCount,
                               skippedUnavailable: 0, isResuming: isResuming))

        let request = configuration.request
        let extractor = self.extractor
        let thumbs = self.thumbnails
        let meta = metadataByID
        var batchStart = 0
        do {
            while batchStart < queue.count {
                try Task.checkCancellation()
                let batch = Array(queue[batchStart..<min(queue.count, batchStart + configuration.batchSize)])
                let nextBatch = Array(queue[min(queue.count, batchStart + configuration.batchSize)..<min(queue.count, batchStart + 2 * configuration.batchSize)])
                if !nextBatch.isEmpty { await thumbs.startCaching(nextBatch, request: request) }
                let limit = generationActive ? configuration.concurrencyWhileGenerating : configuration.maxConcurrentRequests
                let b0 = clock.now()
                let outcomes = try await BoundedConcurrency.map(batch, maxConcurrent: limit) { id -> (ScanItemOutcome, Double) in
                    switch await thumbs.thumbnail(for: id, request: request) {
                    case .unavailableLocal: return (.unavailableLocal, 0)
                    case .failed: return (.failed, 0)
                    case .image(let buffer):
                        let e0 = clock.now()
                        guard var rec = try? extractor.extract(from: buffer) else { return (.failed, clock.now() - e0) }
                        if let m = meta[id], m.pixelWidth > 0, m.pixelHeight > 0 { rec.aspectRatio = m.aspectRatio }   // 评审 O3
                        return (.ok(rec), clock.now() - e0)
                    }
                }
                await thumbs.stopCaching(batch, request: request)
                let batchWall = clock.now() - b0
                var extractSeconds = 0.0
                for (id, (outcome, secs)) in zip(batch, outcomes) {
                    extractSeconds += secs
                    switch outcome {
                    case .ok(let rec): uncommitted.append((id, rec))
                    case .unavailableLocal:
                        manifest.entries[id]?.status = .unavailableLocal
                        summary.unavailableLocal += 1
                        skipped += 1
                    case .failed:
                        manifest.entries[id]?.status = .failed
                        summary.failed += 1
                    }
                }
                perf?.record(.thumbnailFetch, seconds: batchWall, items: batch.count, note: "并发 \(limit)")
                perf?.record(.featureExtract, seconds: extractSeconds, items: batch.count, note: "累计 CPU")
                processed += batch.count
                batchStart += batch.count
                // 整表重写是 O(n)：阈值随表长增长（≥ 10% 表长），总写入量 O(n log n) 级；另有时间上限兜底。
                if uncommitted.count >= max(configuration.minRowsPerCommit, table.count / 10)
                    || clock.now() - lastCommit >= configuration.maxSecondsBetweenCommits
                    || batchStart >= queue.count {
                    summary.newlyAvailable += uncommitted.count
                    try flush(&uncommitted)
                    lastCommit = clock.now()
                }
                progress?(ScanProgress(processed: processed, total: queue.count,
                                       availableCount: manifest.okCount + uncommitted.count,
                                       skippedUnavailable: skipped, isResuming: isResuming))
            }
        } catch {
            // 取消或 I/O 失败：尽量保住已完成的部分；scanInProgress 保持 true → 下次显示 scan.resume。
            summary.newlyAvailable += uncommitted.count
            try? flush(&uncommitted)
            throw error
        }
        manifest.scanInProgress = false
        summary.compacted = try compactIfNeeded()
        try commit()
        hasCompletedInitialScan = true
        summary.processed = processed
        summary.wallSeconds = clock.now() - wall0
        return summary
    }

    private enum ScanItemOutcome: Sendable {
        case ok(FeatureRecord), unavailableLocal, failed
    }

    /// 待扫描队列：先按最近一次 diff 的资产顺序，再补上 diff 之外残留的 pending（排序保证可复现）。
    private func pendingQueue() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for id in orderedIDs where manifest.entries[id]?.status == .pending {
            out.append(id)
            seen.insert(id)
        }
        let rest = manifest.entries.compactMap { $0.value.status == .pending && !seen.contains($0.key) ? $0.key : nil }
        return out + rest.sorted()
    }

    private func flush(_ uncommitted: inout [(String, FeatureRecord)]) throws {
        guard !uncommitted.isEmpty else { return }
        let base = table.count
        table = table.appending(uncommitted.map(\.1))
        for (i, (id, _)) in uncommitted.enumerated() {
            // 条目可能已在扫描期间被删（diff 并发调用被 actor 串行化，理论上不会），防御性地跳过。
            guard manifest.entries[id] != nil else { table.markDeleted(base + i); continue }
            manifest.entries[id]?.status = .ok
            manifest.entries[id]?.row = base + i
        }
        uncommitted.removeAll(keepingCapacity: true)
        try commit()
    }

    /// 空洞率 > 20% 时压缩并重映射行号。
    private func compactIfNeeded() throws -> Bool {
        guard table.needsCompaction else { return false }
        let t0 = perf?.clock.now()
        let (t, map) = table.compacted()
        table = t
        manifest.remapRows(map)
        if let t0, let perf { perf.record(.compaction, seconds: perf.clock.now() - t0, items: t.count) }
        return true
    }

    /// 原子提交：先 features.bin，后 index.json。
    private func commit() throws {
        let t0 = perf?.clock.now()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FeatureFile.write(table, to: featuresURL)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        if let t0, let perf { perf.record(.indexCommit, seconds: perf.clock.now() - t0, items: table.count) }
    }

    // MARK: 快照

    /// 生成那一刻的素材快照（来源 ∧ 已扫描 ∧ 未删除）。
    public func snapshot(for source: SourceSelection) async throws -> IndexSnapshot {
        var sourceMask: BitMask?
        if case .album(let albumID) = source {
            let ids: [String]
            do { ids = try await library.assetIDs(inAlbum: albumID) } catch { throw PhotoIndexError.albumUnreadable }
            var rows: [Int] = []
            for id in ids {
                if let e = manifest.entries[id], e.status == .ok, let r = e.row, r < table.count { rows.append(r) }
            }
            sourceMask = BitMask(count: table.count, setIndices: rows)
        }
        let lib = try LibrarySnapshot(table: table, sourceMask: sourceMask)
        return IndexSnapshot(library: lib, assetIDsByRow: manifest.assetIDsByRow(rowCount: table.count))
    }
}
