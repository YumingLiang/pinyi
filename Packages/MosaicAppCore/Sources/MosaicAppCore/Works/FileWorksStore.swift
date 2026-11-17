import Foundation
import MosaicCore

/// 作品库（design/works-storage-v0.1.md）。
public protocol WorksStore: Sendable {
    /// 全部作品，按保存时间倒序（新的在前）。只读 meta.json。
    func list() async -> [WorkSummary]
    /// 保存。布局指纹相同的作品已存在时不重复存，返回已有的那份（`inserted == false`）。
    func save(_ draft: WorkDraft) async throws -> (summary: WorkSummary, inserted: Bool)
    /// 打开（读显式布局）。
    func load(_ id: WorkID) async throws -> Work
    /// 删除整个作品目录。
    func delete(_ id: WorkID) async throws
    /// 记下最近一次检查到的缺失原照片数（列表 / 查看页提示用）。
    func setMissingCount(_ count: Int, for id: WorkID) async throws
    /// 写回一次补格结果（4b）：新布局、重画预览，累计 `replacedCellCount` / `droppedPhotoCount`。
    /// 磁盘上的布局已经不是 `base`（期间别处已经处理过）或结果没有改动时，什么都不写，返回磁盘上的现状。
    func applyRematch(_ result: WorkRematchResult, base: MosaicLayout, for id: WorkID) async throws -> Work
    /// 启动时清理上次被杀留下的临时目录 / 待删目录。
    func removeIncomplete() async
}

/// 文件实现：`Application Support/Works/<uuid>/` 一个作品一个目录。
///
/// - 目录内：`meta.json`（`WorkMeta`）、`layout.json`（`MosaicLayout` 原样 JSON，显式每格照片 ID + 裁剪）、
///   预览图（长边 2732）、目标图副本（长边 ≤ 4096）。图片由注入的 `WorkImageEncoding` 写。
/// - **原子**：先在 `Works/.tmp-<uuid>/` 写齐全部文件（meta.json 最后写），再一次 `rename` 成 `Works/<uuid>/`。
///   同一卷上 rename 是原子的：任何时刻被杀，要么没有这个作品，要么是完整的作品；残留的 `.tmp-*` 列表不认、启动时清掉。
/// - 删除：先 rename 成 `.trash-<uuid>` 再递归删，删到一半被杀也不会在列表里出现半个作品。
/// - **参与 iCloud 备份**：这里刻意不设 `isExcludedFromBackup`（与索引目录相反，见 works-storage-v0.1「重装、换机」）。
/// - layout.json 是不压缩的 JSON：Linux 的 Foundation 没有 `NSData.compressed(using:)`，又不允许手写 deflate；
///   细档 120×90 约 1 万格，JSON 约 1–2 MB，可接受。压缩（lzfse/zlib，仅 Apple）留作 formatVersion 2。
/// - actor：保存 / 删除串行，「同一张不重复存」的查重不会被并发打穿。
public actor FileWorksStore: WorksStore {
    public static let metaFileName = "meta.json"
    public static let layoutFileName = "layout.json"
    static let tempPrefix = ".tmp-"
    static let trashPrefix = ".trash-"

    public nonisolated let directory: URL
    private let images: any WorkImageEncoding
    private let now: @Sendable () -> Date
    private var inFlight: [String: Task<WorkSummary, any Error>] = [:]
    /// 正在改写的作品（打开和导出前可能同时触发缺图处理）：同一作品串行。
    private var updating: [WorkID: (token: UUID, task: Task<Work, any Error>)] = [:]

    public init(directory: URL, images: any WorkImageEncoding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.images = images
        self.now = now
    }

    // MARK: 列表

    public func list() async -> [WorkSummary] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [WorkSummary] = []
        for name in names where !name.hasPrefix(".") {
            guard let id = WorkID(directoryName: name), let s = try? readSummary(id) else { continue }
            out.append(s)
        }
        return out.sorted(by: Self.newestFirst)
    }

    static func newestFirst(_ a: WorkSummary, _ b: WorkSummary) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id.directoryName > b.id.directoryName
    }

    private func workDirectory(_ id: WorkID) -> URL { directory.appendingPathComponent(id.directoryName, isDirectory: true) }

    private func readSummary(_ id: WorkID) throws -> WorkSummary {
        let dir = workDirectory(id)
        let data: Data
        do { data = try Data(contentsOf: dir.appendingPathComponent(Self.metaFileName)) } catch { throw WorksStoreError.notFound }
        guard let meta = try? Self.decoder().decode(WorkMeta.self, from: data) else { throw WorksStoreError.corrupted }
        guard meta.formatVersion <= WorkMeta.currentFormatVersion else { throw WorksStoreError.unsupportedFormat(meta.formatVersion) }
        guard meta.id == id else { throw WorksStoreError.corrupted }
        let preview = dir.appendingPathComponent(meta.previewFile)
        guard FileManager.default.fileExists(atPath: preview.path) else { throw WorksStoreError.corrupted }
        return WorkSummary(meta: meta, previewURL: preview)
    }

    // MARK: 保存

    public func save(_ draft: WorkDraft) async throws -> (summary: WorkSummary, inserted: Bool) {
        let layoutData = try Self.encoder().encode(draft.layout)
        let fingerprint = Self.fingerprint(layoutData)
        // actor 在 await 处可重入：同一布局正在写时，后来者等同一个任务，不另写一份
        if let running = inFlight[fingerprint] {
            return (try await running.value, false)
        }
        if let existing = await list().first(where: { $0.meta.fingerprint == fingerprint }) {
            return (existing, false)
        }
        let task = Task { try await self.write(draft, layoutData: layoutData, fingerprint: fingerprint) }
        inFlight[fingerprint] = task
        defer { inFlight[fingerprint] = nil }
        return (try await task.value, true)
    }

    private func write(_ draft: WorkDraft, layoutData: Data, fingerprint: String) async throws -> WorkSummary {
        let fm = FileManager.default
        let id = WorkID()
        let temp = directory.appendingPathComponent(Self.tempPrefix + id.directoryName, isDirectory: true)
        let final = workDirectory(id)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            try layoutData.write(to: temp.appendingPathComponent(Self.layoutFileName), options: .atomic)
            let preview = try await images.writePreview(layout: draft.layout, target: draft.target,
                                                        overlayAlpha: draft.overlayAlpha,
                                                        maxLongEdge: WorkImageLimits.previewLongEdge, into: temp)
            var targetFile: String?
            if let t = draft.target {
                targetFile = try await images.writeTarget(t, maxLongEdge: WorkImageLimits.targetLongEdge, into: temp).fileName
            }
            let ids = draft.layout.uniqueAssetIDs
            let meta = WorkMeta(id: id, createdAt: now(), columns: draft.layout.cols, rows: draft.layout.rows,
                                tier: draft.tier, photoCount: ids.count, missingCount: 0,
                                overlayAlpha: draft.overlayAlpha, seed: draft.seed, fingerprint: fingerprint,
                                origin: draft.origin, previewFile: preview.fileName, previewPixelWidth: preview.pixelWidth,
                                previewPixelHeight: preview.pixelHeight, targetFile: targetFile)
            // meta.json 最后写：它在，其余文件一定都在
            try Self.encoder().encode(meta).write(to: temp.appendingPathComponent(Self.metaFileName), options: .atomic)
            try fm.moveItem(at: temp, to: final)
            return WorkSummary(meta: meta, previewURL: final.appendingPathComponent(meta.previewFile))
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    // MARK: 打开 / 删除 / 更新

    public func load(_ id: WorkID) async throws -> Work {
        let summary = try readSummary(id)
        let dir = workDirectory(id)
        let data: Data
        do { data = try Data(contentsOf: dir.appendingPathComponent(Self.layoutFileName)) } catch { throw WorksStoreError.corrupted }
        guard let layout = try? Self.decoder().decode(MosaicLayout.self, from: data) else { throw WorksStoreError.corrupted }
        let target = summary.meta.targetFile.map { dir.appendingPathComponent($0) }
        return Work(summary: summary, layout: layout,
                    targetURL: target.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }

    public func delete(_ id: WorkID) async throws {
        let fm = FileManager.default
        let dir = workDirectory(id)
        guard fm.fileExists(atPath: dir.path) else { throw WorksStoreError.notFound }
        let trash = directory.appendingPathComponent(Self.trashPrefix + id.directoryName + "-" + UUID().uuidString, isDirectory: true)
        try fm.moveItem(at: dir, to: trash)
        try? fm.removeItem(at: trash)
    }

    public func setMissingCount(_ count: Int, for id: WorkID) async throws {
        var meta = try readSummary(id).meta
        guard meta.missingCount != count else { return }
        meta.missingCount = count
        // 单文件原子替换（写临时文件再 rename）
        try Self.encoder().encode(meta).write(to: workDirectory(id).appendingPathComponent(Self.metaFileName), options: .atomic)
    }

    /// 补格结果的写回。原子性（单个作品目录内，不整目录替换——整目录 rename 两步之间被杀会丢作品）：
    /// 1. 新预览先写进 `.tmp-*`（启动时清），再 rename 成作品目录里的**新文件名** `preview-<随机>.jpg`；
    /// 2. meta.json 原子替换（指向新预览、新指纹、累计去掉张数）——从这一刻起列表 / 查看页只认新预览；
    /// 3. layout.json 原子替换；4. 删旧预览。
    /// 任一步被杀：1 后只多一个没人引用的文件；2 后布局还是旧的，下次打开会再查到缺失、重做一遍（幂等，只是
    /// 去掉张数可能多算一次）；不会出现「新布局 + 旧预览（还看得到隐藏照片）」。
    /// 指纹随新布局更新：从作品再导出成功后自动保存仍能查重命中，不会多出一份。
    public func applyRematch(_ result: WorkRematchResult, base: MosaicLayout, for id: WorkID) async throws -> Work {
        try await serialized(id) { try await self.performApply(result, base: base, for: id) }
    }

    /// 不补格、全部留白（测试 / 没有补格器时）。
    public func dropMissingPhotos(_ assetIDs: Set<String>, for id: WorkID) async throws -> Work {
        try await serialized(id) {
            let work = try await self.load(id)
            return try await self.performApply(.allBlank(work.layout, missing: assetIDs), base: work.layout, for: id)
        }
    }

    private func serialized(_ id: WorkID, _ body: @escaping @Sendable () async throws -> Work) async throws -> Work {
        while let running = updating[id] {
            _ = try? await running.task.value
            // 已完成的任务由这里清掉（发起方可能还没轮到恢复），否则会对着一个已完成的任务空转
            if updating[id]?.token == running.token { updating[id] = nil }
        }
        let token = UUID()
        let task = Task { try await body() }
        updating[id] = (token, task)
        defer { if updating[id]?.token == token { updating[id] = nil } }
        return try await task.value
    }

    private func performApply(_ result: WorkRematchResult, base: MosaicLayout, for id: WorkID) async throws -> Work {
        let work = try await load(id)
        let layout = result.layout
        guard work.layout == base, layout != base, layout.cols == base.cols, layout.rows == base.rows,
              layout.cellAssignments.count == base.cellAssignments.count else { return work }
        let fm = FileManager.default
        let dir = workDirectory(id)
        let temp = directory.appendingPathComponent(Self.tempPrefix + "preview-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        var meta = work.meta
        var target: PixelBuffer?
        if meta.overlayAlpha > 0, let url = work.targetURL { target = try? await images.readTarget(at: url) }
        let preview = try await images.writePreview(layout: layout, target: target, overlayAlpha: meta.overlayAlpha,
                                                    maxLongEdge: WorkImageLimits.previewLongEdge, into: temp)
        let ext = (preview.fileName as NSString).pathExtension
        let newName = "preview-" + UUID().uuidString.prefix(8).lowercased() + (ext.isEmpty ? "" : "." + ext)
        try fm.moveItem(at: temp.appendingPathComponent(preview.fileName), to: dir.appendingPathComponent(newName))

        let layoutData = try Self.encoder().encode(layout)
        let oldPreview = meta.previewFile
        meta.previewFile = newName
        meta.previewPixelWidth = preview.pixelWidth
        meta.previewPixelHeight = preview.pixelHeight
        meta.fingerprint = Self.fingerprint(layoutData)
        meta.photoCount = layout.uniqueAssetIDs.count
        meta.droppedPhotoCount += result.droppedPhotos
        meta.replacedCellCount += result.replacedCells
        meta.missingCount = meta.droppedPhotoCount
        do {
            try Self.encoder().encode(meta).write(to: dir.appendingPathComponent(Self.metaFileName), options: .atomic)
        } catch {
            try? fm.removeItem(at: dir.appendingPathComponent(newName))
            throw error
        }
        try layoutData.write(to: dir.appendingPathComponent(Self.layoutFileName), options: .atomic)
        if oldPreview != newName { try? fm.removeItem(at: dir.appendingPathComponent(oldPreview)) }
        return Work(summary: WorkSummary(meta: meta, previewURL: dir.appendingPathComponent(newName)), layout: layout,
                    targetURL: work.targetURL)
    }

    public func removeIncomplete() async {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) || name.hasPrefix(Self.trashPrefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: 编码

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]   // 指纹稳定
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    /// FNV-1a 64（不依赖 CryptoKit，Linux / iOS 一致）。
    static func fingerprint(_ data: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in data {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
