import Foundation
import MosaicCore

/// 导出几何（T8，技术方案 §4.2）：导出尺寸、每格像素、条带切分、磁盘 / 内存预算。
///
/// **不假设尺寸上限**（「高清导出」可能到长边 2–3 万像素）：条带高度按**字节预算**算（默认每条画布 ≤ 16 MB），
/// 宽图自动变成更矮的条带；最少 1 行格子。像素与字节一律用 Int64 计算，不会溢出。
public struct ExportGeometry: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let cellPixels: Int
    public let columns: Int
    public let strips: [ExportStrip]

    /// 单条带画布字节预算默认值。
    public static let defaultStripByteBudget = 16 * 1_048_576

    public init(layout: GridLayout, longEdge: Int, stripByteBudget: Int = ExportGeometry.defaultStripByteBudget) {
        let s = layout.exportSize(longEdge: longEdge)
        width = s.width
        height = s.height
        cellPixels = s.cellPixels
        columns = layout.columns
        let bytesPerCellRow = Int64(s.width) * 4 * Int64(max(1, s.cellPixels))
        let rowsPerStrip = Int(max(1, Int64(stripByteBudget) / max(1, bytesPerCellRow)))
        strips = layout.exportStrips(longEdge: longEdge, policy: .cellRows(rowsPerStrip))
    }

    /// 未压缩 RGBA8 暂存文件大小（条带逐条追加写入，编码时再流式读）。
    public var rawBytes: Int64 { Int64(width) * Int64(height) * 4 }

    /// JPEG（质量 0.9）编码结果的保守上界：马赛克图细节多，按 0.6 字节/像素估。
    public static let encodedBytesPerPixel = 0.6
    public var estimatedEncodedBytes: Int64 { Int64((Double(width) * Double(height) * Self.encodedBytesPerPixel).rounded(.up)) }

    /// 预检余量（系统相册写入时的元数据、缩略图等）。
    public static let safetyMarginBytes: Int64 = 50 * 1_048_576

    /// 存储预检所需字节：暂存 raw + 编码文件 + 写入相册时系统复制一份 + 余量。
    public var estimatedDiskBytes: Int64 { rawBytes + 2 * estimatedEncodedBytes + Self.safetyMarginBytes }

    /// 单条带在内存里的峰值字节（RGBA8 画布）。≤ 预算，除非 1 行格子本身就超过预算。
    public var peakStripBytes: Int64 { Int64(width) * Int64(strips.map(\.pixelHeight).max() ?? 0) * 4 }

    /// 条带覆盖的格子下标（行优先，连续）。
    public func cells(in strip: ExportStrip) -> Range<Int> {
        (strip.rows.lowerBound * columns)..<(strip.rows.upperBound * columns)
    }
}

/// 存储预检（文案 `save.disk_full.*`：预检不足，或写入中磁盘写满）。
public enum StoragePrecheck {
    /// 读不到可用空间（nil）时不拦截。
    public static func check(required: Int64, available: Int64?) throws {
        if let available, available < required { throw ExportError.insufficientStorage }
    }

    /// 写入过程中的磁盘满错误 → `ExportError.insufficientStorage`。
    public static func isOutOfSpace(_ error: any Error) -> Bool {
        if let e = error as? ExportError { return e == .insufficientStorage }
        if let e = error as? CocoaError, e.code == .fileWriteOutOfSpace { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) { return true }
        return false
    }
}

/// 平台层：渲染一条条带，返回 RGBA8、行优先、自上而下的字节（`width × strip.pixelHeight × 4`）。
public protocol StripRendering: Sendable {
    func render(_ strip: ExportStrip, geometry: ExportGeometry, request: ExportRequest) async throws -> Data
}

/// 平台层：把 raw RGBA8 暂存文件编码成最终图片文件（ImageIO 流式读，不整张进内存）。
public protocol RasterEncoding: Sendable {
    /// 文件扩展名（"jpg"）。
    var fileExtension: String { get }
    func encode(rawFile: URL, width: Int, height: Int, to output: URL) throws
}

/// 条带导出器（T8）：逻辑全在这里（Linux 可测），平台层只提供 `StripRendering` 和 `RasterEncoding`。
///
/// - 每条带之前 `Task.checkCancellation()`（**B-34**：取消后最多再完成当前这一条，不再开始下一条）；
/// - 取消 / 出错时删掉暂存 raw 与半截输出文件，不留垃圾；
/// - 磁盘满（预检或写入中）统一抛 `ExportError.insufficientStorage`；
/// - 所有文件都在 `directory`（App 里是 `tmp/export/`）下，启动时整个目录清空（**B-27**）。
public struct StripExporter: MosaicExporting {
    public let directory: URL
    public let renderer: any StripRendering
    public let encoder: any RasterEncoding
    public let storage: @Sendable () -> Int64?
    public let stripByteBudget: Int
    /// 进度里条带渲染所占份额（其余是编码）。
    public static let renderShare = 0.9

    public init(directory: URL, renderer: any StripRendering, encoder: any RasterEncoding,
                stripByteBudget: Int = ExportGeometry.defaultStripByteBudget, storage: @escaping @Sendable () -> Int64?) {
        self.directory = directory
        self.renderer = renderer
        self.encoder = encoder
        self.stripByteBudget = stripByteBudget
        self.storage = storage
    }

    public func geometry(for request: ExportRequest) -> ExportGeometry {
        ExportGeometry(layout: request.product.generation.layout, longEdge: request.longEdge, stripByteBudget: stripByteBudget)
    }

    public func estimatedBytes(for request: ExportRequest) -> Int64 { geometry(for: request).estimatedDiskBytes }

    public func availableBytes() -> Int64? { storage() }

    public func export(_ request: ExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let geo = geometry(for: request)
        try StoragePrecheck.check(required: geo.estimatedDiskBytes, available: storage())
        let fm = FileManager.default
        let token = UUID().uuidString
        let raw = directory.appendingPathComponent("\(token).rgba")
        let output = directory.appendingPathComponent("\(token).\(encoder.fileExtension)")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard fm.createFile(atPath: raw.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: raw)
            do {
                let count = geo.strips.count
                for strip in geo.strips {
                    try Task.checkCancellation()   // B-34：条带边界
                    let bytes = try await renderer.render(strip, geometry: geo, request: request)
                    guard Int64(bytes.count) == Int64(geo.width) * Int64(strip.pixelHeight) * 4 else { throw ExportError.encodingFailed }
                    try handle.write(contentsOf: bytes)
                    progress(Self.renderShare * Double(strip.index + 1) / Double(max(1, count)))
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try Task.checkCancellation()
            try encoder.encode(rawFile: raw, width: geo.width, height: geo.height, to: output)
            try? fm.removeItem(at: raw)
            progress(1)
            return output
        } catch {
            try? fm.removeItem(at: raw)
            try? fm.removeItem(at: output)
            if error is CancellationError { throw error }
            if StoragePrecheck.isOutOfSpace(error) { throw ExportError.insufficientStorage }
            if let e = error as? ExportError { throw e }
            throw ExportError.encodingFailed
        }
    }

    public func discard(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    public func removeStaleExports() { try? FileManager.default.removeItem(at: directory) }
}
