import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 假图片编解码：预览 / 目标图写成小文件，内容由布局 / 尺寸决定（可逐字节比较）；可在指定步骤失败或卡住。
final class FakeWorkImages: WorkImageEncoding, Sendable {
    enum Step: Sendable, Hashable { case preview, target, fallback }
    struct State: Sendable {
        var failAt: Step?
        var previews = 0
        var targets = 0
        var reads = 0
        var imageReads = 0
        var fallbackWrites = 0
        /// 最近一次 writePreview 收到的兜底格（下标 → 小图平均色）。
        var lastFallbacks: [Int: RGB8] = [:]
    }
    struct RGB8: Sendable, Hashable { var r, g, b: UInt8 }
    let state = Locked(State())
    let gate: Locked<GatePoint?>
    init(gate: GatePoint? = nil) { self.gate = Locked(gate) }

    /// 假预览每格像素（预览文件里存真像素，裁兜底格时能读回）。
    static let cellPixels = 4

    /// 预览文件的第一行（布局摘要）：照片 ID；兜底格写成 `fb#rrggbb`（兜底小图的平均色）。
    static func previewBytes(_ layout: MosaicLayout, fallbacks: [Int: RGB8] = [:]) -> Data {
        let cells = layout.cellAssignments.enumerated().map { i, c -> String in
            if let f = fallbacks[i] { return String(format: "fb#%02x%02x%02x", f.r, f.g, f.b) }
            return c.localIdentifier
        }
        return Data("PREVIEW:\(layout.cols)x\(layout.rows):\(cells.joined(separator: ","))".utf8)
    }

    /// 读预览文件的第一行（与 `previewBytes` 比较）。
    static func previewHeader(_ url: URL) throws -> Data {
        let d = try Data(contentsOf: url)
        return d.firstIndex(of: 0x0A).map { d[..<$0] } ?? d
    }

    /// 一张「照片」的颜色（按 ID 定，测试里可预期）。
    static func color(of id: String) -> RGB8 {
        var h: UInt32 = 2_166_136_261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return RGB8(r: UInt8(40 + h % 170), g: UInt8(40 + (h >> 8) % 170), b: UInt8(40 + (h >> 16) % 170))
    }

    static func average(_ p: PixelBuffer) -> RGB8 {
        var r = 0, g = 0, b = 0
        for y in 0..<p.height { for x in 0..<p.width { let c = p.rgb(x: x, y: y); r += Int(c.r); g += Int(c.g); b += Int(c.b) } }
        let n = p.width * p.height
        return RGB8(r: UInt8((r + n / 2) / n), g: UInt8((g + n / 2) / n), b: UInt8((b + n / 2) / n))
    }

    static func raw(_ p: PixelBuffer) -> Data {
        var d = Data("RAWIMG \(p.width) \(p.height)\n".utf8)
        var bytes = [UInt8](); bytes.reserveCapacity(p.width * p.height * 4)
        for y in 0..<p.height { for x in 0..<p.width { let c = p.rgb(x: x, y: y); bytes += [c.r, c.g, c.b, 255] } }
        d.append(contentsOf: bytes)
        return d
    }

    static func decodeRaw(_ d: Data) -> PixelBuffer? {
        guard let start = d.range(of: Data("RAWIMG ".utf8)) else { return nil }
        guard let nl = d[start.upperBound...].firstIndex(of: 0x0A),
              let header = String(data: d[start.upperBound..<nl], encoding: .utf8) else { return nil }
        let parts = header.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let bytes = [UInt8](d[(nl + 1)...])
        return try? PixelBuffer(width: parts[0], height: parts[1], bytes: bytes)
    }

    /// 按布局「画」预览：每格纯色（照片色 / 兜底小图平均色 / 白），再按 α 叠加目标图（与 App 同一换算），存真像素。
    static func render(_ layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, fallbacks: [Int: RGB8]) -> PixelBuffer {
        let cp = cellPixels, w = layout.cols * cp, h = layout.rows * cp
        let alpha = target == nil ? 0 : OverlayBlendLimits.clamp(overlayAlpha)
        let crop = target.map { WorkFallbackImages.scaledCrop(layout, width: $0.width, height: $0.height) }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for py in 0..<h {
            for px in 0..<w {
                let cell = (py / cp) * layout.cols + px / cp
                let id = layout.cellAssignments[cell].localIdentifier
                let c = fallbacks[cell] ?? (id.isEmpty ? RGB8(r: 255, g: 255, b: 255) : color(of: id))
                var v = (Double(c.r), Double(c.g), Double(c.b))
                if alpha > 0, let target, let crop {
                    let t = WorkFallbackImages.bilinear(target, crop.x + (Double(px) + 0.5) * crop.width / Double(w) - 0.5,
                                                        crop.y + (Double(py) + 0.5) * crop.height / Double(h) - 0.5)
                    v = ((1 - alpha) * v.0 + alpha * t.0, (1 - alpha) * v.1 + alpha * t.1, (1 - alpha) * v.2 + alpha * t.2)
                }
                let o = (py * w + px) * 4
                bytes[o] = WorkFallbackImages.byte(v.0); bytes[o + 1] = WorkFallbackImages.byte(v.1); bytes[o + 2] = WorkFallbackImages.byte(v.2)
            }
        }
        return try! PixelBuffer(width: w, height: h, bytes: bytes)
    }

    func writePreview(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, maxLongEdge: Int,
                      fallbacks: [Int: PixelBuffer], into directory: URL) async throws -> WorkImageFile {
        state.update { $0.previews += 1 }
        if let g = gate.get() {
            await g.reached.open()
            await g.release.wait()
        }
        if state.get().failAt == .preview { throw ExportError.encodingFailed }
        let avg = fallbacks.mapValues(Self.average)
        state.update { $0.lastFallbacks = avg }
        var data = Self.previewBytes(layout, fallbacks: avg)
        data.append(0x0A)
        data.append(Self.raw(Self.render(layout, target: target, overlayAlpha: overlayAlpha, fallbacks: avg)))
        try data.write(to: directory.appendingPathComponent("preview.jpg"))
        let scale = Double(maxLongEdge) / Double(max(layout.cols, layout.rows))
        return WorkImageFile(fileName: "preview.jpg", pixelWidth: Int(Double(layout.cols) * scale),
                             pixelHeight: Int(Double(layout.rows) * scale))
    }

    func writeTarget(_ target: PixelBuffer, maxLongEdge: Int, into directory: URL) async throws -> WorkImageFile {
        state.update { $0.targets += 1 }
        if state.get().failAt == .target { throw CocoaError(.fileWriteOutOfSpace) }
        var data = Data("TARGET:\(target.width)x\(target.height)\n".utf8)
        data.append(Self.raw(target))
        try data.write(to: directory.appendingPathComponent("target.jpg"))
        return WorkImageFile(fileName: "target.jpg", pixelWidth: target.width, pixelHeight: target.height)
    }

    func readTarget(at url: URL) async throws -> PixelBuffer {
        state.update { $0.reads += 1 }
        let d = try Data(contentsOf: url)
        return try Self.decodeRaw(d) ?? PixelBuffer(width: 2, height: 2, bytes: [UInt8](repeating: 128, count: 16))
    }

    func readImage(at url: URL) async throws -> PixelBuffer {
        state.update { $0.imageReads += 1 }
        guard let p = Self.decodeRaw(try Data(contentsOf: url)) else { throw ExportError.encodingFailed }
        return p
    }

    func writeFallback(_ image: PixelBuffer, into directory: URL) async throws -> WorkImageFile {
        state.update { $0.fallbackWrites += 1 }
        if state.get().failAt == .fallback { throw CocoaError(.fileWriteOutOfSpace) }
        try Self.raw(image).write(to: directory.appendingPathComponent("fallback.png"))
        return WorkImageFile(fileName: "fallback.png", pixelWidth: image.width, pixelHeight: image.height)
    }
}

/// 假「原照片还在不在」。`deleted` 里的 ID 取不到——删除和「后来被隐藏」在 App 里是同一件事
/// （按 ID 取图不含隐藏照片），这里用同一个集合模拟；`hidden` 只是给测试读起来更清楚的别名入口。
final class FakeExistence: PhotoExistenceChecking, Sendable {
    let deleted = Locked(Set<String>())
    let calls = Locked(0)
    /// false = 模拟受限访问 / 无权限（取不到也不能确认是真没了）。
    let fullAccess = Locked(true)
    func existingIdentifiers(among identifiers: [String]) async -> Set<String> {
        calls.update { $0 += 1 }
        let gone = deleted.get()
        return Set(identifiers.filter { !gone.contains($0) })
    }
    func canConfirmMissing() async -> Bool { fullAccess.get() }
    /// 模拟在「照片」App 里把照片设为隐藏：PhotoKit 按 ID 取（includeHiddenAssets = false）不再返回它。
    func hide(_ ids: String...) { deleted.update { $0.formUnion(ids) } }
    /// 取消隐藏：又能取到了。
    func unhide(_ ids: String...) { deleted.update { $0.subtract(ids) } }
}

/// 假墙钟：每次取时间 +1 s（保证新旧顺序确定）。
final class FakeWallClock: Sendable {
    let t = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    var provider: @Sendable () -> Date {
        { [t] in t.update { d in d = d.addingTimeInterval(1); return d } }
    }
}

/// 记录导出请求的假导出线。
@MainActor
final class RecordingWorkExporter: WorkExportHandling {
    var calls: [(MosaicLayout, Bool, ExportPurpose)] = []
    /// 每次导出收到的兜底格（下标 → 小图平均色）。
    var fallbacks: [[Int: FakeWorkImages.RGB8]] = []
    func exportWork(layout: MosaicLayout, target: PixelBuffer?, fallbacks: [Int: PixelBuffer], purpose: ExportPurpose) async {
        calls.append((layout, target != nil, purpose))
        self.fallbacks.append(fallbacks.mapValues(FakeWorkImages.average))
    }
}

func sampleLayout(_ ids: [String], cols: Int = 3, seed: UInt64 = 7) -> MosaicLayout {
    let rows = max(1, ids.count / cols)
    return MosaicLayout(cols: cols, rows: rows, cellAssignments: ids.map { MosaicLayout.CellAssignment(localIdentifier: $0) },
                        targetSize: .init(width: 300, height: 200), targetCrop: CropRect(x: 0, y: 0, width: 300, height: 200),
                        params: .init(overlayAlpha: 0.15, density: "coarse", seed: seed))
}

/// 同 `sampleLayout`，空串格子标成预览兜底格（`fallback == true`）：原照片取不到、找不到替代、用旧预览裁切填充。
func sampleFallbackLayout(_ ids: [String], cols: Int = 3, seed: UInt64 = 7) -> MosaicLayout {
    var l = sampleLayout(ids, cols: cols, seed: seed)
    for i in l.cellAssignments.indices where l.cellAssignments[i].localIdentifier.isEmpty { l.cellAssignments[i].fallback = true }
    return l
}

func smallTarget() throws -> PixelBuffer {
    try PixelBuffer(width: 4, height: 3, bytes: [UInt8](repeating: 200, count: 4 * 3 * 4))
}

/// 等 WorksController 状态满足条件（观察回调，不轮询；看门狗只防卡死）。
@MainActor
func waitForWorks(_ c: WorksController, _ what: String = "", file: StaticString = #filePath, line: UInt = #line,
                  _ predicate: @escaping @MainActor (WorksState) -> Bool) async {
    if predicate(c.state) { return }
    var token: UUID?
    let ok: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        var done = false
        let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !done { done = true; cont.resume(returning: false) }
        }
        token = c.observe { s in
            if !done, predicate(s) { done = true; watchdog.cancel(); cont.resume(returning: true) }
        }
    }
    if let token { c.removeObserver(token) }
    if !ok { XCTFail("等待作品状态超时：\(what)", file: file, line: line) }
}
