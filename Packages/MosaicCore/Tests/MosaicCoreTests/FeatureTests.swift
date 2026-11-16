import XCTest
@testable import MosaicCore

final class FeatureTests: XCTestCase {
    func testPixelBufferValidation() {
        XCTAssertThrowsError(try PixelBuffer(width: 0, height: 4, bytes: []))
        XCTAssertThrowsError(try PixelBuffer(width: 2, height: 2, bytes: [UInt8](repeating: 0, count: 15)))
        XCTAssertThrowsError(try PixelBuffer(width: 2, height: 2, bytesPerRow: 7, bytes: [UInt8](repeating: 0, count: 64)))
        XCTAssertNoThrow(try PixelBuffer(width: 2, height: 2, bytesPerRow: 12, bytes: [UInt8](repeating: 0, count: 20)))
    }

    func testBGRALayout() throws {
        let buf = try PixelBuffer(width: 1, height: 1, layout: .bgra8, bytes: [10, 20, 30, 255])
        let p = buf.rgb(x: 0, y: 0)
        XCTAssertEqual(p.r, 30)
        XCTAssertEqual(p.g, 20)
        XCTAssertEqual(p.b, 10)
    }

    func testUniformImageGivesFourEqualBlocks() throws {
        let buf = try PixelBuffer.solid(width: 32, height: 32, red: 200, green: 100, blue: 50)
        let rec = try FeatureExtractor().extract(from: buf)
        let expected = OKLab(LinearRGB(srgb8Red: 200, green: 100, blue: 50)).simd
        for i in 0..<4 {
            let blk = rec.vector.block(i)
            XCTAssertEqual(blk.x, expected.x, accuracy: 1e-5)
            XCTAssertEqual(blk.y, expected.y, accuracy: 1e-5)
            XCTAssertEqual(blk.z, expected.z, accuracy: 1e-5)
        }
        XCTAssertEqual(rec.lightnessVariance, 0, accuracy: 1e-6)
        XCTAssertTrue(rec.flags.contains(.lowDetail))
        XCTAssertEqual(rec.aspectRatio, 1)
    }

    /// 四个象限不同颜色 → 对应块（TL, TR, BL, BR）。
    func testQuadrantsMapToBlocksInOrder() throws {
        let w = 8, h = 8
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let q = (y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)
                let o = (y * w + x) * 4
                bytes[o] = colors[q].0
                bytes[o + 1] = colors[q].1
                bytes[o + 2] = colors[q].2
            }
        }
        let buf = try PixelBuffer(width: w, height: h, bytes: bytes)
        let rec = try FeatureExtractor().extract(from: buf)
        for q in 0..<4 {
            let e = OKLab(LinearRGB(srgb8Red: colors[q].0, green: colors[q].1, blue: colors[q].2)).simd
            XCTAssertEqual(rec.vector.block(q).x, e.x, accuracy: 1e-5, "block \(q)")
            XCTAssertEqual(rec.vector.block(q).y, e.y, accuracy: 1e-5, "block \(q)")
            XCTAssertEqual(rec.vector.block(q).z, e.z, accuracy: 1e-5, "block \(q)")
        }
        XCTAssertGreaterThan(rec.lightnessVariance, 0.01)
        XCTAssertFalse(rec.flags.contains(.lowDetail))
    }

    /// 黑白各半：线性光平均 ≠ 感知空间平均。
    func testLinearLightVersusPerceptualAveraging() throws {
        // 4×4 黑白棋盘：每个 2×2 子块含 2 黑 2 白。
        var big = [UInt8](repeating: 255, count: 4 * 4 * 4)
        for y in 0..<4 { for x in 0..<4 where (x + y) % 2 == 0 { let o = (y * 4 + x) * 4; big[o] = 0; big[o + 1] = 0; big[o + 2] = 0 } }
        let buf = try PixelBuffer(width: 4, height: 4, bytes: big)
        let lin = try FeatureExtractor(averaging: .linearLight).extract(from: buf)
        let per = try FeatureExtractor(averaging: .perceptual).extract(from: buf)
        // 线性光平均 = 50% 线性灰 → OKLab L = cbrt(0.5) ≈ 0.7937；感知平均 = (0 + 1) / 2 = 0.5。
        XCTAssertClose(lin.vector.block(0).x, 0.7937005259840998, accuracy: 1e-4)
        XCTAssertClose(per.vector.block(0).x, 0.5, accuracy: 1e-4)
    }

    func testCenterSquareCropOnLandscapeImage() throws {
        // 12×4：左 4 列红、中 4 列绿、右 4 列蓝 → 中心正方形只含绿色。
        let w = 12, h = 4
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                bytes[o] = x < 4 ? 255 : 0
                bytes[o + 1] = (x >= 4 && x < 8) ? 255 : 0
                bytes[o + 2] = x >= 8 ? 255 : 0
            }
        }
        let buf = try PixelBuffer(width: w, height: h, bytes: bytes)
        XCTAssertEqual(buf.centerSquare, PixelRegion(x: 4, y: 0, width: 4, height: 4))
        let rec = try FeatureExtractor().extract(from: buf)
        let green = OKLab(srgbRed: 0, green: 1, blue: 0).simd
        for i in 0..<4 { XCTAssertEqual(rec.vector.block(i).x, green.x, accuracy: 1e-5) }
        XCTAssertEqual(rec.aspectRatio, 3)
    }

    func testOddAndTinyRegions() throws {
        let one = try PixelBuffer.solid(width: 1, height: 1, red: 10, green: 20, blue: 30)
        let rec = try FeatureExtractor().extract(from: one)
        XCTAssertEqual(rec.vector.block(0), rec.vector.block(3))
        let odd = try PixelBuffer.solid(width: 5, height: 3, red: 10, green: 20, blue: 30)
        XCTAssertNoThrow(try FeatureExtractor().extract(from: odd))
        XCTAssertThrowsError(try FeatureExtractor().extract(from: odd, region: PixelRegion(x: 4, y: 0, width: 2, height: 1)))
        XCTAssertThrowsError(try FeatureExtractor().extract(from: odd, region: PixelRegion(x: 0, y: 0, width: 0, height: 1)))
    }

    func testSpanPartitionCoversLength() {
        for length in 1...20 {
            for parts in 1...6 {
                var covered = 0
                for i in 0..<parts {
                    let s = FeatureExtractor.span(index: i, parts: parts, length: length)
                    XCTAssertFalse(s.isEmpty)
                    XCTAssertTrue(s.lowerBound >= 0 && s.upperBound <= length)
                    if parts <= length { covered += s.count }
                }
                if parts <= length { XCTAssertEqual(covered, length) }
            }
        }
    }

    func testFeatureVectorBasics() {
        let v = FeatureVector((0..<12).map(Float.init))
        XCTAssertEqual(v.components, (0..<12).map(Float.init))
        XCTAssertEqual(v.block(1), SIMD3(3, 4, 5))
        XCTAssertEqual(v.meanColor, SIMD3(4.5, 5.5, 6.5))
        XCTAssertEqual(v.storage[12], 0)
        XCTAssertEqual(v.squaredDistance(to: FeatureVector()), (0..<12).reduce(Float(0)) { $0 + Float($1 * $1) })
    }

    func testFeatureMatrixSoALayout() throws {
        let vs = syntheticVectors(count: 5, seed: 1)
        let m = FeatureMatrix(vectors: vs)
        XCTAssertEqual(m.count, 5)
        XCTAssertEqual(m.storage.count, 60)
        for i in 0..<5 {
            XCTAssertEqual(m.row(i), vs[i].components)
            for d in 0..<12 { XCTAssertEqual(m.storage[d * 5 + i], vs[i][d]) }
        }
        let fromRows = try FeatureMatrix(dimension: 12, rows: vs.map(\.components))
        XCTAssertEqual(fromRows, m)
        XCTAssertEqual(m.subset(3).storage, vs[3].components)
        XCTAssertThrowsError(try FeatureMatrix(dimension: 12, count: 2, soa: [0]))
        XCTAssertThrowsError(try FeatureMatrix(dimension: 12, rows: [[1, 2]]))
        XCTAssertEqual(FeatureMatrix(vectors: []).count, 0)
    }

    func testTargetSamplerGrid() throws {
        let buf = try PixelBuffer.solid(width: 400, height: 300, red: 50, green: 60, blue: 70)
        let layout = try Layout.grid(width: 400, height: 300, density: .coarse)
        XCTAssertEqual(layout.columns, 40)
        XCTAssertEqual(layout.rows, 30)
        let cells = try TargetSampler().cellFeatures(of: buf, layout: layout)
        XCTAssertEqual(cells.count, 1200)
        XCTAssertEqual(cells[0].vector, cells[1199].vector)
        XCTAssertEqual(try MosaicGrid(density: .medium, imageWidth: 4, imageHeight: 3).cellCount, 4800)
        XCTAssertEqual(try MosaicGrid(density: .fine, imageWidth: 4, imageHeight: 3).cellCount, 10800)
        XCTAssertThrowsError(try TargetSampler().cellFeatures(of: buf, layout: Layout.grid(width: 401, height: 300, density: .coarse)))
    }
}
