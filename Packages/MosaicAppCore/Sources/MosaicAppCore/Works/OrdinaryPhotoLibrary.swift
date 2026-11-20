import Foundation
import MosaicCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 普通照片（没有形状框、没有 manifest）的内容比较。
/// `cd1-` 只是 64 位 FNV，命中前还要逐项比格子、fc 和 fb。缺 meta 摘要时只从 layout 现算，不写回。
enum OrdinaryPhotoContent {
    static func isGuarded(_ layout: MosaicLayout) -> Bool {
        guard layout.shapeFrame == nil, layout.shapeManifest == nil else { return false }
        return layout.cellAssignments.contains { $0.fill != nil || $0.fallback }
    }

    /// 按钮缓存用的内容键。`cd1-` 本身不含 fb 和强度，这里另加上量化强度和逐格 fb。
    /// 这不是 `inFlight` 队列键。带 fc 的公开保存仍在登记队列前返回。
    static func flightKey(_ layout: MosaicLayout) -> String {
        var parts = [WorkContentDigest.of(layout), String(FNV1a64.quantize(layout.params.overlayAlpha))]
        for cell in layout.cellAssignments { parts.append(cell.fallback ? "1" : "0") }
        return parts.joined(separator: "|")
    }

    static func same(_ draft: MosaicLayout, _ stored: MosaicLayout, metaOverlay: Double) -> Bool {
        guard draft.shapeFrame == nil, stored.shapeFrame == nil,
              draft.shapeManifest == nil, stored.shapeManifest == nil else { return false }
        guard WorkContentDigest.of(draft) == WorkContentDigest.of(stored) else { return false }
        guard draft.cols == stored.cols, draft.rows == stored.rows, draft.params.seed == stored.params.seed else { return false }
        guard quantize(draft.targetCrop) == quantize(stored.targetCrop) else { return false }
        guard draft.targetSize == stored.targetSize else { return false }
        guard WorkFingerprint.sameOverlay(draft.params.overlayAlpha, stored.params.overlayAlpha),
              WorkFingerprint.sameOverlay(draft.params.overlayAlpha, metaOverlay) else { return false }
        guard draft.cellAssignments.count == stored.cellAssignments.count else { return false }
        for (left, right) in zip(draft.cellAssignments, stored.cellAssignments) {
            guard left.localIdentifier == right.localIdentifier,
                  quantize(left.crop) == quantize(right.crop),
                  left.fallback == right.fallback,
                  left.fill == right.fill else { return false }
        }
        return true
    }

    private static func quantize(_ crop: CropRect) -> (Int64, Int64, Int64, Int64) {
        (FNV1a64.quantize(crop.x), FNV1a64.quantize(crop.y), FNV1a64.quantize(crop.width), FNV1a64.quantize(crop.height))
    }

}

struct OrdinaryPhotoHit {
    var summary: WorkSummary
    var blocksEquivalence: Bool
    var fingerprint: String
}

/// 只读扫作品目录。不调用会前滚或清文件的列表、打开和补格入口。
enum OrdinaryPhotoLibrary {
    static let transactionPrefix = ".tmp-fc-new-"

    static func scan(directory: URL, draft: MosaicLayout, preferred: WorkID?, explicit: WorkID?) -> [OrdinaryPhotoHit] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var hits: [OrdinaryPhotoHit] = []
        for name in names where !name.hasPrefix(".") {
            guard let id = WorkID(directoryName: name) else { continue }
            guard let hit = read(directory: directory, id: id, draft: draft, preferred: preferred, explicit: explicit) else { continue }
            hits.append(hit)
        }
        return hits
    }

    /// 高版本或坏 meta 直接跳过，不删除。返回仍在磁盘上的目录名。
    static func untouchedNames(directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private static func read(directory: URL, id: WorkID, draft: MosaicLayout, preferred: WorkID?, explicit: WorkID?) -> OrdinaryPhotoHit? {
        let dir = directory.appendingPathComponent(id.directoryName, isDirectory: true)
        let metaURL = dir.appendingPathComponent(FileWorksStore.metaFileName)
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? FileWorksStore.decoder().decode(WorkMeta.self, from: metaData),
              meta.id == id else { return nil }
        if meta.formatVersion > WorkMeta.currentFormatVersion { return nil }
        let layoutURL = dir.appendingPathComponent(FileWorksStore.layoutFileName)
        guard let layoutData = try? Data(contentsOf: layoutURL),
              let layout = try? FileWorksStore.decoder().decode(MosaicLayout.self, from: layoutData) else {
            return referenced(id, preferred: preferred, explicit: explicit) ? blocked(meta, dir) : nil
        }
        if layout.shapeFrame != nil || layout.shapeManifest != nil { return nil }
        let fingerprint = WorkFingerprint.of(layout)
        let related = fingerprint == WorkFingerprint.of(draft) || referenced(id, preferred: preferred, explicit: explicit)
        guard related else { return nil }
        let previewName = meta.previewFile
        let previewOK = safeBasename(previewName)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent(previewName).path)
        let agrees = WorkFingerprint.sameOverlay(layout.params.overlayAlpha, meta.overlayAlpha)
        let summary = WorkSummary(meta: meta, previewURL: dir.appendingPathComponent(previewName))
        if meta.pendingPreviewFile != nil {
            return OrdinaryPhotoHit(summary: summary, blocksEquivalence: true, fingerprint: fingerprint)
        }
        guard previewOK, agrees, OrdinaryPhotoContent.same(draft, layout, metaOverlay: meta.overlayAlpha) else { return nil }
        return OrdinaryPhotoHit(summary: summary, blocksEquivalence: false, fingerprint: fingerprint)
    }

    private static func blocked(_ meta: WorkMeta, _ dir: URL) -> OrdinaryPhotoHit {
        OrdinaryPhotoHit(summary: WorkSummary(meta: meta, previewURL: dir.appendingPathComponent(meta.previewFile)),
                         blocksEquivalence: true, fingerprint: meta.fingerprint)
    }

    private static func referenced(_ id: WorkID, preferred: WorkID?, explicit: WorkID?) -> Bool {
        id == preferred || id == explicit
    }

    static func safeBasename(_ name: String) -> Bool {
        name == (name as NSString).lastPathComponent && !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
    }
}

enum DirectoryRename {
    /// 同卷、不覆盖的目录发布。检查「目标不存在」不能代替这个调用。
    static func exclusive(from: URL, to: URL) throws {
        let rc: Int32 = from.withUnsafeFileSystemRepresentation { src in
            to.withUnsafeFileSystemRepresentation { dst in
                guard let src, let dst else { return Int32(EINVAL) }
                #if canImport(Darwin)
                return renameExclusiveDarwin(src, dst)
                #else
                return renameat2(-100, src, -100, dst, 1)
                #endif
            }
        }
        if rc == 0 { return }
        if errno == EEXIST || errno == ENOTEMPTY { throw WorksError.publishCollision }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: to.path])
    }
}

#if canImport(Darwin)
private func renameExclusiveDarwin(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>) -> Int32 {
    renamex_np(from, to, 0x4)
}
#endif

#if canImport(Glibc)
@_silgen_name("renameat2")
private func renameat2(_ olddirfd: Int32, _ oldpath: UnsafePointer<CChar>?, _ newdirfd: Int32, _ newpath: UnsafePointer<CChar>?, _ flags: UInt32) -> Int32
#endif

extension FileWorksStore {
    /// 纯读等价。全等时调用方返回原 ID，不写旧库、不解码旧图。
    func matchOrdinaryPhoto(_ draft: WorkDraft) -> (equivalent: WorkSummary?, blocked: Bool) {
        let hits = OrdinaryPhotoLibrary.scan(directory: directory, draft: draft.layout,
                                             preferred: draft.preferredWorkID, explicit: draft.updateWorkID)
        if hits.contains(where: { $0.blocksEquivalence }) { return (nil, true) }
        let equivalent = hits.filter { !$0.blocksEquivalence }.map(\.summary)
        let fingerprint = WorkFingerprint.of(draft.layout)
        return (WorkSummary.saveTarget(in: equivalent, fingerprint: fingerprint, preferred: draft.preferredWorkID), false)
    }

    func saveFilledOrdinaryPhoto(_ draft: WorkDraft) throws -> WorkSaveResult {
        var draft = draft
        draft.layout.params.overlayAlpha = draft.overlayAlpha
        if let explicit = draft.updateWorkID {
            return try saveExplicitOrdinaryPhoto(draft, id: explicit)
        }
        let match = matchOrdinaryPhoto(draft)
        if match.blocked { throw WorksError.cannotProvePhotoEquivalence }
        if let existing = match.equivalent {
            return WorkSaveResult(summary: existing, outcome: .unchanged)
        }
        throw WorksError.unsupportedFilledCells
    }

    private func saveExplicitOrdinaryPhoto(_ draft: WorkDraft, id: WorkID) throws -> WorkSaveResult {
        let dir = directory.appendingPathComponent(id.directoryName, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorksStoreError.notFound
        }
        let match = matchOrdinaryPhoto(draft)
        if match.blocked { throw WorksError.cannotProvePhotoEquivalence }
        if let existing = match.equivalent, existing.id == id {
            return WorkSaveResult(summary: existing, outcome: .unchanged)
        }
        throw WorksError.unsupportedExistingWorkUpdate
    }

    /// 测试里的新建事务。公开 `save` 在守护解除前不会走到这里。
    /// 不写 contentDigest / revision。中止只删本次未发布的 `.tmp-fc-new-` 目录。
    func publishNewFilledPhoto(_ draft: WorkDraft, id: WorkID = WorkID(), sourceLayoutAtStart: Data? = nil, sourceID: WorkID? = nil) async throws -> WorkSaveResult {
        let fm = FileManager.default
        let tx = UUID().uuidString
        let temp = directory.appendingPathComponent(OrdinaryPhotoLibrary.transactionPrefix + tx, isDirectory: true)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        } catch {
            throw WorksError.publishCollision
        }
        do {
            return try await writeAndPublish(draft, id: id, temp: temp, sourceLayoutAtStart: sourceLayoutAtStart, sourceID: sourceID)
        } catch {
            discardUnpublished(temp)
            throw error
        }
    }

    /// 发布后回执丢了：只能只读认出同一份内容。认不出就报不确定，不删目录、不重建。
    func readPublishedFilledPhoto(id: WorkID, expecting layout: MosaicLayout) throws -> WorkSummary {
        let dir = directory.appendingPathComponent(id.directoryName, isDirectory: true)
        guard let metaData = try? Data(contentsOf: dir.appendingPathComponent(Self.metaFileName)),
              let meta = try? Self.decoder().decode(WorkMeta.self, from: metaData),
              meta.id == id,
              let layoutData = try? Data(contentsOf: dir.appendingPathComponent(Self.layoutFileName)),
              let stored = try? Self.decoder().decode(MosaicLayout.self, from: layoutData),
              OrdinaryPhotoContent.same(layout, stored, metaOverlay: meta.overlayAlpha),
              meta.pendingPreviewFile == nil else {
            throw WorksError.publishResultUncertain
        }
        let preview = dir.appendingPathComponent(meta.previewFile)
        guard FileManager.default.fileExists(atPath: preview.path) else { throw WorksError.publishResultUncertain }
        return WorkSummary(meta: meta, previewURL: preview)
    }

    private func writeAndPublish(_ draft: WorkDraft, id: WorkID, temp: URL, sourceLayoutAtStart: Data?, sourceID: WorkID?) async throws -> WorkSaveResult {
        var layout = draft.layout
        layout.params.overlayAlpha = draft.overlayAlpha
        let layoutData = try Self.encoder().encode(layout)
        try layoutData.write(to: temp.appendingPathComponent(Self.layoutFileName), options: .atomic)
        let preview = try await images.writePreview(layout: layout, target: draft.target, overlayAlpha: draft.overlayAlpha,
                                                    maxLongEdge: WorkImageLimits.previewLongEdge, fallbacks: [:], into: temp)
        guard OrdinaryPhotoLibrary.safeBasename(preview.fileName),
              preview.fileName != Self.layoutFileName, preview.fileName != Self.metaFileName else {
            throw ExportError.encodingFailed
        }
        var targetFile: String?
        if let target = draft.target {
            let written = try await images.writeTarget(target, maxLongEdge: WorkImageLimits.targetLongEdge, into: temp)
            guard OrdinaryPhotoLibrary.safeBasename(written.fileName) else { throw ExportError.encodingFailed }
            targetFile = written.fileName
        }
        guard FileManager.default.fileExists(atPath: temp.appendingPathComponent(preview.fileName).path) else {
            throw ExportError.encodingFailed
        }
        let fingerprint = WorkFingerprint.of(layout)
        var meta = WorkMeta(id: id, createdAt: now(), columns: layout.cols, rows: layout.rows, tier: draft.tier,
                            photoCount: layout.uniqueAssetIDs.count, missingCount: 0, overlayAlpha: draft.overlayAlpha,
                            seed: layout.params.seed, fingerprint: fingerprint, origin: draft.origin,
                            previewFile: preview.fileName, previewPixelWidth: preview.pixelWidth,
                            previewPixelHeight: preview.pixelHeight, targetFile: targetFile)
        meta.fallbackVersion = WorkMeta.currentFallbackVersion
        let metaData = try Self.encoder().encode(meta)
        try metaData.write(to: temp.appendingPathComponent(Self.metaFileName), options: .atomic)
        if let sourceID, let sourceLayoutAtStart {
            let sourceURL = directory.appendingPathComponent(sourceID.directoryName).appendingPathComponent(Self.layoutFileName)
            let nowLayout = try? Data(contentsOf: sourceURL)
            if nowLayout != sourceLayoutAtStart { throw WorksError.cannotProvePhotoEquivalence }
        }
        let final = directory.appendingPathComponent(id.directoryName, isDirectory: true)
        try DirectoryRename.exclusive(from: temp, to: final)
        return WorkSaveResult(summary: WorkSummary(meta: meta, previewURL: final.appendingPathComponent(preview.fileName)),
                              outcome: .inserted)
    }

    private func discardUnpublished(_ temp: URL) {
        let name = temp.lastPathComponent
        let parent = temp.deletingLastPathComponent().resolvingSymlinksInPath().path
        let root = directory.resolvingSymlinksInPath().path
        guard name.hasPrefix(OrdinaryPhotoLibrary.transactionPrefix),
              parent == root || parent == root + "/" || parent + "/" == root else { return }
        try? FileManager.default.removeItem(at: temp)
    }
}
