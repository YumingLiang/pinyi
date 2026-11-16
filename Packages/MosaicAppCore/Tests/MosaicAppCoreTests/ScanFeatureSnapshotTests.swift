import MosaicCore
import XCTest
@testable import MosaicAppCore

/// 扫描建索引路径的特征快照：非正方形源按 14ac550 的 `opaqueSRGB(maxEdge: 128)` 几何缩小后再提取。
/// 先裁成正方形再缩小会得到不同特征，不能与已建索引混用。
final class ScanFeatureSnapshotTests: XCTestCase {
    /// 14ac550 快照：`SyntheticImage(index: 0, 256×341)` → 长边缩到 128（96×128）→ `FeatureExtractor`。
    /// 分量用 bitPattern 锁定，保证与记录时逐 bit 相同。
    static let snapshotBits: [UInt32] = [
        1_044_246_420, 1_016_134_264, 1_002_940_672, 1_049_320_243,
        3_143_268_480, 1_022_312_624, 1_046_694_776, 3_169_060_436,
        1_022_079_872, 1_049_446_590, 3_176_122_742, 1_021_522_064,
    ]
    static let snapshotVarianceBits: UInt32 = 985_776_403

    func testScanPathKeepsPrefFixGeometryAndFeatureVersion2() throws {
        XCTAssertEqual(MosaicCoreInfo.featureVersion, 2)
        XCTAssertEqual(FeatureSpec.current.featureVersion, 2)
        XCTAssertEqual(ThumbnailRequest.scan.targetPixelSize, 128)
        XCTAssertFalse(ThumbnailRequest.scan.centerCropToSquare, "扫描建索引不能先裁方")
        XCTAssertTrue(ThumbnailRequest.scanDisplay.centerCropToSquare)

        let src = SyntheticImage.make(index: 0, width: 256, height: 341)
        XCTAssertEqual(src.width, 256)
        XCTAssertEqual(src.height, 341)

        let size = ScanThumbnailGeometry.size(width: src.width, height: src.height)
        XCTAssertEqual(size.width, 96)
        XCTAssertEqual(size.height, 128)
        XCTAssertNotEqual(size.width, size.height, "14ac550 扫描结果保持宽高比，不是正方形")

        let thumb = Self.scaledToMaxEdge(src, maxEdge: ScanThumbnailGeometry.targetPixelSize)
        XCTAssertEqual(thumb.width, 96)
        XCTAssertEqual(thumb.height, 128)
        XCTAssertEqual(thumb.centerSquare, PixelRegion(x: 0, y: 16, width: 96, height: 96))

        let rec = try FeatureExtractor().extract(from: thumb)
        XCTAssertEqual(rec.vector.components.map(\.bitPattern), Self.snapshotBits)
        XCTAssertEqual(rec.lightnessVariance.bitPattern, Self.snapshotVarianceBits)
        XCTAssertEqual(rec.aspectRatio, 0.75)
        XCTAssertEqual(rec.flags, [])
    }

    func testCenterCropFirstDoesNotMatchScanSnapshot() throws {
        let src = SyntheticImage.make(index: 0, width: 256, height: 341)
        let crop = CenterSquareCrop.rect(width: src.width, height: src.height)
        XCTAssertEqual(crop.x, 0)
        XCTAssertEqual(crop.y, 42)
        XCTAssertEqual(crop.size, 256)
        // 先裁 256×256 再缩到 128×128，与扫描的 96×128 不同，特征必须不同。
        let square = Self.crop(src, crop)
        let thumb = Self.scaledToMaxEdge(square, maxEdge: 128)
        XCTAssertEqual(thumb.width, 128)
        XCTAssertEqual(thumb.height, 128)
        let rec = try FeatureExtractor().extract(from: thumb)
        XCTAssertNotEqual(rec.vector.components.map(\.bitPattern), Self.snapshotBits)
    }

    /// 与 `ImagePixels.opaqueSRGB(maxEdge:)` 相同的尺寸规则，像素用中心最近邻（Linux 可复现）。
    private static func scaledToMaxEdge(_ buffer: PixelBuffer, maxEdge: Int) -> PixelBuffer {
        let out = ScanThumbnailGeometry.size(width: buffer.width, height: buffer.height, maxEdge: maxEdge)
        if out.width == buffer.width && out.height == buffer.height { return buffer }
        var bytes = [UInt8](repeating: 255, count: out.width * out.height * 4)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let sx = min(buffer.width - 1, Int((Double(x) + 0.5) * Double(buffer.width) / Double(out.width)))
                let sy = min(buffer.height - 1, Int((Double(y) + 0.5) * Double(buffer.height) / Double(out.height)))
                let p = buffer.rgb(x: sx, y: sy)
                let o = (y * out.width + x) * 4
                bytes[o] = p.r; bytes[o + 1] = p.g; bytes[o + 2] = p.b
            }
        }
        return try! PixelBuffer(width: out.width, height: out.height, bytes: bytes)
    }

    private static func crop(_ buffer: PixelBuffer, _ r: (x: Int, y: Int, size: Int)) -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: r.size * r.size * 4)
        for y in 0..<r.size {
            for x in 0..<r.size {
                let p = buffer.rgb(x: r.x + x, y: r.y + y)
                let o = (y * r.size + x) * 4
                bytes[o] = p.r; bytes[o + 1] = p.g; bytes[o + 2] = p.b
            }
        }
        return try! PixelBuffer(width: r.size, height: r.size, bytes: bytes)
    }
}
