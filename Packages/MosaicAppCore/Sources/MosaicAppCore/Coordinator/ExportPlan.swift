import Foundation

/// 导出档位（AndyL 12:17 拍板：默认超清）。取代原 4000 / 6000。
public enum ExportTier: String, Sendable, Hashable, CaseIterable, Codable {
    /// 分享：长边约 4000。
    case share
    /// 高清：每格 160 px。
    case hd
    /// 超清（默认）：每格 256 px。
    case uhd

    public static let `default` = ExportTier.uhd
    public static let shareLongEdge = 4000
    public static let hdCellPixels = 160
    public static let uhdCellPixels = 256

    public var titleKey: L10nKey {
        switch self {
        case .share: return .exportSizeShare
        case .hd: return .exportSizeHD
        case .uhd: return .exportSizeUHD
        }
    }

    public var descriptionKey: L10nKey {
        switch self {
        case .share: return .exportSizeShareDesc
        case .hd: return .exportSizeHDDesc
        case .uhd: return .exportSizeUHDDesc
        }
    }

    /// 本档请求的每格像素（未降档）。分享 = ⌊4000 ÷ 长边格数⌋。
    public func requestedCellPixels(columns: Int, rows: Int) -> Int {
        switch self {
        case .share: return max(1, Self.shareLongEdge / max(1, max(columns, rows)))
        case .hd: return Self.hdCellPixels
        case .uhd: return Self.uhdCellPixels
        }
    }
}

/// 导出尺寸方案（纯函数，Linux 单测）。格子是正方形：宽 = 列 × 每格，高 = 行 × 每格。
///
/// 紧急版（12:30）：整张位图一次画完，所以总像素上限是**动态**的：
/// `cap = min(300 MP, 可用内存 ÷ 2 ÷ 4)`（可用内存 = `os_proc_available_memory()`，由平台层传入；Linux 测试注入）；
/// 每格 = min(档位每格, ⌊√(cap ÷ (列 × 行))⌋)，最少 1 px，单边不超 JPEG 65535。
public struct ExportPlan: Sendable, Hashable {
    /// 静态上限 300 MP（design/hd-export-v0.1 12:15 修订）。
    public static let staticMaxTotalPixels: Int64 = 300_000_000
    public static let jpegMaxDimension = 65_535
    /// 位图要 ≤ 可用内存的一半。
    public static let memoryHeadroom: Int64 = 2
    public static let bytesPerPixel: Int64 = 4

    public let tier: ExportTier
    public let columns: Int
    public let rows: Int
    public let requestedCellPixels: Int
    public let cellPixels: Int
    /// 本次实际总像素上限。
    public let capPixels: Int64
    /// 计算时传入的可用内存（nil = 未知，只用静态上限）。
    public let availableMemoryBytes: Int64?

    public static func capPixels(availableMemoryBytes: Int64?) -> Int64 {
        guard let a = availableMemoryBytes else { return staticMaxTotalPixels }
        return max(1, min(staticMaxTotalPixels, max(0, a) / memoryHeadroom / bytesPerPixel))
    }

    public init(tier: ExportTier, columns: Int, rows: Int, availableMemoryBytes: Int64? = nil) {
        let c = max(1, columns), r = max(1, rows)
        self.tier = tier
        self.columns = c
        self.rows = r
        self.availableMemoryBytes = availableMemoryBytes
        let cap = Self.capPixels(availableMemoryBytes: availableMemoryBytes)
        capPixels = cap
        let requested = tier.requestedCellPixels(columns: c, rows: r)
        requestedCellPixels = requested
        cellPixels = max(1, min(requested, Self.maxCellPixels(columns: c, rows: r, maxTotalPixels: cap)))
    }

    /// 总像素 ≤ 上限、单边 ≤ JPEG 上限时的最大每格像素：⌊√(上限 ÷ 格数)⌋（整数修正浮点误差）。
    public static func maxCellPixels(columns: Int, rows: Int, maxTotalPixels: Int64) -> Int {
        let cells = Int64(max(1, columns)) * Int64(max(1, rows))
        let cap = max(1, maxTotalPixels)
        var t = Int64((Double(cap) / Double(cells)).squareRoot())
        while t > 1, t * t * cells > cap { t -= 1 }
        while (t + 1) * (t + 1) * cells <= cap { t += 1 }
        let byJPEG = Int64(jpegMaxDimension / max(1, max(columns, rows)))
        return Int(max(1, min(t, byJPEG)))
    }

    public var width: Int { columns * cellPixels }
    public var height: Int { rows * cellPixels }
    public var totalPixels: Int64 { Int64(width) * Int64(height) }
    public var bitmapBytes: Int64 { totalPixels * Self.bytesPerPixel }
    public var isCapped: Bool { cellPixels < requestedCellPixels }

    /// 日志 / 内测性能页用（界面不显示像素）。
    public var logDescription: String {
        let mem = availableMemoryBytes.map { "\($0 / 1_048_576)MB" } ?? "未知"
        return "\(tier.rawValue) \(columns)×\(rows) 每格 \(cellPixels)px（请求 \(requestedCellPixels)）\(width)×\(height) \(totalPixels / 1_000_000)MP 上限 \(capPixels / 1_000_000)MP 可用内存 \(mem)"
    }
}
