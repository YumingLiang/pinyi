import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 假图片编解码：预览 / 目标图写成小文件，内容由布局 / 尺寸决定（可逐字节比较）；可在指定步骤失败或卡住。
final class FakeWorkImages: WorkImageEncoding, Sendable {
    enum Step: Sendable, Hashable { case preview, target }
    struct State: Sendable {
        var failAt: Step?
        var previews = 0
        var targets = 0
        var reads = 0
    }
    let state = Locked(State())
    let gate: Locked<GatePoint?>
    init(gate: GatePoint? = nil) { self.gate = Locked(gate) }

    static func previewBytes(_ layout: MosaicLayout) -> Data {
        Data("PREVIEW:\(layout.cols)x\(layout.rows):\(layout.cellAssignments.map(\.localIdentifier).joined(separator: ","))".utf8)
    }

    func writePreview(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, maxLongEdge: Int,
                      into directory: URL) async throws -> WorkImageFile {
        state.update { $0.previews += 1 }
        if let g = gate.get() {
            await g.reached.open()
            await g.release.wait()
        }
        if state.get().failAt == .preview { throw ExportError.encodingFailed }
        try Self.previewBytes(layout).write(to: directory.appendingPathComponent("preview.jpg"))
        let scale = Double(maxLongEdge) / Double(max(layout.cols, layout.rows))
        return WorkImageFile(fileName: "preview.jpg", pixelWidth: Int(Double(layout.cols) * scale),
                             pixelHeight: Int(Double(layout.rows) * scale))
    }

    func writeTarget(_ target: PixelBuffer, maxLongEdge: Int, into directory: URL) async throws -> WorkImageFile {
        state.update { $0.targets += 1 }
        if state.get().failAt == .target { throw CocoaError(.fileWriteOutOfSpace) }
        try Data("TARGET:\(target.width)x\(target.height)".utf8).write(to: directory.appendingPathComponent("target.jpg"))
        return WorkImageFile(fileName: "target.jpg", pixelWidth: target.width, pixelHeight: target.height)
    }

    func readTarget(at url: URL) async throws -> PixelBuffer {
        state.update { $0.reads += 1 }
        _ = try Data(contentsOf: url)
        return try PixelBuffer(width: 2, height: 2, bytes: [UInt8](repeating: 128, count: 16))
    }
}

/// 假「原照片还在不在」。
final class FakeExistence: PhotoExistenceChecking, Sendable {
    let deleted = Locked(Set<String>())
    let calls = Locked(0)
    func existingIdentifiers(among identifiers: [String]) async -> Set<String> {
        calls.update { $0 += 1 }
        let gone = deleted.get()
        return Set(identifiers.filter { !gone.contains($0) })
    }
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
    func exportWork(layout: MosaicLayout, target: PixelBuffer?, purpose: ExportPurpose) async {
        calls.append((layout, target != nil, purpose))
    }
}

func sampleLayout(_ ids: [String], cols: Int = 3, seed: UInt64 = 7) -> MosaicLayout {
    let rows = max(1, ids.count / cols)
    return MosaicLayout(cols: cols, rows: rows, cellAssignments: ids.map { MosaicLayout.CellAssignment(localIdentifier: $0) },
                        targetSize: .init(width: 300, height: 200), targetCrop: CropRect(x: 0, y: 0, width: 300, height: 200),
                        params: .init(overlayAlpha: 0.15, density: "coarse", seed: seed))
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
