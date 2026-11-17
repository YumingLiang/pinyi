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

/// 作品是怎么进库的（结果页「存到我的作品」）。
/// `autoSavedOnExport` 只为读旧作品保留：AndyL 11-16 22:20 定「导出不自动存」（需求 B10-1），新代码不再写这个值。
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
    /// 最近一次检查时缺失的原照片数（保存时为 0；打开 / 导出前会重新检查，见 `WorksController`）。
    public var missingCount: Int
    public var overlayAlpha: Double
    /// 只用于追溯（不用于重算）。
    public var seed: UInt64?
    /// 作品指纹（`WorkFingerprint`）：「同一张」只存一份（需求 B10 / B9-2）。
    /// `fingerprintVersion` < `WorkFingerprint.currentVersion` 的旧作品（v1 = 整个布局 JSON 的 FNV，含叠加强度和 seed），
    /// 由存储层读列表时按新口径补算并原子写回 meta.json（见 `FileWorksStore`）。
    public var fingerprint: String
    /// 指纹口径版本；旧 meta 没有这个字段 → 1。
    public var fingerprintVersion: Int
    public var origin: WorkOrigin
    public var previewFile: String
    public var previewPixelWidth: Int
    public var previewPixelHeight: Int
    public var targetFile: String?

    public init(formatVersion: Int = WorkMeta.currentFormatVersion, id: WorkID, createdAt: Date, columns: Int, rows: Int,
                tier: String?, photoCount: Int, missingCount: Int, overlayAlpha: Double, seed: UInt64?, fingerprint: String,
                origin: WorkOrigin, previewFile: String, previewPixelWidth: Int, previewPixelHeight: Int, targetFile: String?,
                fingerprintVersion: Int = WorkFingerprint.currentVersion) {
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
        self.fingerprintVersion = fingerprintVersion
        self.origin = origin
        self.previewFile = previewFile
        self.previewPixelWidth = previewPixelWidth
        self.previewPixelHeight = previewPixelHeight
        self.targetFile = targetFile
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, id, createdAt, columns, rows, tier, photoCount, missingCount, overlayAlpha, seed, fingerprint,
             origin, previewFile, previewPixelWidth, previewPixelHeight, targetFile, fingerprintVersion
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
        fingerprintVersion = try c.decodeIfPresent(Int.self, forKey: .fingerprintVersion) ?? 1
        origin = try c.decodeIfPresent(WorkOrigin.self, forKey: .origin) ?? .savedManually
        previewFile = try c.decodeIfPresent(String.self, forKey: .previewFile) ?? "preview.jpg"
        previewPixelWidth = try c.decodeIfPresent(Int.self, forKey: .previewPixelWidth) ?? 0
        previewPixelHeight = try c.decodeIfPresent(Int.self, forKey: .previewPixelHeight) ?? 0
        targetFile = try c.decodeIfPresent(String.self, forKey: .targetFile)
    }
}

/// 「同一张作品」的指纹（AndyL 11-16 22:20 定，需求 B10-2/3）：只看**格子分配**（每格照片 ID + 裁剪）、
/// **cols/rows** 和 **targetCrop**。不含叠加强度、seed、密度名、targetSize：
/// - 只改叠加强度 → 指纹相同 → 更新原作品（不另存）；
/// - 不同 seed 但格子分配恰好相同 → 同一张；
/// - 「换一种拼法」/ 重新生成 / 改密度、裁剪、目标图、素材 → 格子分配（或网格、裁剪区）不同 → 新的一张。
///
/// 实现：对规范字节流做 FNV-1a 64（不经 JSON，1 万格也只要约 1 ms；Linux / iOS 一致）。
/// 浮点按 1e-6 量化成整数，JSON 往返的末位差异不影响指纹。
public enum WorkFingerprint {
    /// v1 = 整个布局 JSON（含 params）的 FNV；v2 = 本口径。
    public static let currentVersion = 2

    public static func of(_ layout: MosaicLayout) -> String {
        var h = FNV1a64()
        h.add(Array("pinyi.work.v2".utf8))
        h.add(Int64(layout.cols))
        h.add(Int64(layout.rows))
        h.add(layout.targetCrop)
        h.add(Int64(layout.cellAssignments.count))
        for cell in layout.cellAssignments {
            h.add(Array(cell.localIdentifier.utf8))
            h.add([0])
            h.add(cell.crop)
        }
        return h.hex
    }

    /// 叠加强度是否算「没改」（滑杆值经 JSON 往返，按 1e-6 比较）。
    public static func sameOverlay(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
}

/// FNV-1a 64 累加器。
struct FNV1a64 {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ bytes: [UInt8]) {
        for b in bytes {
            value ^= UInt64(b)
            value = value &* 0x0000_0100_0000_01b3
        }
    }

    mutating func add(_ v: Int64) {
        var x = UInt64(bitPattern: v)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(8)
        for _ in 0..<8 {
            bytes.append(UInt8(truncatingIfNeeded: x))
            x >>= 8
        }
        add(bytes)
    }

    mutating func add(_ r: CropRect) {
        add(Self.quantize(r.x))
        add(Self.quantize(r.y))
        add(Self.quantize(r.width))
        add(Self.quantize(r.height))
    }

    static func quantize(_ v: Double) -> Int64 {
        guard v.isFinite else { return Int64.min }
        let scaled: Double = (v * 1_000_000).rounded()
        let limit: Double = 9.0e18
        return Int64(max(-limit, min(limit, scaled)))
    }

    var hex: String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }
}

/// 保存结果。
public struct WorkSaveResult: Sendable {
    public enum Outcome: Sendable, Hashable {
        /// 新存了一份。
        case inserted
        /// 已有同一张（指纹相同），只更新了叠加强度和预览图；日期、列表位置、布局不变。
        case updatedOverlay
        /// 已有同一张且叠加强度也相同：什么都没写。
        case unchanged
    }
    public var summary: WorkSummary
    public var outcome: Outcome
    public var inserted: Bool { outcome == .inserted }
    public init(summary: WorkSummary, outcome: Outcome) {
        self.summary = summary
        self.outcome = outcome
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
    /// 按布局渲染预览图（长边 ≤ `maxLongEdge`）。
    func writePreview(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, maxLongEdge: Int,
                      into directory: URL) async throws -> WorkImageFile
    /// 写目标图副本（长边 ≤ `maxLongEdge`，原图更小就不放大）。
    func writeTarget(_ target: PixelBuffer, maxLongEdge: Int, into directory: URL) async throws -> WorkImageFile
    /// 读回目标图副本（从作品再导出时做叠加用）。
    func readTarget(at url: URL) async throws -> PixelBuffer
}

/// 原照片还在不在（App 里是 `PHAsset.fetchAssets(withLocalIdentifiers:)`，一次批量查）。
public protocol PhotoExistenceChecking: Sendable {
    /// 返回 `identifiers` 里仍然存在、可访问的那部分。
    func existingIdentifiers(among identifiers: [String]) async -> Set<String>
}

/// 11-18 预留（需求 F2 / F5「4b」）：把缺失原照片的格子换成本机相近照片，返回新布局。
/// **本轮不实现**；`WorksController` 只做缺失检测 + 计数。缺失格子不再用预览图放大补（F 节作废）。
public protocol MissingCellRematching: Sendable {
    func rematch(_ layout: MosaicLayout, missing: Set<String>) async throws -> (layout: MosaicLayout, replacedCells: Int)
}

public enum WorksStoreError: Error, Sendable, Equatable {
    case notFound
    /// 新版 App 写的作品（formatVersion 更高），旧版不读。
    case unsupportedFormat(Int)
    case corrupted
}
