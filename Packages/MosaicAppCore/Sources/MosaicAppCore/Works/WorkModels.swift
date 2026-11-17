import Foundation
import MosaicCore

// 「我的作品」数据模型（design/works-storage-v0.1.md，架构师；product/hd-export-req-v0.2.md B 节、F 节）。
// 每格用哪张照片显式存在 `MosaicLayout` 里（localIdentifier + 裁剪），重新打开 / 再导出都不重跑匹配、不靠种子重算。

/// 作品 id（目录名 = `uuidString`）。
public struct WorkID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
    public init?(directoryName: String) {
        guard let u = UUID(uuidString: directoryName) else { return nil }
        uuid = u
    }
    public var directoryName: String { uuid.uuidString }
    public var description: String { uuid.uuidString }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let u = UUID(uuidString: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad work id \(s)"))
        }
        uuid = u
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(uuid.uuidString)
    }
}

/// 作品是怎么进库的（导出成功自动存 / 结果页「存到我的作品」）。
public enum WorkOrigin: String, Sendable, Codable, Hashable {
    case autoSavedOnExport
    case savedManually
}

/// meta.json：列表只扫这个文件（不读布局、不解码图片），所以 100 个作品也很快。
///
/// 版本规则（升级兼容，QA「升级后重开旧作品」）：
/// - `formatVersion` ≤ `currentFormatVersion`：照常读；后加的字段一律 `decodeIfPresent` + 默认值，旧作品不丢；
/// - `formatVersion` > `currentFormatVersion`（新版写的、又装回旧版）：列表跳过、**不删除**，装回新版还能看到。
public struct WorkMeta: Sendable, Hashable, Codable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: WorkID
    public var createdAt: Date
    public var columns: Int
    public var rows: Int
    /// 保存时的导出档位（字符串，档位枚举归导出层；手动保存时为 nil）。
    public var tier: String?
    /// 不同照片数。
    public var photoCount: Int
    /// 最近一次检查到、但**还没处理**的缺失原照片数（受限访问 / 索引未就绪 / 写回失败时；保存时为 0；处理过即归 0）。
    /// 只在内部性能页显示，不再用于提示（提示只在本次真的发生替换 / 兜底时出一次，见 `WorksController`）。
    public var missingCount: Int
    public var overlayAlpha: Double
    /// 只用于追溯（不用于重算）。
    public var seed: UInt64?
    /// 布局指纹（布局 JSON 的 FNV-1a 64）：同一张图重复保存只存一份（需求 B2 / B9-2）。
    public var fingerprint: String
    public var origin: WorkOrigin
    public var previewFile: String
    public var previewPixelWidth: Int
    public var previewPixelHeight: Int
    public var targetFile: String?
    /// 取不到（删除或后来被隐藏，需求 v0.4 §4.8 5a）、且至少有一格**找不到替代只能留白**的原照片数。累计，不会减少：
    /// 照片恢复 / 取消隐藏后格子不改回去（5b）。旧作品缺省 0。
    public var droppedPhotoCount: Int
    /// 换成本机相近照片的格子数（4b，累计；`works.replaced`）。旧作品缺省 0。
    public var replacedCellCount: Int
    /// 找不到合格相近照片的格子数（按格，累计；`works.missing`）：用旧预览裁切兜底的，加上没有旧预览只能留白的。
    /// 兜底格后来升级成照片也不回退（与 `droppedPhotoCount` 一样只增）。旧作品缺省 0。
    public var fallbackCellCount: Int
    /// 预览兜底图（作品目录内，PNG，无损；按格拼成一张、每格与预览每格同像素，只有兜底格位置有像素，其余为 0）。布局里 `fallback == true` 的格子
    /// 从这里按格裁出、放大填充。没有兜底格时为 nil。旧作品缺省 nil。
    public var fallbackFile: String?
    /// 目标图本机版本的有效长边（px，photo-picker-v0.1 §6.1；内部性能页显示）。旧作品 / 未记录为 nil。
    public var targetLocalLongSide: Int?
    /// 叠加降级系数 k（`OverlayDegrade`，另一条线计算；内部性能页显示）。旧作品 / 未记录为 nil。
    public var overlayDegradeFactor: Double?

    public init(formatVersion: Int = WorkMeta.currentFormatVersion, id: WorkID, createdAt: Date, columns: Int, rows: Int,
                tier: String?, photoCount: Int, missingCount: Int, overlayAlpha: Double, seed: UInt64?, fingerprint: String,
                origin: WorkOrigin, previewFile: String, previewPixelWidth: Int, previewPixelHeight: Int, targetFile: String?,
                droppedPhotoCount: Int = 0, replacedCellCount: Int = 0, fallbackCellCount: Int = 0, fallbackFile: String? = nil,
                targetLocalLongSide: Int? = nil, overlayDegradeFactor: Double? = nil) {
        self.formatVersion = formatVersion
        self.id = id
        self.createdAt = createdAt
        self.columns = columns
        self.rows = rows
        self.tier = tier
        self.photoCount = photoCount
        self.missingCount = missingCount
        self.overlayAlpha = overlayAlpha
        self.seed = seed
        self.fingerprint = fingerprint
        self.origin = origin
        self.previewFile = previewFile
        self.previewPixelWidth = previewPixelWidth
        self.previewPixelHeight = previewPixelHeight
        self.targetFile = targetFile
        self.droppedPhotoCount = droppedPhotoCount
        self.replacedCellCount = replacedCellCount
        self.fallbackCellCount = fallbackCellCount
        self.fallbackFile = fallbackFile
        self.targetLocalLongSide = targetLocalLongSide
        self.overlayDegradeFactor = overlayDegradeFactor
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, id, createdAt, columns, rows, tier, photoCount, missingCount, overlayAlpha, seed, fingerprint,
             origin, previewFile, previewPixelWidth, previewPixelHeight, targetFile, droppedPhotoCount, replacedCellCount, fallbackCellCount, fallbackFile,
             targetLocalLongSide,
             overlayDegradeFactor
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        id = try c.decode(WorkID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        columns = try c.decode(Int.self, forKey: .columns)
        rows = try c.decode(Int.self, forKey: .rows)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        photoCount = try c.decodeIfPresent(Int.self, forKey: .photoCount) ?? 0
        missingCount = try c.decodeIfPresent(Int.self, forKey: .missingCount) ?? 0
        overlayAlpha = try c.decodeIfPresent(Double.self, forKey: .overlayAlpha) ?? 0
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        origin = try c.decodeIfPresent(WorkOrigin.self, forKey: .origin) ?? .savedManually
        previewFile = try c.decodeIfPresent(String.self, forKey: .previewFile) ?? "preview.jpg"
        previewPixelWidth = try c.decodeIfPresent(Int.self, forKey: .previewPixelWidth) ?? 0
        previewPixelHeight = try c.decodeIfPresent(Int.self, forKey: .previewPixelHeight) ?? 0
        targetFile = try c.decodeIfPresent(String.self, forKey: .targetFile)
        droppedPhotoCount = try c.decodeIfPresent(Int.self, forKey: .droppedPhotoCount) ?? 0
        replacedCellCount = try c.decodeIfPresent(Int.self, forKey: .replacedCellCount) ?? 0
        fallbackCellCount = try c.decodeIfPresent(Int.self, forKey: .fallbackCellCount) ?? 0
        fallbackFile = try c.decodeIfPresent(String.self, forKey: .fallbackFile)
        targetLocalLongSide = try c.decodeIfPresent(Int.self, forKey: .targetLocalLongSide)
        overlayDegradeFactor = try c.decodeIfPresent(Double.self, forKey: .overlayDegradeFactor)
    }
}

/// 列表里的一项（meta + 预览图文件位置）。
public struct WorkSummary: Sendable, Hashable, Identifiable {
    public var meta: WorkMeta
    public var previewURL: URL
    public var id: WorkID { meta.id }
    public var createdAt: Date { meta.createdAt }
    public init(meta: WorkMeta, previewURL: URL) {
        self.meta = meta
        self.previewURL = previewURL
    }
}

/// 打开的作品：summary + 显式布局 + 目标图副本位置。
public struct Work: Sendable {
    public var summary: WorkSummary
    public var layout: MosaicLayout
    public var targetURL: URL?
    public var meta: WorkMeta { summary.meta }
    public var id: WorkID { summary.id }
    public init(summary: WorkSummary, layout: MosaicLayout, targetURL: URL?) {
        self.summary = summary
        self.layout = layout
        self.targetURL = targetURL
    }
}

/// 要保存的东西。
public struct WorkDraft: Sendable {
    public var layout: MosaicLayout
    /// 目标图（App 里是解码降采样后的那份；副本长边 ≤ `WorkImageLimits.targetLongEdge`）。
    public var target: PixelBuffer?
    public var overlayAlpha: Double
    public var tier: String?
    public var seed: UInt64?
    public var origin: WorkOrigin

    public init(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, tier: String? = nil, seed: UInt64? = nil,
                origin: WorkOrigin) {
        self.layout = layout
        self.target = target
        self.overlayAlpha = overlayAlpha
        self.tier = tier
        self.seed = seed
        self.origin = origin
    }
}

/// 图片尺寸约定（works-storage-v0.1）。
public enum WorkImageLimits {
    /// 预览图长边（屏幕分辨率，列表缩略图和查看放大都用它）。
    public static let previewLongEdge = 2732
    /// 目标图副本长边上限。
    public static let targetLongEdge = 4096
}

/// 平台层写出的一张图。
public struct WorkImageFile: Sendable, Hashable {
    public var fileName: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public init(fileName: String, pixelWidth: Int, pixelHeight: Int) {
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// 平台层图片编解码（App 里是 Core Graphics + ImageIO；Linux 测试用假实现）。
///
/// 实现约定：只往给定的 `directory`（作品的临时目录）里写，文件名自定（如 `preview.jpg`）；
/// 失败就抛错——存储层会把整个临时目录删掉，不留半个作品。
public protocol WorkImageEncoding: Sendable {
    /// 按布局渲染预览图（长边 ≤ `maxLongEdge`）。`fallbacks`：格子下标 → 预览兜底图（`WorkFallbackImages`），
    /// 这些格子不取照片，把兜底图放大填满该格（双线性 / `.high`，不用最近邻），再照常叠加目标图。
    func writePreview(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, maxLongEdge: Int,
                      fallbacks: [Int: PixelBuffer], into directory: URL) async throws -> WorkImageFile
    /// 写目标图副本（长边 ≤ `maxLongEdge`，原图更小就不放大）。
    func writeTarget(_ target: PixelBuffer, maxLongEdge: Int, into directory: URL) async throws -> WorkImageFile
    /// 读回目标图副本（从作品再导出时做叠加用）。
    func readTarget(at url: URL) async throws -> PixelBuffer
    /// 读回作品目录里的预览图 / 兜底图（原尺寸，不降采样；裁兜底格用）。
    func readImage(at url: URL) async throws -> PixelBuffer
    /// 写预览兜底图（无损 PNG；只往 `directory` 里写）。
    func writeFallback(_ image: PixelBuffer, into directory: URL) async throws -> WorkImageFile
}

/// 原照片还在不在（App 里是 `PHAsset.fetchAssets(withLocalIdentifiers:)`，一次批量查）。
///
/// App 实现必须**不含隐藏照片**（includeHiddenAssets = false）：后来被隐藏的照片和已删除的一样返回「不在」（需求 v0.4 §4.8 5a）。
public protocol PhotoExistenceChecking: Sendable {
    /// 返回 `identifiers` 里仍然存在、可访问的那部分。
    func existingIdentifiers(among identifiers: [String]) async -> Set<String>
    /// 「取不到」能不能当成真的没了（完整相册权限时为 true）。受限访问 / 无权限时，没选进来的照片也取不到，
    /// 这时只计数提示，**不**改写作品（否则会把整张作品清空）。默认 true。
    func canConfirmMissing() async -> Bool
}

extension PhotoExistenceChecking {
    public func canConfirmMissing() async -> Bool { true }
}

extension MosaicLayout {
    /// 把用到 `assetIDs` 里照片的格子清成缺图格（空串，渲染 / 导出按「没有分到照片」画）。
    /// 返回新布局和实际去掉的不同照片数（不在布局里的 ID 不算）。
    public func clearingAssets(_ assetIDs: Set<String>) -> (layout: MosaicLayout, droppedPhotos: Int) {
        guard !assetIDs.isEmpty else { return (self, 0) }
        var out = self
        var dropped = Set<String>()
        for i in out.cellAssignments.indices where !out.cellAssignments[i].localIdentifier.isEmpty
            && assetIDs.contains(out.cellAssignments[i].localIdentifier) {
            dropped.insert(out.cellAssignments[i].localIdentifier)
            // 兜底标记由存储层写回时按「有没有旧预览」决定（`FileWorksStore.applyRematch`）
            out.cellAssignments[i] = CellAssignment(localIdentifier: "", crop: out.cellAssignments[i].crop)
        }
        return (out, dropped.count)
    }
}

public enum WorksStoreError: Error, Sendable, Equatable {
    case notFound
    /// 新版 App 写的作品（formatVersion 更高），旧版不读。
    case unsupportedFormat(Int)
    case corrupted
}
