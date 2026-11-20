import CoreGraphics
import Darwin
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
import MosaicCore
import MosaicAppCore
@testable import PhotoMosaic

/// 模拟器上的真实预览 JPEG 和 `.hd` 再导出。只比较像素。
/// 不证明旧预览有没有被读取。Linux 不编译这个文件。不是页面点击验收。
final class FilledCellPixelTests: XCTestCase {
    func testPreviewAndExportMatchKnownFillAndShapeBackground() async throws {
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("fc-pixel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let inside = (r: UInt8(32), g: UInt8(96), b: UInt8(160))
        let mask = try CellMask(columns: 2, rows: 2, bitsV1: [0b0000_1101])
        let frame = ShapeFrame(background: .black, mask: mask)
        let cells = [
            MosaicLayout.CellAssignment(localIdentifier: "inside-photo", fill: CellColor(r: inside.r, g: inside.g, b: inside.b)),
            MosaicLayout.CellAssignment(localIdentifier: "outside-photo", fill: CellColor(r: 255, g: 0, b: 0)),
            MosaicLayout.CellAssignment(localIdentifier: ""),
            MosaicLayout.CellAssignment(localIdentifier: ""),
        ]
        let layout = MosaicLayout(cols: 2, rows: 2, cellAssignments: cells,
                                  targetSize: .init(width: 32, height: 32),
                                  targetCrop: CropRect(x: 0, y: 0, width: 32, height: 32),
                                  params: .init(overlayAlpha: 0.3, density: "coarse", seed: 4),
                                  shapeFrame: frame)
        let magenta = try solid(width: 4, height: 4, r: 255, g: 0, b: 255)
        let previewFile = try await bounded(seconds: 20) {
            try await ImageIOWorkImages(thumbnails: MissingThumbs()).writePreview(
                layout: layout, target: nil, overlayAlpha: 0.3, maxLongEdge: 320,
                fallbacks: [0: magenta, 1: magenta], into: outDir)
        }
        let previewURL = outDir.appendingPathComponent(previewFile.fileName)
        let request = ExportRequest(layout: layout, target: nil, overlayAlpha: 0.3, tier: .hd,
                                    cellFallbacks: [0: magenta, 1: magenta])
        let exportURL = try await bounded(seconds: 20) {
            try await LiveMosaicExporter(thumbnails: MissingThumbs()).export(request) { _ in }
        }
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let preview = try XCTUnwrap(decodeJPEG(previewURL))
        let exported = try XCTUnwrap(decodeJPEG(exportURL))
        let previewInside = sample(try bitmap(preview), image: preview, index: 0)
        let exportInside = sample(try bitmap(exported), image: exported, index: 0)
        assertNear(previewInside, inside, tolerance: 8, label: "预览内格")
        assertNear(exportInside, inside, tolerance: 8, label: "导出内格")
        assertNear(previewInside, exportInside, tolerance: 8, label: "预览和再导出")
        let previewOutside = sample(try bitmap(preview), image: preview, index: 1)
        let exportOutside = sample(try bitmap(exported), image: exported, index: 1)
        assertNear(previewOutside, (r: 0, g: 0, b: 0), tolerance: 8, label: "预览形状外仍是背景")
        assertNear(exportOutside, (r: 0, g: 0, b: 0), tolerance: 8, label: "导出形状外仍是背景")
    }

    private func sample(_ bytes: [UInt8], image: CGImage, index: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let columns = 2
        let cell = image.width / columns
        let column = index % columns, row = index / columns
        let x = column * cell + cell / 2
        let y = row * cell + cell / 2
        let o = y * image.width * 4 + x * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2])
    }

    private func assertNear(_ pixel: (r: UInt8, g: UInt8, b: UInt8), _ expected: (r: UInt8, g: UInt8, b: UInt8),
                            tolerance: Int, label: String) {
        for pair in [(pixel.r, expected.r), (pixel.g, expected.g), (pixel.b, expected.b)] {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), tolerance, "\(label) \(pixel)")
        }
    }

    private func bitmap(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(ok)
        return bytes
    }

    private func solid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
        }
        return try PixelBuffer(width: width, height: height, bytes: bytes)
    }

    private func decodeJPEG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// 生产 ImageIO 入口对一张普通可 seek JPEG 的调用记录。
/// 只覆盖 `readImage`、`readTarget`、`loadImage`。不是进程里的 `open` 次数。
final class FilledCellImageIOReadTests: XCTestCase {
    private let sentinel = (r: UInt8(255), g: UInt8(0), b: UInt8(255))

    func testProductionEntriesDecodeTheSameSeekableJPEG() async throws {
        let url = try seekableJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ProductionReadLog()
        defer { log.stop() }
        log.reset()
        let full = try await bounded(seconds: 5) {
            try await ImageIOWorkImages(thumbnails: MissingThumbs()).readImage(at: url)
        }
        assertNear(center(full), sentinel, tolerance: 8, label: "readImage")
        XCTAssertEqual(log.paths().filter { $0 == url.path }.count, 1)
        log.reset()
        let target = try await bounded(seconds: 5) {
            try await ImageIOWorkImages(thumbnails: MissingThumbs()).readTarget(at: url)
        }
        assertNear(center(target), sentinel, tolerance: 8, label: "readTarget")
        XCTAssertEqual(log.paths().filter { $0 == url.path }.count, 1)
        log.reset()
        let thumb = try await bounded(seconds: 5) { ImageIOWorkImages.loadImage(url, maxPixel: 32) }
        XCTAssertNotNil(thumb)
        XCTAssertEqual(log.paths().filter { $0 == url.path }.count, 1)
    }

    func testDeliberateProductionReadBreaksAZeroClaim() async throws {
        let url = try seekableJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ProductionReadLog()
        defer { log.stop() }
        log.reset()
        _ = try await ImageIOWorkImages(thumbnails: MissingThumbs()).readImage(at: url)
        XCTAssertEqual(log.paths().filter { $0 == url.path }.count, 1, "故意走生产 readImage 必须留下记录，否则零调用断言没有敏感性")
    }

    func testRawOpenAndCloseIsOutsideThisObservation() throws {
        let url = try seekableJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ProductionReadLog()
        defer { log.stop() }
        log.reset()
        let fd = Darwin.open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        _ = Darwin.close(fd)
        XCTAssertEqual(log.paths().filter { $0 == url.path }.count, 0, "裸 open/close 不在这次观察里，空记录不是 0 次 open")
    }

    func testWritePreviewAndExportDoNotCallProductionImageIOOnTheOldPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fc-read-\(UUID().uuidString)", isDirectory: true)
        let outDir = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPreview = root.appendingPathComponent("preview.jpg")
        try writeSolidJPEG(to: oldPreview, width: 8, height: 8, r: sentinel.r, g: sentinel.g, b: sentinel.b)
        try assertSeekableFile(oldPreview)
        let log = ProductionReadLog()
        defer { log.stop() }
        log.reset()
        let proved = try await bounded(seconds: 5) {
            try await ImageIOWorkImages(thumbnails: MissingThumbs()).readImage(at: oldPreview)
        }
        assertNear(center(proved), sentinel, tolerance: 8, label: "同一路径的生产解码")
        XCTAssertEqual(log.paths().filter { $0 == oldPreview.path }.count, 1)
        log.reset()

        let mask = try CellMask(columns: 2, rows: 2, bitsV1: [0b0000_1101])
        let layout = MosaicLayout(cols: 2, rows: 2, cellAssignments: [
            MosaicLayout.CellAssignment(localIdentifier: "", fill: CellColor(r: 32, g: 96, b: 160)),
            MosaicLayout.CellAssignment(localIdentifier: ""),
            MosaicLayout.CellAssignment(localIdentifier: ""),
            MosaicLayout.CellAssignment(localIdentifier: ""),
        ], targetSize: .init(width: 32, height: 32), targetCrop: CropRect(x: 0, y: 0, width: 32, height: 32),
           params: .init(overlayAlpha: 0, density: "coarse", seed: 4),
           shapeFrame: ShapeFrame(background: .black, mask: mask))
        _ = try await bounded(seconds: 20) {
            try await ImageIOWorkImages(thumbnails: MissingThumbs()).writePreview(
                layout: layout, target: nil, overlayAlpha: 0, maxLongEdge: 320, fallbacks: [:], into: outDir)
        }
        let request = ExportRequest(layout: layout, target: nil, tier: .hd)
        let exportURL = try await bounded(seconds: 20) {
            try await LiveMosaicExporter(thumbnails: MissingThumbs()).export(request) { _ in }
        }
        defer { try? FileManager.default.removeItem(at: exportURL) }
        XCTAssertEqual(log.paths().filter { $0 == oldPreview.path }.count, 0,
                       "这两次直接调用没有经过 readImage / readTarget / loadImage。不是打开作品再导出，也不是 0 次 open")
    }

    private func seekableJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fc-seek-\(UUID().uuidString).jpg")
        try writeSolidJPEG(to: url, width: 8, height: 8, r: sentinel.r, g: sentinel.g, b: sentinel.b)
        try assertSeekableFile(url)
        return url
    }

    private func assertSeekableFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertGreaterThan(values.fileSize ?? 0, 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        XCTAssertGreaterThan(try handle.seekToEnd(), 0)
    }

    private func center(_ buffer: PixelBuffer) -> (r: UInt8, g: UInt8, b: UInt8) {
        let x = buffer.width / 2, y = buffer.height / 2
        let o = y * buffer.bytesPerRow + x * 4
        return (buffer.bytes[o], buffer.bytes[o + 1], buffer.bytes[o + 2])
    }

    private func assertNear(_ pixel: (r: UInt8, g: UInt8, b: UInt8), _ expected: (r: UInt8, g: UInt8, b: UInt8),
                            tolerance: Int, label: String) {
        for pair in [(pixel.r, expected.r), (pixel.g, expected.g), (pixel.b, expected.b)] {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), tolerance, "\(label) \(pixel)")
        }
    }

    private func writeSolidJPEG(to url: URL, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [
            CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1,
        ])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return XCTFail("写不出 jpeg")
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}

/// 普通照片作品：打开后走 `exportOpenedTapped`，再单独画一张带 fc 的预览和 `.hd` 导出。
/// 存盘守护仍在。不是页面点击，也不是 0 次 open。
@MainActor
final class OrdinaryPhotoFillEvidenceTests: XCTestCase {
    private let photo = (r: UInt8(20), g: UInt8(180), b: UInt8(40))
    private let targetColor = (r: UInt8(20), g: UInt8(40), b: UInt8(220))
    private let sentinel = (r: UInt8(255), g: UInt8(0), b: UInt8(255))
    private let fill = (r: UInt8(32), g: UInt8(96), b: UInt8(160))

    func testOpenedWorkExportConsumesStoredTargetAndNotSentinelPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let known = root.appendingPathComponent("known-target.jpg")
        try writeSolidJPEG(to: known, width: 16, height: 16, r: targetColor.r, g: targetColor.g, b: targetColor.b)
        try assertSeekableFile(known)
        let layout = photoLayout(fill: nil)
        let store = FileWorksStore(directory: root.appendingPathComponent("Works", isDirectory: true),
                                   images: ImageIOWorkImages(thumbnails: TwoColorThumbs(photo: photo, other: photo)))
        let saved = try await store.save(WorkDraft(layout: layout, target: try solid(width: 8, height: 8, r: 1, g: 2, b: 3),
                                                   overlayAlpha: 0, origin: .savedManually))
        let dir = saved.summary.previewURL.deletingLastPathComponent()
        let targetName = try XCTUnwrap(saved.summary.meta.targetFile)
        let targetURL = dir.appendingPathComponent(targetName)
        let previewURL = saved.summary.previewURL
        try FileManager.default.removeItem(at: targetURL)
        try FileManager.default.copyItem(at: known, to: targetURL)
        try writeSolidJPEG(to: previewURL, width: 16, height: 16, r: sentinel.r, g: sentinel.g, b: sentinel.b)

        let proved = try await ImageIOWorkImages(thumbnails: TwoColorThumbs(photo: photo, other: photo)).readTarget(at: targetURL)
        assertNear(center(proved), targetColor, tolerance: 8, label: "同一 JPEG 经生产 readTarget")
        let log = ProductionReadLog()
        defer { log.stop() }
        log.reset()
        let again = try await ImageIOWorkImages(thumbnails: TwoColorThumbs(photo: photo, other: photo)).readTarget(at: targetURL)
        assertNear(center(again), targetColor, tolerance: 8, label: "观察器正对照")
        XCTAssertEqual(log.paths().filter { $0 == targetURL.path }.count, 1, "正对照没有记下这次生产读取，后面的零记录没有敏感性")
        log.reset()

        let controller = WorksController(store: store, existence: AllPresent(), images: ImageIOWorkImages(thumbnails: TwoColorThumbs(photo: photo, other: photo)))
        let exporter = RecordingExporter(thumbs: TwoColorThumbs(photo: photo, other: photo))
        controller.exportHandler = exporter
        try await within(20) { await controller.open(saved.summary.id) }
        XCTAssertEqual(controller.openedWork?.id, saved.summary.id)
        let fallbackURL = dir.appendingPathComponent("fallback.png")
        try writeSolidJPEG(to: fallbackURL, width: 8, height: 8, r: sentinel.r, g: sentinel.g, b: sentinel.b)
        XCTAssertEqual(log.paths().filter { $0 == previewURL.path }.count, 0, "打开作品的 ImageIO 入口没有读哨兵预览。裸 open 不在此列")
        XCTAssertEqual(log.paths().filter { $0 == fallbackURL.path }.count, 0)
        log.reset()

        try await within(20) { await controller.exportOpenedTapped(purpose: .save) }
        XCTAssertNil(exporter.failure)
        XCTAssertEqual(exporter.fallbacks.count, 0)
        let consumed = try XCTUnwrap(exporter.target, "导出没有消费作品里的目标 JPEG")
        assertNear(center(consumed), targetColor, tolerance: 8, label: "exportOpenedTapped 读到的目标图")
        XCTAssertGreaterThanOrEqual(log.paths().filter { $0 == targetURL.path }.count, 1, "完整导出路径没有消费这张 JPEG")
        XCTAssertEqual(log.paths().filter { $0 == previewURL.path }.count, 0, "导出路径的 ImageIO 入口没有读哨兵预览。不是 0 次 open")
        XCTAssertEqual(log.paths().filter { $0 == fallbackURL.path }.count, 0, "导出路径的 ImageIO 入口没有读哨兵兜底文件")
        let exported = try XCTUnwrap(decodeJPEG(try XCTUnwrap(exporter.url)))
        assertNear(sample(try bitmap(exported), image: exported, columns: 2, index: 0), photo, tolerance: 12, label: "导出格不是哨兵预览")
        assertNear(sample(try bitmap(exported), image: exported, columns: 2, index: 1), photo, tolerance: 12, label: "邻格")

        log.reset()
        _ = try await ImageIOWorkImages(thumbnails: TwoColorThumbs(photo: photo, other: photo)).readImage(at: previewURL)
        XCTAssertEqual(log.paths().filter { $0 == previewURL.path }.count, 1, "故意读哨兵预览必须被击穿")
    }

    func testOrdinaryPhotoFillPreviewMatchesExportAndSaveStaysRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-fc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = photoLayout(fill: CellColor(r: fill.r, g: fill.g, b: fill.b))
        let thumbs = TwoColorThumbs(photo: (r: 220, g: 30, b: 30), other: photo)
        let previewFile = try await within(20) {
            try await ImageIOWorkImages(thumbnails: thumbs).writePreview(
                layout: layout, target: nil, overlayAlpha: 0, maxLongEdge: 320, fallbacks: [:], into: root)
        }
        let request = ExportRequest(layout: layout, target: nil, tier: .hd)
        let exportURL = try await within(20) {
            try await LiveMosaicExporter(thumbnails: thumbs).export(request) { _ in }
        }
        defer { try? FileManager.default.removeItem(at: exportURL) }
        let preview = try XCTUnwrap(decodeJPEG(root.appendingPathComponent(previewFile.fileName)))
        let exported = try XCTUnwrap(decodeJPEG(exportURL))
        let previewFill = sample(try bitmap(preview), image: preview, columns: 2, index: 0)
        let exportFill = sample(try bitmap(exported), image: exported, columns: 2, index: 0)
        assertNear(previewFill, fill, tolerance: 8, label: "普通照片预览 fc 中心")
        assertNear(exportFill, fill, tolerance: 8, label: "普通照片导出 fc 中心")
        assertNear(previewFill, exportFill, tolerance: 8, label: "预览和再导出")
        assertNear(sample(try bitmap(preview), image: preview, columns: 2, index: 1), photo, tolerance: 12, label: "预览邻格")
        assertNear(sample(try bitmap(exported), image: exported, columns: 2, index: 1), photo, tolerance: 12, label: "导出邻格")

        let store = FileWorksStore(directory: root.appendingPathComponent("Works", isDirectory: true), images: ImageIOWorkImages(thumbnails: thumbs))
        do {
            _ = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0, origin: .savedManually))
            XCTFail("带 fc 的普通照片仍不能写盘")
        } catch let error as WorksError {
            XCTAssertEqual(error, .unsupportedFilledCells)
        } catch {
            XCTFail("意外错误 \(error)")
        }
        let listed = await store.list()
        XCTAssertTrue(listed.isEmpty)
    }

    /// 超时是失败，不当成「没有读取」，也不当成取消。
    private func within<T>(_ seconds: TimeInterval, _ work: () async throws -> T) async throws -> T {
        let box = OSAllocatedUnfairLock<(Result<T, Error>)?>(initialState: nil)
        let done = XCTestExpectation(description: "within")
        let task = Task { @MainActor in
            let result: Result<T, Error>
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            box.withLock { $0 = result }
            done.fulfill()
        }
        let outcome = await XCTWaiter().fulfillment(of: [done], timeout: seconds)
        if outcome != .completed {
            task.cancel()
            XCTFail("操作超过 \(seconds) 秒。这不是零读取，也不是导出被取消的证据")
            throw CocoaError(.userCancelled)
        }
        return try XCTUnwrap(box.withLock { $0 }).get()
    }

    private func photoLayout(fill: CellColor?) -> MosaicLayout {
        MosaicLayout(cols: 2, rows: 1, cellAssignments: [
            MosaicLayout.CellAssignment(localIdentifier: "filled", fill: fill),
            MosaicLayout.CellAssignment(localIdentifier: "neighbor"),
        ], targetSize: .init(width: 32, height: 16),
           targetCrop: CropRect(x: 0, y: 0, width: 32, height: 16),
           params: .init(overlayAlpha: 0, density: "coarse", seed: 4))
    }

    private func sample(_ bytes: [UInt8], image: CGImage, columns: Int, index: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let cell = image.width / columns
        let column = index % columns, row = index / columns
        let x = column * cell + cell / 2
        let y = row * cell + cell / 2
        let o = y * image.width * 4 + x * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2])
    }

    private func assertNear(_ pixel: (r: UInt8, g: UInt8, b: UInt8), _ expected: (r: UInt8, g: UInt8, b: UInt8),
                            tolerance: Int, label: String) {
        for pair in [(pixel.r, expected.r), (pixel.g, expected.g), (pixel.b, expected.b)] {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), tolerance, "\(label) \(pixel)")
        }
    }

    private func bitmap(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(ok)
        return bytes
    }

    private func solid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
        }
        return try PixelBuffer(width: width, height: height, bytes: bytes)
    }

    private func decodeJPEG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func center(_ buffer: PixelBuffer) -> (r: UInt8, g: UInt8, b: UInt8) {
        let x = buffer.width / 2, y = buffer.height / 2
        let o = y * buffer.bytesPerRow + x * 4
        return (buffer.bytes[o], buffer.bytes[o + 1], buffer.bytes[o + 2])
    }

    private func assertSeekableFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertGreaterThan(values.fileSize ?? 0, 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        XCTAssertGreaterThan(try handle.seekToEnd(), 0)
    }

    private func writeSolidJPEG(to url: URL, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return XCTFail("写不出 jpeg")
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}

private struct AllPresent: PhotoExistenceChecking {
    func existingIdentifiers(among identifiers: [String]) async -> Set<String> {
        Set(identifiers.filter { !$0.isEmpty })
    }
}

private struct TwoColorThumbs: ThumbnailProviding {
    var photo: (r: UInt8, g: UInt8, b: UInt8)
    var other: (r: UInt8, g: UInt8, b: UInt8)
    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        let color = assetID == "neighbor" ? other : photo
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = color.r; bytes[i + 1] = color.g; bytes[i + 2] = color.b
        }
        guard let tile = try? PixelBuffer(width: 8, height: 8, bytes: bytes) else { return .failed }
        return .image(tile)
    }
}

@MainActor
private final class RecordingExporter: WorkExportHandling {
    let thumbs: TwoColorThumbs
    var target: PixelBuffer?
    var fallbacks: [Int: PixelBuffer] = [:]
    var url: URL?
    var failure: Error?
    init(thumbs: TwoColorThumbs) { self.thumbs = thumbs }
    func exportWork(layout: MosaicLayout, target: PixelBuffer?, fallbacks: [Int: PixelBuffer], purpose: ExportPurpose) async {
        self.target = target
        self.fallbacks = fallbacks
        let request = ExportRequest(layout: layout, target: target, tier: .hd, cellFallbacks: fallbacks)
        do { url = try await LiveMosaicExporter(thumbnails: thumbs).export(request) { _ in } }
        catch { failure = error }
    }
}

private struct MissingThumbs: ThumbnailProviding {
    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult { .missing }
}

private final class ProductionReadLog: @unchecked Sendable {
    private let urls = OSAllocatedUnfairLock(initialState: [String]())
    private let token: UUID

    init() {
        let urls = self.urls
        token = ImageIOReadObservation.install { url in
            urls.withLock { $0.append(url.path) }
        }
    }

    func stop() { ImageIOReadObservation.remove(token) }
    func reset() { urls.withLock { $0.removeAll() } }
    func paths() -> [String] { urls.withLock { $0 } }
}

private func bounded<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = OSAllocatedUnfairLock<(Result<T, Error>)?>(initialState: nil)
    let done = XCTestExpectation(description: "bounded")
    Task {
        let result: Result<T, Error>
        do { result = .success(try await work()) }
        catch { result = .failure(error) }
        box.withLock { $0 = result }
        done.fulfill()
    }
    let outcome = await XCTWaiter().fulfillment(of: [done], timeout: seconds)
    guard outcome == .completed else {
        XCTFail("操作超过 \(seconds) 秒")
        throw CocoaError(.userCancelled)
    }
    let result = try XCTUnwrap(box.withLock { $0 })
    return try result.get()
}
