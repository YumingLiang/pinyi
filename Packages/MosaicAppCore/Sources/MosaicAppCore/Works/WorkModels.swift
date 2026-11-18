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
///
/// 版本历史：
/// - v1：`fingerprint` = 整个布局 JSON（含叠加强度、seed）的 FNV-1a 64。
/// - v2（AndyL 的作品规则：换拼法后再存就新存一份，只改强度算同一张；需求 B10-2/3、B9-7）：`fingerprint` = 内容指纹
///   `WorkFingerprint`（格子分配 + cols/rows + targetCrop + seed，不含叠加强度 / 档位）；新增 `updatedAt`（只改叠加强度
///   更新原作品时写，只记录、不排序、不显示）和 `pendingPreviewFile`（更新叠加强度的提交日志，见 `FileWorksStore`）。
///   读到 v1（或 #17 早期内测包写的、不带 seed 的 v2 指纹）时，存储层按 layout.json 在内存里补算指纹，
///   **只在命中并更新时才写回 v2**（QA A3），打开列表不写盘。
public struct WorkMeta: Sendable, Hashable, Codable {
    public static let currentFormatVersion = 2

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
    /// 内容指纹（v2 起为 `WorkFingerprint`）：「同一张」只存一份（需求 B10 / B9-2）。
    public var fingerprint: String
    /// 最近一次「只改叠加强度、更新原作品」的时间；从没更新过 / 旧数据为 nil。只记录，不参与排序，界面不显示（B10-7）。
    public var updatedAt: Date?
    /// 更新叠加强度的提交日志：meta.json（新强度）写下时，新预览图还在作品目录里的这个临时文件名下，
    /// 之后才换到 `previewFile`。读到非 nil 时存储层先把它换过去（前滚），再清掉这一项。平时为 nil（不写进 JSON）。
    public var pendingPreviewFile: String?
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
    /// 兜底规则版本（架构师 11-17）：2 = 隐藏 / 拿不准的格子填目标平均色、只有确认删除才裁旧预览。
    /// nil / 1 = 旧版（补不上的格子一律裁旧预览，兜底图和预览可能带着隐藏照片的像素），打开 / 导出前整体迁移。
    /// 2 = 旧兜底图整体作废后的写法。产品 03:55 Q1 之后不再产生兜底图；v2 时删除格裁的旧预览兜底图靠
    /// `needsFallbackMigration`（还登记着兜底图就迁移）作废，版本号不再升（QA 门禁按 2 断言）。
    public var fallbackVersion: Int?
    public static let currentFallbackVersion = 2
    /// 旧版兜底需要迁移：还登记着兜底图（v1 / v2 裁的旧预览，可能带先隐藏后删除的像素），或 v1 存过兜底格。
    /// 列表 / 查看页在迁移（重画预览）完成前不显示旧预览，用占位图。
    public var needsFallbackMigration: Bool {
        fallbackFile != nil || ((fallbackVersion ?? 1) < 2 && fallbackCellCount > 0)
    }
    /// 目标图本机版本的有效长边（px，photo-picker-v0.1 §6.1；内部性能页显示）。旧作品 / 未记录为 nil。
    public var targetLocalLongSide: Int?
    /// 叠加降级系数 k（`OverlayDegrade`，另一条线计算；内部性能页显示）。旧作品 / 未记录为 nil。
    public var overlayDegradeFactor: Double?

    public init(formatVersion: Int = WorkMeta.currentFormatVersion, id: WorkID, createdAt: Date, columns: Int, rows: Int,
                tier: String?, photoCount: Int, missingCount: Int, overlayAlpha: Double, seed: UInt64?, fingerprint: String,
                origin: WorkOrigin, previewFile: String, previewPixelWidth: Int, previewPixelHeight: Int, targetFile: String?,
                updatedAt: Date? = nil,
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
        self.updatedAt = updatedAt
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
             origin, previewFile, previewPixelWidth, previewPixelHeight, targetFile, updatedAt, pendingPreviewFile,
             droppedPhotoCount, replacedCellCount, fallbackCellCount, fallbackFile, targetLocalLongSide, overlayDegradeFactor,
             fallbackVersion
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
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        origin = try c.decodeIfPresent(WorkOrigin.self, forKey: .origin) ?? .savedManually
        previewFile = try c.decodeIfPresent(String.self, forKey: .previewFile) ?? "preview.jpg"
        previewPixelWidth = try c.decodeIfPresent(Int.self, forKey: .previewPixelWidth) ?? 0
        previewPixelHeight = try c.decodeIfPresent(Int.self, forKey: .previewPixelHeight) ?? 0
        targetFile = try c.decodeIfPresent(String.self, forKey: .targetFile)
        droppedPhotoCount = try c.decodeIfPresent(Int.self, forKey: .droppedPhotoCount) ?? 0
        replacedCellCount = try c.decodeIfPresent(Int.self, forKey: .replacedCellCount) ?? 0
        fallbackCellCount = try c.decodeIfPresent(Int.self, forKey: .fallbackCellCount) ?? 0
        fallbackFile = try c.decodeIfPresent(String.self, forKey: .fallbackFile)
        fallbackVersion = try c.decodeIfPresent(Int.self, forKey: .fallbackVersion)
        targetLocalLongSide = try c.decodeIfPresent(Int.self, forKey: .targetLocalLongSide)
        overlayDegradeFactor = try c.decodeIfPresent(Double.self, forKey: .overlayDegradeFactor)
        pendingPreviewFile = try c.decodeIfPresent(String.self, forKey: .pendingPreviewFile)
    }
}

/// 「同一张作品」的指纹（AndyL 的规则：换拼法后再存就新存一份，只改强度算同一张；需求 B10-2/3、B9-7，
/// 开发协调人 11-16 按 QA PR #17 复核定口径）：**格子分配**（每格照片 ID + 裁剪）+ **cols/rows** + **targetCrop** + **seed**。
/// 不含叠加强度、导出档位（B10-10）、密度名（三档长边格数固定，改密度必然改 cols/rows，QA 复核第 3 节②）、targetSize：
/// - 只改叠加强度（「再调一调」→「完成」不换 seed）→ 指纹相同 → 更新原作品（不另存）；
/// - 「换一种拼法」/「开始拼图」重新生成必换 seed → 新的一张，**即使格子分配恰好相同**（只有 1 张素材时就是这样）；
/// - 改密度、裁剪、目标图、素材 → 网格 / 裁剪区 / 格子分配 / seed 不同 → 新的一张。
///
/// 指纹带前缀 `prefix`，用来认出 v1 和 #17 早期内测包写的不带 seed 的旧口径指纹（见 `isCurrent`）。
/// 实现：对规范字节流做 FNV-1a 64（不经 JSON，1 万格也只要约 1 ms；Linux / iOS 一致）。
/// 浮点按 1e-6 量化成整数，JSON 往返的末位差异不影响指纹。
public enum WorkFingerprint {
    public static func of(_ layout: MosaicLayout) -> String {
        var h = FNV1a64()
        h.add(Array("pinyi.work.v2s".utf8))
        h.add(Int64(bitPattern: layout.params.seed))
        h.add(Int64(layout.cols))
        h.add(Int64(layout.rows))
        h.add(layout.targetCrop)
        h.add(Int64(layout.cellAssignments.count))
        for cell in layout.cellAssignments {
            h.add(Array(cell.localIdentifier.utf8))
            h.add([0])
            h.add(cell.crop)
        }
        // 只在有形状时追加。普通拼图的字节与加形状字段之前相同。
        if let shape = layout.shape {
            h.add(Array("shape".utf8))
            h.add(Array(shape.background.rawValue.utf8))
            h.add(shape.mask.bitsV1Bytes)
        }
        return prefix + h.hex
    }

    /// 当前口径指纹的前缀。
    public static let prefix = "s2-"
    /// 是不是当前口径（含 seed）算出来的指纹。
    public static func isCurrent(_ fingerprint: String) -> Bool { fingerprint.hasPrefix(prefix) }

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
    /// 最近一次保存时间：`updatedAt`，没有就用 `createdAt`（B10-12：旧数据多份同指纹时按它取最大的那份）。
    public var lastSavedAt: Date { meta.updatedAt ?? meta.createdAt }
    /// 不是完整相册权限（运行时状态，由 `WorksState` 统一打上，不存盘）。04:05 临时做法：不逐个判断，所有作品都占位。
    public var accessRestricted = false
    /// 列表 / 查看页显示占位图而不是预览：旧版兜底还没迁移（预览可能带隐藏照片的像素），或不是完整相册权限（v1.7a）。
    public var showsPlaceholder: Bool { meta.needsFallbackMigration || accessRestricted }
    public init(meta: WorkMeta, previewURL: URL) {
        self.meta = meta
        self.previewURL = previewURL
    }

    /// 保存时命中哪一份（存储层查重和结果页按钮状态共用同一口径）：
    /// `preferred` 还在且指纹相同 → 就是它（结果页记住的作品 id，B10-13）；否则同指纹里 `lastSavedAt` 最大的那份
    /// （B10-9/12；相同时取列表里靠前的，即 createdAt 更新的）。没有同指纹的 → nil。
    public static func saveTarget(in list: [WorkSummary], fingerprint: String, preferred: WorkID? = nil) -> WorkSummary? {
        if let preferred, let hit = list.first(where: { $0.id == preferred && $0.meta.fingerprint == fingerprint }) {
            return hit
        }
        var best: WorkSummary?
        for s in list where s.meta.fingerprint == fingerprint {
            if let b = best, s.lastSavedAt <= b.lastSavedAt { continue }
            best = s
        }
        return best
    }
}

/// 打开的作品：summary + 显式布局 + 目标图副本位置。
public struct Work: Sendable {
    public var summary: WorkSummary
    public var layout: MosaicLayout
    public var targetURL: URL?
    public var meta: WorkMeta { summary.meta }
    public var id: WorkID { summary.id }
    /// meta 已提交、layout.json 没写成（写回途中被杀，架构师 11-17 D-b）：meta 的指纹和实际布局对不上。
    /// 只认本轮写过的作品（`fallbackVersion` 有值、指纹是当前口径）；这样的作品下次打开时按待处理重新走一遍写回。
    public var isLayoutOutOfSync: Bool {
        meta.fallbackVersion != nil && WorkFingerprint.isCurrent(meta.fingerprint) && meta.fingerprint != WorkFingerprint.of(layout)
    }
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
    /// 结果页记住的「当前结果对应的作品」（存过 / 更新过之后；经「再调一调」来回不丢）。还在且同指纹时优先命中它。
    public var preferredWorkID: WorkID?

    public init(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, tier: String? = nil, seed: UInt64? = nil,
                origin: WorkOrigin, preferredWorkID: WorkID? = nil) {
        self.layout = layout
        self.target = target
        self.overlayAlpha = overlayAlpha
        self.tier = tier
        self.seed = seed
        self.origin = origin
        self.preferredWorkID = preferredWorkID
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

/// 一次查询的结果：还在的 ID + 取不到的 ID 各自的原因（需求 4.8 第 5e 条，架构师 11-17 最终方案）。
public struct PhotoAvailability: Sendable, Hashable {
    /// 仍然存在、可访问（且不是隐藏）的。
    public var present: Set<String>
    /// 取不到的 → 原因（hidden / deleted / unknown）。
    public var missing: [String: MissingReason]
    public init(present: Set<String>, missing: [String: MissingReason]) {
        self.present = present
        self.missing = missing
    }
}

/// 原照片还在不在（App 里是 `PHAsset.fetchAssets(withLocalIdentifiers:)`，一次批量查）。
///
/// App 实现必须**不含隐藏照片**（includeHiddenAssets = false）：后来被隐藏的照片和已删除的一样「不在」（需求 v0.4 §4.8 5a）。
/// 取不到的原因另由 `PhotoFetch.classifyMissing`（唯一一处只读元数据的 includeHiddenAssets 例外）分出。
public protocol PhotoExistenceChecking: Sendable {
    /// 返回 `identifiers` 里仍然存在、可访问的那部分（补格时查候选可见性用）。
    func existingIdentifiers(among identifiers: [String]) async -> Set<String>
    /// 还在的 ID + 缺失原因（作品打开 / 导出前的缺图处理用）。**只读元数据，不请求任何图像。**
    /// 默认：`existingIdentifiers` 之外的一律 `.unknown`（按隐藏处理）。
    func availability(among identifiers: [String]) async -> PhotoAvailability
    /// 「取不到」能不能当成真的没了（完整相册权限时为 true）。受限访问 / 无权限时，没选进来的照片也取不到，
    /// 这时只计数提示，**不**改写作品（否则会把整张作品清空）。默认 true。
    func canConfirmMissing() async -> Bool
}

extension PhotoExistenceChecking {
    public func canConfirmMissing() async -> Bool { true }
    public func availability(among identifiers: [String]) async -> PhotoAvailability {
        let present = await existingIdentifiers(among: identifiers)
        var missing: [String: MissingReason] = [:]
        for id in identifiers where !id.isEmpty && !present.contains(id) { missing[id] = .unknown }
        return PhotoAvailability(present: present, missing: missing)
    }
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
            // 兜底 / 纯色由存储层写回时按缺失原因决定（`FileWorksStore.applyRematch` → `MissingCellFill.decide`）
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

/// 作品写入的前置条件错误（架构师 11-17 B）。
public enum WorksError: Error, Sendable, Equatable {
    /// `write(_ draft:)` 收到带纯色格（`fc`）的布局：新存作品的预览渲染还不读 fc，先拒绝（长期改法见 works-missing-fill）。
    case unsupportedFilledCells
}
