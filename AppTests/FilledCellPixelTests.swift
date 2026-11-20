import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
import MosaicCore
import MosaicAppCore
@testable import PhotoMosaic

/// 模拟器上的真实预览 JPEG 和再导出 JPEG。Linux 不编译这个文件。
/// 这不是目标页或确认页的点击验收。
final class FilledCellPixelTests: XCTestCase {
    private let inside = (r: UInt8(32), g: UInt8(96), b: UInt8(160))

    func testFilledCellMatchesAcrossPreviewAndExportAndDoesNotOpenTheOldPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fc-pixel-\(UUID().uuidString)", isDirectory: true)
        let oldDir = root.appendingPathComponent("old", isDirectory: true)
        let outDir = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPreview = oldDir.appendingPathComponent("preview.jpg")
        try writeSolidJPEG(to: oldPreview, width: 8, height: 8, r: 255, g: 0, b: 255)
        let oldBytes = try Data(contentsOf: oldPreview)
        let probe = try OpenProbe(url: oldPreview)
        defer { probe.close() }
        XCTAssertEqual(probe.drainOpens(), 0, "登记之后先清掉监视本身的打开")
        let control = open(oldPreview.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(control, 0)
        close(control)
        XCTAssertGreaterThan(probe.drainOpens(), 0, "正对照必须让内核记到这个旧预览文件被打开")

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
        let fallbacks = [0: magenta, 1: magenta]
        let thumbs = NoFetchThumbs()
        let images = ImageIOWorkImages(thumbnails: thumbs)
        let previewFile = try await images.writePreview(layout: layout, target: nil, overlayAlpha: 0.3,
                                                        maxLongEdge: 320, fallbacks: fallbacks, into: outDir)
        let previewURL = outDir.appendingPathComponent(previewFile.fileName)
        let request = ExportRequest(layout: layout, target: nil, overlayAlpha: 0.3, tier: .hd, cellFallbacks: fallbacks)
        let exportURL = try await LiveMosaicExporter(thumbnails: thumbs).export(request) { _ in }
        defer { try? FileManager.default.removeItem(at: exportURL) }

        XCTAssertEqual(probe.drainOpens(), 0, "真实预览和再导出没有打开旧预览文件")
        XCTAssertEqual(try Data(contentsOf: oldPreview), oldBytes)
        XCTAssertEqual(thumbs.ids(), [], "fc 格和形状外不取照片")

        let preview = try XCTUnwrap(decodeJPEG(previewURL))
        let exported = try XCTUnwrap(decodeJPEG(exportURL))
        let previewBytes = try bitmap(preview)
        let exportBytes = try bitmap(exported)
        let previewInside = sample(previewBytes, image: preview, index: 0)
        let exportInside = sample(exportBytes, image: exported, index: 0)
        assertNear(previewInside, inside, tolerance: 8, label: "预览内格")
        assertNear(exportInside, inside, tolerance: 8, label: "导出内格")
        assertNear(previewInside, exportInside, tolerance: 8, label: "预览和再导出")
        let previewOutside = sample(previewBytes, image: preview, index: 1)
        let exportOutside = sample(exportBytes, image: exported, index: 1)
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
            return XCTFail("写不出旧预览")
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func decodeJPEG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// 内核级打开计数。正对照打开文件之后次数增加；渲染期间不再增加，才算旧预览读取为 0。
private final class OpenProbe {
    private let fd: Int32
    private let queue: Int32

    init(url: URL) throws {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        queue = kqueue()
        guard queue >= 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var change = kevent(ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                            fflags: UInt32(NOTE_OPEN), data: 0, udata: nil)
        guard Darwin.kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            close(queue)
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func close() {
        Darwin.close(queue)
        Darwin.close(fd)
    }

    func drainOpens() -> Int {
        var count = 0
        while true {
            var event = kevent()
            var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let n = Darwin.kevent(queue, nil, 0, &event, 1, &timeout)
            if n <= 0 { break }
            if event.fflags & UInt32(NOTE_OPEN) != 0 { count += 1 }
        }
        return count
    }
}

private final class NoFetchThumbs: ThumbnailProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var fetched: [String] = []

    func ids() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return fetched
    }

    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        lock.lock()
        fetched.append(assetID)
        lock.unlock()
        return .missing
    }
}
