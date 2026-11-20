import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import MosaicCore
import MosaicAppCore
@testable import PhotoMosaic

/// 临时作品目录真写盘，换一个 store 打开，再导出。不是可见点击，也不是 0 次 open。
final class ShapeWorkDiskPixelTests: XCTestCase {
    func testSavedShapeAndTextReexportMatchesTheFrozenMask() async throws {
        try await check(source: .preset(.heart), background: .black)
        try await check(source: .text(lines: ["生日快乐", "宝贝"]), background: .white)
        try await check(source: .text(lines: ["LOVE"]), background: .black)
        try await check(source: .preset(.star), background: .white)
    }

    private func check(source: ShapeSource, background: ShapeBackground) async throws {
        let mask = try CellMask(columns: 2, rows: 1, bitsV1: [0b0000_0001])
        let manifest = ShapeManifest(spec: ShapeSpec(source: source, palette: .blue, background: background), mask: mask)
        let layout = MosaicLayout(cols: 2, rows: 1,
                                  cellAssignments: [MosaicLayout.CellAssignment(localIdentifier: "fixture"),
                                                    MosaicLayout.CellAssignment(localIdentifier: "outside")],
                                  targetSize: .init(width: 8, height: 4),
                                  targetCrop: CropRect(x: 0, y: 0, width: 8, height: 4),
                                  params: .init(overlayAlpha: 0, density: source.isText ? "fine" : "coarse", seed: 9),
                                  shapeFrame: ShapeFrame(background: background, mask: mask),
                                  shapeManifest: manifest)
        let thumbs = RedSwatchThumbs()
        let direct = try await export(layout, thumbs: thumbs)
        defer { try? FileManager.default.removeItem(at: direct) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shape-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileWorksStore(directory: root, images: ImageIOWorkImages(thumbnails: thumbs))
        let saved = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0, origin: .savedManually))
        XCTAssertNil(saved.summary.meta.targetFile)
        let reloaded = try await FileWorksStore(directory: root, images: ImageIOWorkImages(thumbnails: thumbs)).load(saved.summary.id)
        XCTAssertEqual(reloaded.layout.shapeManifest?.mask, mask)
        XCTAssertEqual(reloaded.layout.shapeFrame?.background, background)
        let again = try await export(reloaded.layout, thumbs: thumbs)
        defer { try? FileManager.default.removeItem(at: again) }

        let left = try XCTUnwrap(decode(direct))
        let right = try XCTUnwrap(decode(again))
        XCTAssertEqual(left.width, right.width)
        XCTAssertEqual(left.height, right.height)
        let leftBytes = try bitmap(left)
        let rightBytes = try bitmap(right)
        let inside = sample(leftBytes, image: left, index: 0)
        let outside = sample(leftBytes, image: left, index: 1)
        let label = source.isText ? "text" : "shape"
        assertNear(inside, (r: 220, g: 30, b: 30), tolerance: 12, label: "\(label) \(background) 内格")
        let bg: UInt8 = background == .black ? 0 : 255
        assertNear(outside, (r: bg, g: bg, b: bg), tolerance: 8, label: "\(label) \(background) 形状外")
        assertNear(sample(rightBytes, image: right, index: 0), inside, tolerance: 8, label: "\(label) 再导出内格")
        assertNear(sample(rightBytes, image: right, index: 1), outside, tolerance: 8, label: "\(label) 再导出形状外")
    }

    private func export(_ layout: MosaicLayout, thumbs: RedSwatchThumbs) async throws -> URL {
        let request = ExportRequest(layout: layout, target: nil, tier: .hd)
        return try await LiveMosaicExporter(thumbnails: thumbs).export(request) { _ in }
    }

    private func sample(_ bytes: [UInt8], image: CGImage, index: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let cell = image.width / 2
        let x = index * cell + cell / 2
        let y = cell / 2
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

    private func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

private struct RedSwatchThumbs: ThumbnailProviding {
    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        guard assetID == "fixture" else { return .missing }
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = 220
            bytes[i + 1] = 30
            bytes[i + 2] = 30
        }
        return .image(try! PixelBuffer(width: 8, height: 8, bytes: bytes))
    }
}
