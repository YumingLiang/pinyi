import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import MosaicCore
import MosaicAppCore

/// 导出器的 Apple 实现（紧急版 12:28：一张 CGBitmapContext 画整张）。
///
/// - 尺寸：`ExportPlan`（MosaicAppCore 纯函数）按档位 + `os_proc_available_memory()` 算每格像素：
///   上限 = min(300 MP, 可用内存 ÷ 2 ÷ 4)，位图分配前算，放不下就自动变小，不硬分配。
/// - 取图：按行优先顺序，最多 4 张在飞；取到一张立刻画进位图并释放（autoreleasepool），不先取全再画。
///   峰值 ≈ 位图 + 4 张缩略图。PhotoKit 请求 targetSize = 每格像素、highQualityFormat、`isNetworkAccessAllowed = false`。
/// - 编码：CGImageDestination 写 JPEG（质量 0.9）到 `tmp/export/`；保存 / 分享结束后删除，启动时清空目录（B-27）。
/// - 「我的作品」兜底格（`request.cellFallbacks`，旧预览裁出的小图）：不取照片，`.high` 插值放大填满该格（不用最近邻），
///   计入「糊格子」。
/// - 实际每格像素、尺寸、上限、可用内存、用时、文件大小，以及退回 128px 缩略图（糊格子）和完全空白（白格子）的数量，写 os_log（subsystem 同 Bundle ID，category "export"）和内测性能页。
/// - 不做（紧急版范围外）：取消、后台续跑、降档提示、存储预检。导出成功经协调器 `onExportSucceeded` 通知「我的作品」（只刷新按钮状态，导出不自动存，需求 B10-1）。
/// ⚠️ 盲写（Linux 上无法编译 CG / ImageIO / PhotoKit）。
struct LiveMosaicExporter: MosaicExporting {
    let thumbnails: any ThumbnailProviding
    let perf: PerfRecorder?

    static let maxInFlight = 4
    static let jpegQuality = 0.9
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "pinyi", category: "export")

    init(thumbnails: any ThumbnailProviding, perf: PerfRecorder? = nil) {
        self.thumbnails = thumbnails
        self.perf = perf
    }

    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
    }

    /// 紧急版不做存储预检（0 = 不拦截）。
    func estimatedBytes(for request: ExportRequest) -> Int64 { 0 }

    func availableBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// `os_proc_available_memory()`；模拟器 / 读不到时返回 0 → 当作未知（只用 300 MP 静态上限）。
    static func availableMemory() -> Int64? {
        let n = os_proc_available_memory()
        return n > 0 ? Int64(n) : nil
    }

    func export(_ request: ExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let t0 = Date()
        let mem = Self.availableMemory()
        let plan = request.plan(availableMemoryBytes: mem)
        Self.log.info("export start \(plan.logDescription, privacy: .public)")
        let w = plan.width, h = plan.height, cp = plan.cellPixels, columns = plan.columns
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            Self.log.error("export bitmap alloc failed \(plan.logDescription, privacy: .public)")
            throw ExportError.encodingFailed
        }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high

        let fallbacks = request.cellFallbacks
        let ids = request.layout.cellAssignments.map { $0.localIdentifier.isEmpty ? nil : $0.localIdentifier }
        let thumbs = thumbnails
        let hq: ThumbnailRequest = {
            var r = ThumbnailRequest(targetPixelSize: cp)
            r.fastFormat = false
            r.fastResize = false
            r.centerCropToSquare = true
            return r
        }()

        // 行优先、最多 4 张在飞；每取到一张立刻画进位图（CG 原点在左下）。
        var next = 0
        var done = 0
        var fills = ExportFillStats()
        let total = max(1, ids.count)
        await withTaskGroup(of: (Int, PixelBuffer?, ExportFillStats.Fill).self) { group in
            func enqueue() {
                while next < ids.count {
                    let i = next
                    next += 1
                    if let tile = fallbacks[i] {
                        let drawn: Bool = autoreleasepool {
                            guard let img = ImagePixels.cgImage(tile) else { return false }
                            let col = i % columns, row = i / columns
                            ctx.draw(img, in: CGRect(x: col * cp, y: h - (row + 1) * cp, width: cp, height: cp))
                            return true
                        }
                        fills.add(drawn ? .blurryFallback : .blank)
                        done += 1
                        continue
                    }
                    guard let id = ids[i] else { fills.add(.blank); done += 1; continue }
                    group.addTask {
                        if case .image(let pb) = await thumbs.thumbnail(for: id, request: hq) {
                            return (i, pb, .highQuality)
                        }
                        if case .image(let pb) = await thumbs.thumbnail(for: id, request: .scanDisplay) {
                            return (i, pb, .blurryFallback)
                        }
                        return (i, nil, .blank)
                    }
                    return
                }
            }
            for _ in 0..<Self.maxInFlight { enqueue() }
            while let result = await group.next() {
                let (i, pb, fill) = result
                let drawn: Bool = {
                    guard let pb else { return false }
                    return autoreleasepool {
                        guard let img = ImagePixels.cgImage(pb) else { return false }
                        let col = i % columns, row = i / columns
                        ctx.draw(img, in: CGRect(x: col * cp, y: h - (row + 1) * cp, width: cp, height: cp))
                        return true
                    }
                }()
                fills.add(drawn ? fill : .blank)
                done += 1
                if done % 64 == 0 { progress(0.9 * Double(done) / Double(total)) }
                enqueue()
            }
        }

        // 叠加目标图（α ≤ 0.3，与预览同公式）。
        let alpha = OverlayBlendLimits.clamp(request.overlayAlpha)
        if alpha > 0, let targetBuf = request.target {
            autoreleasepool {
                let crop = request.layout.targetCrop
                if let target = ImagePixels.cgImage(targetBuf),
                   let part = target.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height).integral) {
                    ctx.setAlpha(alpha)
                    ctx.interpolationQuality = .medium
                    ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
                    ctx.setAlpha(1)
                }
            }
        }
        progress(0.92)

        try FileManager.default.createDirectory(at: Self.exportDirectory, withIntermediateDirectories: true)
        let url = Self.exportDirectory.appendingPathComponent("pinyi-\(UUID().uuidString).jpg")
        let ok: Bool = autoreleasepool {
            guard let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary)
            return CGImageDestinationFinalize(dest)
        }
        guard ok else {
            try? FileManager.default.removeItem(at: url)
            Self.log.error("export encode failed \(plan.logDescription, privacy: .public)")
            throw ExportError.encodingFailed
        }
        let seconds = Date().timeIntervalSince(t0)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let note = "\(plan.logDescription) \(fills.logDescription) 文件 \(bytes / 1_048_576)MB"
        Self.log.info("export done \(String(format: "%.1f", seconds), privacy: .public)s \(note, privacy: .public)")
        perf?.record(.exportTotal, seconds: seconds, items: plan.columns * plan.rows, note: note)
        progress(1)
        return url
    }

    func discard(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    func removeStaleExports() { try? FileManager.default.removeItem(at: Self.exportDirectory) }
}
