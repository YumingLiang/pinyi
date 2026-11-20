import Foundation
import MosaicCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 作品库（design/works-storage-v0.1.md）。
public protocol WorksStore: Sendable {
    /// 全部作品，按保存时间倒序（新的在前）。只读 meta.json。
    func list() async -> [WorkSummary]
    /// 保存（需求 B10）。指纹（`WorkFingerprint`：格子分配 + cols/rows + targetCrop + seed）相同的作品已存在时不另存：
    /// 叠加强度也相同 → `.unchanged`；只有叠加强度不同 → 更新那份的叠加强度和预览图（`.updatedOverlay`），日期、位置、布局不变。
    /// 已有多份同指纹（旧版本留下的重复）时用最新的那份，其余不动、不自动删。
    func save(_ draft: WorkDraft) async throws -> WorkSaveResult
    /// 打开（读显式布局）。
    func load(_ id: WorkID) async throws -> Work
    /// 删除整个作品目录。
    func delete(_ id: WorkID) async throws
    /// 记下最近一次检查到的缺失原照片数（列表 / 查看页提示用）。
    func setMissingCount(_ count: Int, for id: WorkID) async throws
    /// 写回一次补格结果（4b）：新布局、重画预览，累计 `replacedCellCount` / `fallbackCellCount` / `droppedPhotoCount`。
    /// 磁盘上的布局已经不是 `base`（期间别处已经处理过）或结果没有改动时，什么都不写，返回磁盘上的现状。
    /// `reasons`：缺失原照片 → 原因（`MissingReason`），只做统计。找不到相近照片的格子不论原因一律填目标图这一格的平均色
    /// （`CellAssignment.fill`，产品 03:55 Q1）；**不读旧预览、不写兜底图**。
    /// `migrateFallbacks`：旧版兜底（`WorkMeta.needsFallbackMigration`）整体作废，或 meta 和 layout 对不上（`Work.isLayoutOutOfSync`）：
    /// 旧兜底图删掉、仍空着的旧兜底格填目标平均色，即使布局没变也重画预览，写当前 `fallbackVersion`。
    func applyRematch(_ result: WorkRematchResult, base: MosaicLayout, for id: WorkID,
                      reasons: [String: MissingReason], migrateFallbacks: Bool) async throws -> Work
    /// 导出用的格子填充图：纯色格（`fill`）+ 旧版兜底格 + `transientCells`（还没处理的缺失格，受限访问 / 索引未就绪时临时补，
    /// **不**存盘），后两种一律填目标平均色；不读预览、不读兜底图（`transientReasons` 只做统计）。
    func fallbackTiles(for id: WorkID, transientCells: Set<Int>,
                       transientReasons: [Int: MissingReason]) async -> [Int: PixelBuffer]
    /// 启动时清理上次被杀留下的临时目录 / 待删目录，以及各作品目录里 meta 没登记的预览 / 兜底图（D-a）。
    func removeIncomplete() async
    /// 打开作品前清掉这个作品目录里 meta 没登记的预览 / 兜底图（D-a）。
    func removeOrphans(for id: WorkID) async
}

public extension WorksStore {
    func removeOrphans(for id: WorkID) async {}
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
/// - actor：保存 / 删除串行，「同一张不重复存」的查重不会被并发打穿（同指纹的保存排队，见 `inFlight`）。
/// - 数据版本 v1 → v2：读到 v1 的 meta（或 #17 早期内测包写的不带 seed 的指纹）时，按 layout.json 在**内存里**补算
///   内容指纹，用于命中；**只有命中并更新叠加强度时才把 meta.json 写成 v2**（QA A3），打开列表不写盘，装回旧包还能看到。
///   已经重复的旧作品不自动合并、不删。
/// - 更新叠加强度的原子性见 `updateOverlay`：meta.json 是唯一提交点，带 `pendingPreviewFile` 日志，被杀后读时前滚。
public actor FileWorksStore: WorksStore {
    public static let metaFileName = "meta.json"
    public static let layoutFileName = "layout.json"
    static let tempPrefix = ".tmp-"
    static let trashPrefix = ".trash-"

    public nonisolated let directory: URL
    private let images: any WorkImageEncoding
    private let now: @Sendable () -> Date
    /// 每个指纹最多一个正在写的任务（新存或更新叠加）；后来的同指纹保存等它写完再按最新状态决定。
    private var inFlight: [String: (token: UUID, task: Task<WorkSaveResult, any Error>)] = [:]
    /// 旧口径作品在内存里补算出的新指纹（不写盘，避免每次列表都读 layout.json）。
    private var recomputedFingerprints: [WorkID: String] = [:]
    /// 正在改写的作品（打开和导出前可能同时触发缺图处理）：同一作品串行。
    private var updating: [WorkID: (token: UUID, task: Task<Work, any Error>)] = [:]

    public init(directory: URL, images: any WorkImageEncoding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.images = images
        self.now = now
    }

    // MARK: 列表

    public func list() async -> [WorkSummary] { listNow() }

    /// 同步版（actor 内部用：查重和登记 inFlight 之间不能有挂起点）。
    private func listNow() -> [WorkSummary] {
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
        guard let decoded = try? Self.decoder().decode(WorkMeta.self, from: data) else { throw WorksStoreError.corrupted }
        guard decoded.formatVersion <= WorkMeta.currentFormatVersion else { throw WorksStoreError.unsupportedFormat(decoded.formatVersion) }
        guard decoded.id == id else { throw WorksStoreError.corrupted }
        let meta = currentFingerprint(rollForwardIfNeeded(decoded, in: dir), in: dir)
        let preview = dir.appendingPathComponent(meta.previewFile)
        guard FileManager.default.fileExists(atPath: preview.path) else { throw WorksStoreError.corrupted }
        return WorkSummary(meta: meta, previewURL: preview)
    }

    // MARK: 保存

    public func save(_ draft: WorkDraft) async throws -> WorkSaveResult {
        if draft.layout.cellAssignments.contains(where: { $0.fill != nil }) { throw WorksError.unsupportedFilledCells }
        if draft.layout.shapeFrame != nil { throw WorksError.unsupportedShapeSave }
        let fingerprint = WorkFingerprint.of(draft.layout)
        // actor 在 await 处可重入：同一张正在写（新存或更新叠加）时，后来者先等它写完，再按磁盘上的最新状态决定
        var waited: UUID?
        while let running = inFlight[fingerprint], running.token != waited {
            waited = running.token
            _ = try? await running.task.value
        }
        // 从这里到登记 inFlight 之间没有挂起点
        let existing = WorkSummary.saveTarget(in: listNow(), fingerprint: fingerprint, preferred: draft.preferredWorkID)
        let task: Task<WorkSaveResult, any Error>
        if let existing {
            if WorkFingerprint.sameOverlay(existing.meta.overlayAlpha, draft.overlayAlpha) {
                return WorkSaveResult(summary: existing, outcome: .unchanged)
            }
            task = Task { try await self.updateOverlay(existing, with: draft, fingerprint: fingerprint) }
        } else {
            let layoutData = try Self.encoder().encode(draft.layout)
            task = Task {
                WorkSaveResult(summary: try await self.write(draft, layoutData: layoutData, fingerprint: fingerprint),
                               outcome: .inserted)
            }
        }
        let token = UUID()
        inFlight[fingerprint] = (token, task)
        defer { if inFlight[fingerprint]?.token == token { inFlight[fingerprint] = nil } }
        return try await task.value
    }

    private func write(_ draft: WorkDraft, layoutData: Data, fingerprint: String) async throws -> WorkSummary {
        // 预览和再导出已经按同一 `cellPaint` 读 `fc`。带 `fc` 或形状的作品仍不写盘：Apple 像素验收通过之前不解除这两道守护。
        if draft.layout.cellAssignments.contains(where: { $0.fill != nil }) { throw WorksError.unsupportedFilledCells }
        let fm = FileManager.default
        let id = WorkID()
        let temp = directory.appendingPathComponent(Self.tempPrefix + id.directoryName, isDirectory: true)
        let final = workDirectory(id)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            try layoutData.write(to: temp.appendingPathComponent(Self.layoutFileName), options: .atomic)
            // 新存的作品不带兜底图（结果页的布局没有兜底格；万一带了标记，按缺图画）
            let preview = try await images.writePreview(layout: draft.layout, target: draft.target,
                                                        overlayAlpha: draft.overlayAlpha,
                                                        maxLongEdge: WorkImageLimits.previewLongEdge, fallbacks: [:], into: temp)
            var targetFile: String?
            if let t = draft.target {
                targetFile = try await images.writeTarget(t, maxLongEdge: WorkImageLimits.targetLongEdge, into: temp).fileName
            }
            let ids = draft.layout.uniqueAssetIDs
            var meta = WorkMeta(id: id, createdAt: now(), columns: draft.layout.cols, rows: draft.layout.rows,
                                tier: draft.tier, photoCount: ids.count, missingCount: 0,
                                overlayAlpha: draft.overlayAlpha, seed: draft.seed, fingerprint: fingerprint,
                                origin: draft.origin, previewFile: preview.fileName, previewPixelWidth: preview.pixelWidth,
                                previewPixelHeight: preview.pixelHeight, targetFile: targetFile)
            meta.fallbackVersion = WorkMeta.currentFallbackVersion
            // meta.json 最后写：它在，其余文件一定都在
            try Self.encoder().encode(meta).write(to: temp.appendingPathComponent(Self.metaFileName), options: .atomic)
            try fm.moveItem(at: temp, to: final)
            return WorkSummary(meta: meta, previewURL: final.appendingPathComponent(meta.previewFile))
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// 只改了叠加强度（B10-3、B10-8 覆盖不留历史）：重画预览图、更新 meta 的叠加强度 / 预览尺寸 / `updatedAt`，
    /// 以及 layout.json 里的 `params.overlayAlpha`；`id`、`createdAt`（→ 列表位置）、格子分配、目标图副本都不动，文件名也不变。
    ///
    /// 原子性（QA PR #17 复核 P3「更新途中被杀，强度和预览对不上」）：**meta.json 是唯一提交点**，其余文件都能按它前滚。
    /// ① 新预览图先在 `.tmp-*` 里画好，挪进作品目录，叫 `.preview-pending-<uuid>.<ext>`；
    /// ② 原子写 meta.json：新强度 + `pendingPreviewFile = 那个临时名`（提交点）；
    /// ③ `rename(2)` 把临时预览原子换到 `previewFile`（任何时刻 preview 文件都存在）；
    /// ④ 原子写 layout.json（新强度）；⑤ 原子写 meta.json 清掉 `pendingPreviewFile`。
    /// 被杀时：② 之前 → 作品还是旧强度、旧预览，残留的临时预览启动时清掉（`removeIncomplete`）；
    /// ② 之后 → 下次读 meta 看到 `pendingPreviewFile` 就把它换过去再清日志（`rollForwardIfNeeded`）；
    /// layout.json 没来得及改时，`load` 以 meta 的强度为准（`updatedAt != nil` 的作品）。所以不会出现强度和预览永久不一致。
    private func updateOverlay(_ existing: WorkSummary, with draft: WorkDraft, fingerprint: String) async throws -> WorkSaveResult {
        let fm = FileManager.default
        let id = existing.id
        let dir = workDirectory(id)
        let temp = directory.appendingPathComponent(Self.tempPrefix + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        let layoutURL = dir.appendingPathComponent(Self.layoutFileName)
        guard let layoutData = try? Data(contentsOf: layoutURL),
              var layout = try? Self.decoder().decode(MosaicLayout.self, from: layoutData) else {
            throw WorksStoreError.corrupted
        }
        layout.params.overlayAlpha = draft.overlayAlpha
        // 叠加要用目标图：优先用结果页手里的那份，没有就读作品里存的副本
        var target = draft.target
        if target == nil, let file = existing.meta.targetFile {
            target = try? await images.readTarget(at: dir.appendingPathComponent(file))
        }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        // 兜底格（#11）：存的兜底小图已去掉叠加，换强度后照样放大填满，不出白格
        let tiles = layout.cellAssignments.contains { $0.fallback || $0.fill != nil } ? await fallbackTiles(for: id, transientCells: []) : [:]
        let preview = try await images.writePreview(layout: layout, target: target, overlayAlpha: draft.overlayAlpha,
                                                    maxLongEdge: WorkImageLimits.previewLongEdge, fallbacks: tiles, into: temp)
        // 挂起期间可能被删：作品目录不在了就不写回（不复活、不换新 id），按「没找到」处理。从这里到结束没有挂起点。
        guard fm.fileExists(atPath: dir.appendingPathComponent(Self.metaFileName).path) else { throw WorksStoreError.notFound }
        var meta = try readSummary(id).meta
        // ① 新预览挪进作品目录（临时名）
        let ext = (preview.fileName as NSString).pathExtension
        let pendingName = Self.pendingPreviewPrefix + UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let pendingURL = dir.appendingPathComponent(pendingName)
        try Self.atomicReplace(temp.appendingPathComponent(preview.fileName), over: pendingURL)
        // ② 提交点：meta 带新强度和日志
        meta.overlayAlpha = draft.overlayAlpha
        meta.previewPixelWidth = preview.pixelWidth
        meta.previewPixelHeight = preview.pixelHeight
        meta.fingerprint = fingerprint
        meta.formatVersion = WorkMeta.currentFormatVersion
        meta.updatedAt = now()
        meta.pendingPreviewFile = pendingName
        do {
            try Self.encoder().encode(meta).write(to: dir.appendingPathComponent(Self.metaFileName), options: .atomic)
        } catch {
            try? fm.removeItem(at: pendingURL)
            throw error
        }
        // ③–⑤ 前滚（和被杀后下次读时走的是同一段代码）
        meta = rollForwardIfNeeded(meta, in: dir, layout: layout)
        return WorkSaveResult(summary: WorkSummary(meta: meta, previewURL: dir.appendingPathComponent(meta.previewFile)),
                              outcome: .updatedOverlay)
    }

    /// 更新叠加强度时作品目录里的临时预览图前缀（见 `updateOverlay`）。
    static let pendingPreviewPrefix = ".preview-pending-"

    /// 按 `pendingPreviewFile` 日志前滚：临时预览还在就原子换到 `previewFile`；layout.json 的强度对齐 meta；清掉日志写回 meta。
    /// 每一步都是幂等的；某一步写不下去（只读卷等）就保留日志，下次读再试，返回的 meta 照样以提交的新强度为准。
    private func rollForwardIfNeeded(_ meta: WorkMeta, in dir: URL, layout knownLayout: MosaicLayout? = nil) -> WorkMeta {
        guard let pending = meta.pendingPreviewFile else { return meta }
        let fm = FileManager.default
        let pendingURL = dir.appendingPathComponent(pending)
        if fm.fileExists(atPath: pendingURL.path) {
            guard (try? Self.atomicReplace(pendingURL, over: dir.appendingPathComponent(meta.previewFile))) != nil else { return meta }
        }
        let layoutURL = dir.appendingPathComponent(Self.layoutFileName)
        var layout = knownLayout
        if layout == nil, let data = try? Data(contentsOf: layoutURL) {
            layout = try? Self.decoder().decode(MosaicLayout.self, from: data)
        }
        if var l = layout {
            if !WorkFingerprint.sameOverlay(l.params.overlayAlpha, meta.overlayAlpha) || knownLayout != nil {
                l.params.overlayAlpha = meta.overlayAlpha
                guard (try? Self.encoder().encode(l).write(to: layoutURL, options: .atomic)) != nil else { return meta }
            }
        }
        var done = meta
        done.pendingPreviewFile = nil
        if let encoded = try? Self.encoder().encode(done) {
            try? encoded.write(to: dir.appendingPathComponent(Self.metaFileName), options: .atomic)
        }
        return done
    }

    /// 同一卷上用 `rename(2)` 原子替换文件（目标存在就整体换掉，不会出现「没有这个文件」的瞬间）。
    static func atomicReplace(_ source: URL, over destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    /// 旧口径指纹（meta v1：整个布局 JSON 的哈希；或 #17 早期内测包写的不带 seed 的 v2）按当前口径补算：
    /// 读 layout.json 算 `WorkFingerprint`，**只放在内存里**用于命中，不写盘（QA A3：只有命中并更新时 `updateOverlay`
    /// 才把 meta 写成 v2）。`formatVersion` 保持磁盘上的值。layout.json 读不出来就保持原样（这种作品本来也打不开）。
    private func currentFingerprint(_ meta: WorkMeta, in dir: URL) -> WorkMeta {
        guard meta.formatVersion < WorkMeta.currentFormatVersion || !WorkFingerprint.isCurrent(meta.fingerprint) else { return meta }
        var m = meta
        if let cached = recomputedFingerprints[meta.id] {
            m.fingerprint = cached
            return m
        }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.layoutFileName)),
              let layout = try? Self.decoder().decode(MosaicLayout.self, from: data) else { return meta }
        m.fingerprint = WorkFingerprint.of(layout)
        recomputedFingerprints[meta.id] = m.fingerprint
        return m
    }

    // MARK: 打开 / 删除 / 更新

    public func load(_ id: WorkID) async throws -> Work {
        let summary = try readSummary(id)
        let dir = workDirectory(id)
        let data: Data
        do { data = try Data(contentsOf: dir.appendingPathComponent(Self.layoutFileName)) } catch { throw WorksStoreError.corrupted }
        guard var layout = try? Self.decoder().decode(MosaicLayout.self, from: data) else { throw WorksStoreError.corrupted }
        // 更新过叠加强度的作品以 meta（提交点）的强度为准：layout.json 被杀前没来得及改也不会和预览 / 列表对不上
        if summary.meta.updatedAt != nil { layout.params.overlayAlpha = summary.meta.overlayAlpha }
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
    /// 0. 找不到替代的格子（本次新出现的）**先**从旧预览裁出兜底图（`WorkFallbackImages.crop`，去掉叠加）；之前就兜底、这次仍没补上的
    ///    直接搬旧兜底图；补上了照片的格子丢掉兜底图（升级）。没有旧预览（读不出 / 尺寸不对）的格子才留白。
    /// 1. 新兜底图、新预览先写进 `.tmp-*`（启动时清），再 rename 成作品目录里的**新文件名** `fallback-<随机>.png` / `preview-<随机>.jpg`；
    /// 2. meta.json 原子替换（指向新预览 / 新兜底图、新指纹、累计计数）——从这一刻起列表 / 查看页只认新文件；
    /// 3. layout.json 原子替换；4. 删旧预览、旧兜底图。
    /// 任一步被杀：1 后只多没人引用的文件；2 后布局还是旧的，下次打开会再查到缺失、重做一遍（幂等，只是累计数可能多算一次）；
    /// 不会出现「新布局 + 旧预览（还看得到隐藏照片）」。
    /// 指纹随新布局更新：从作品再导出成功后自动保存仍能查重命中，不会多出一份。
    public func applyRematch(_ result: WorkRematchResult, base: MosaicLayout, for id: WorkID,
                             reasons: [String: MissingReason] = [:], migrateFallbacks: Bool = false) async throws -> Work {
        try await serialized(id) {
            try await self.performApply(result, base: base, for: id, reasons: reasons, migrate: migrateFallbacks)
        }
    }

    /// 不补格、全部兜底 / 留白（测试 / 没有补格器时）。
    public func dropMissingPhotos(_ assetIDs: Set<String>, for id: WorkID,
                                  reasons: [String: MissingReason] = [:]) async throws -> Work {
        try await serialized(id) {
            let work = try await self.load(id)
            return try await self.performApply(.allBlank(work.layout, missing: assetIDs), base: work.layout, for: id,
                                               reasons: reasons, migrate: false)
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

    private func readOverlayTarget(_ work: Work) async -> PixelBuffer? {
        guard work.meta.overlayAlpha > 0, let url = work.targetURL else { return nil }
        return try? await images.readTarget(at: url)
    }

    /// 导出 / 叠加重画用的补格小图：纯色格（`fc`）按存的颜色；旧版兜底格（`fb`，还没迁移）和这次临时补的缺失格一律按目标平均色。
    /// 产品 03:55 Q1：**任何补格都不读旧预览、也不读存盘兜底图**（`transientReasons` 只做统计，不决定像素）。
    public func fallbackTiles(for id: WorkID, transientCells: Set<Int>,
                              transientReasons: [Int: MissingReason] = [:]) async -> [Int: PixelBuffer] {
        guard let work = try? await load(id) else { return [:] }
        var tiles = MissingCellFill.colorTiles(work.layout)
        let marked = work.layout.cellAssignments.indices.filter { work.layout.cellAssignments[$0].fallback }
        let extra = transientCells.union(marked).filter { tiles[$0] == nil && $0 < work.layout.cellAssignments.count }.sorted()
        guard !extra.isEmpty else { return tiles }
        let target = await readTargetCopy(work)
        var l = work.layout
        for cell in extra { l.cellAssignments[cell].fill = MissingCellFill.targetColor(cell: cell, layout: work.layout, target: target) }
        let colored = MissingCellFill.colorTiles(l)
        for cell in extra { if let t = colored[cell] { tiles[cell] = t } }
        return tiles
    }

    /// 目标图副本（算纯色格的平均色用；与叠加强度无关）。
    private func readTargetCopy(_ work: Work) async -> PixelBuffer? {
        guard let url = work.targetURL else { return nil }
        return try? await images.readTarget(at: url)
    }

    private func performApply(_ result: WorkRematchResult, base: MosaicLayout, for id: WorkID,
                              reasons: [String: MissingReason], migrate: Bool) async throws -> Work {
        let work = try await load(id)
        let migrate = migrate && (work.meta.needsFallbackMigration || work.isLayoutOutOfSync)   // 别处已处理过：按普通写回
        var layout = result.layout
        guard work.layout == base, layout.cols == base.cols, layout.rows == base.rows,
              layout.cellAssignments.count == base.cellAssignments.count else { return work }
        // 找不到相近照片的格子怎么补（`MissingCellFill.decide`，产品 03:55 Q1 取消 4b）：
        // - 本次新空出来的：不论原因（隐藏 / 删除 / 拿不准）一律填目标图平均色（`fill`），**不读旧预览**；`reasons` 只做统计。
        // - 之前就纯色、这次仍没补上的：颜色不变。旧版兜底格（`fb`）仍空着的：旧兜底图整体作废，同样填目标色。
        // - 补上了照片的：去掉纯色。不再产生新的 WorkFallbackImages 兜底图。
        _ = reasons
        let cells = base.cellAssignments.indices
        let newlyEmpty = cells.filter { !base.cellAssignments[$0].localIdentifier.isEmpty && layout.cellAssignments[$0].localIdentifier.isEmpty }
        let oldFallbackCells = cells.filter { base.cellAssignments[$0].fallback && layout.cellAssignments[$0].localIdentifier.isEmpty }
        for i in cells {
            layout.cellAssignments[i].fallback = false
            let stillEmpty = layout.cellAssignments[i].localIdentifier.isEmpty
            layout.cellAssignments[i].fill = stillEmpty ? base.cellAssignments[i].fill : nil
        }
        let colorCells = newlyEmpty + oldFallbackCells
        let target = await readOverlayTarget(work)
        if !colorCells.isEmpty {
            let copy = target != nil ? target : await readTargetCopy(work)   // 叠加时已读过就复用
            for cell in colorCells { layout.cellAssignments[cell].fill = MissingCellFill.targetColor(cell: cell, layout: base, target: copy) }
        }
        guard layout != base || migrate else { return work }   // 迁移 / 对齐：即使布局没变也要重画预览、写当前版本
        // 纯色格的填充图：预览重画用；导出同样经 `fallbackTiles` 拿到同一颜色
        let drawTiles = MissingCellFill.colorTiles(layout)

        let fm = FileManager.default
        let dir = workDirectory(id)
        let temp = directory.appendingPathComponent(Self.tempPrefix + "preview-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        var meta = work.meta
        let preview = try await images.writePreview(layout: layout, target: target, overlayAlpha: meta.overlayAlpha,
                                                    maxLongEdge: WorkImageLimits.previewLongEdge, fallbacks: drawTiles, into: temp)
        let fallbackName: String? = nil   // 不再写兜底图
        var moved: [URL] = []
        func unique(_ prefix: String, _ file: String) -> String {
            let ext = (file as NSString).pathExtension
            return prefix + UUID().uuidString.prefix(8).lowercased() + (ext.isEmpty ? "" : "." + ext)
        }
        do {
            let newName = unique("preview-", preview.fileName)
            try fm.moveItem(at: temp.appendingPathComponent(preview.fileName), to: dir.appendingPathComponent(newName))
            moved.append(dir.appendingPathComponent(newName))

            let layoutData = try Self.encoder().encode(layout)
            let oldPreview = meta.previewFile
            let oldFallback = meta.fallbackFile
            meta.previewFile = newName
            meta.previewPixelWidth = preview.pixelWidth
            meta.previewPixelHeight = preview.pixelHeight
            meta.fallbackFile = fallbackName
            meta.fallbackVersion = WorkMeta.currentFallbackVersion
            meta.fingerprint = WorkFingerprint.of(layout)   // 当前口径（#17）；原来写的是 v1 口径
            meta.photoCount = layout.uniqueAssetIDs.count
            meta.droppedPhotoCount += result.droppedPhotos
            meta.replacedCellCount += result.replacedCells
            meta.fallbackCellCount += newlyEmpty.count
            meta.missingCount = 0   // 都处理过了（替换 / 兜底 / 留白），没有待处理的缺失
            try Self.encoder().encode(meta).write(to: dir.appendingPathComponent(Self.metaFileName), options: .atomic)
            moved = []   // meta 已指向新文件：之后失败也不删它们
            try layoutData.write(to: dir.appendingPathComponent(Self.layoutFileName), options: .atomic)
            if oldPreview != newName { try? fm.removeItem(at: dir.appendingPathComponent(oldPreview)) }
            if let oldFallback, oldFallback != fallbackName { try? fm.removeItem(at: dir.appendingPathComponent(oldFallback)) }
            return Work(summary: WorkSummary(meta: meta, previewURL: dir.appendingPathComponent(newName)), layout: layout,
                        targetURL: work.targetURL)
        } catch {
            for url in moved { try? fm.removeItem(at: url) }
            throw error
        }
    }

    public func removeIncomplete() async {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) || name.hasPrefix(Self.trashPrefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        // 每个作品目录里 meta 没登记的预览 / 兜底图（架构师 11-17 D-a）：写回在提交点（meta.json）前后被杀留下的
        // 新文件 / 旧文件都可能带隐藏照片的像素，又会进 iCloud 备份，一律删掉。
        for name in names where !name.hasPrefix(".") {
            guard let id = WorkID(directoryName: name) else { continue }
            removeOrphanImages(id)
        }
    }

    /// 打开作品前也清一次（`WorksController.open`）。
    public func removeOrphans(for id: WorkID) async {
        removeOrphanImages(id)
    }

    /// 删掉作品目录里 meta 没登记（`previewFile` / `fallbackFile` / `pendingPreviewFile`）的 `preview*` / `fallback*` /
    /// 临时预览文件。meta 读不出来就什么都不删。这个作品正在写回（`serialized` 里，新文件已挪进来、meta 还没提交）时跳过；
    /// actor 内从判断到删完没有挂起点，不会和写回交错。
    private func removeOrphanImages(_ id: WorkID) {
        guard updating[id] == nil else { return }
        let fm = FileManager.default
        let dir = workDirectory(id)
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path),
              let data = try? Data(contentsOf: dir.appendingPathComponent(Self.metaFileName)),
              let meta = try? Self.decoder().decode(WorkMeta.self, from: data) else { return }
        let referenced = Set([meta.previewFile, meta.fallbackFile, meta.pendingPreviewFile].compactMap { $0 })
        for f in files where !referenced.contains(f)
            && (f.hasPrefix("preview") || f.hasPrefix("fallback") || f.hasPrefix(Self.pendingPreviewPrefix)) {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
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

    /// 内容指纹（= `WorkFingerprint.of`，QA works-rules 接口名 A2）：含 seed，不含叠加强度、档位、密度名。
    public static func contentFingerprint(_ layout: MosaicLayout) -> String { WorkFingerprint.of(layout) }

    /// FNV-1a 64（不依赖 CryptoKit，Linux / iOS 一致）。v1 指纹 = 布局 JSON 的这个值；现在只给测试造旧作品用。
    static func fingerprint(_ data: Data) -> String {
        var h = FNV1a64()
        h.add([UInt8](data))
        return h.hex
    }
}
