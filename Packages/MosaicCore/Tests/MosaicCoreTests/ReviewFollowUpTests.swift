import Foundation
import XCTest
@testable import MosaicCore

/// 架构师评审（M3、S1–S6）与 QA 复验（A-04、A-12、A-19、A-20、缺陷 9）的补充测试。
final class ReviewFollowUpTests: XCTestCase {
    // MARK: M3 / T4 相对尺度

    /// T4：库特征与格特征整体乘以常数（2 的幂，浮点精确），分配结果逐格不变。
    func testM3ScaleInvarianceOfRelativePenalty() throws {
        let grid = try MosaicGrid(columns: 24, rows: 18)
        let lib = syntheticVectors(count: 300, seed: 41)      // 300 < 2×432 → cap = 3，λ 真正起作用
        let cells = syntheticVectors(count: grid.cellCount, seed: 42)
        func scaled(_ v: [FeatureVector], _ c: Float) -> FeatureMatrix {
            FeatureMatrix(vectors: v.map { FeatureVector($0.components.map { $0 * c }) })
        }
        let config = AssignmentConfiguration(seed: 3)
        let base = try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: scaled(cells, 1), library: scaled(lib, 1))
        XCTAssertGreaterThan(base.statistics.maxUses, 1)
        for c: Float in [4, 0.25, 64] {
            let s = try GreedyAssigner(configuration: config).assign(grid: grid, cellFeatures: scaled(cells, c), library: scaled(lib, c))
            XCTAssertEqual(s.tiles, base.tiles, "scale \(c)")
            XCTAssertEqual(s.statistics.effectiveUsagePenalty, base.statistics.effectiveUsagePenalty * c * c,
                           accuracy: base.statistics.effectiveUsagePenalty * c * c * 1e-5)
        }
        // 绝对 λ 不具备尺度不变性（说明为什么要改）。
        let abs = config.withAbsolutePenalties(usage: 0.005, lowDetail: 0)
        let a1 = try GreedyAssigner(configuration: abs).assign(grid: grid, cellFeatures: scaled(cells, 1), library: scaled(lib, 1))
        let a64 = try GreedyAssigner(configuration: abs).assign(grid: grid, cellFeatures: scaled(cells, 64), library: scaled(lib, 64))
        XCTAssertNotEqual(a1.tiles, a64.tiles)
    }

    func testM3LambdaIsAlphaTimesTop1Median() throws {
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let cells = FeatureMatrix(vectors: syntheticVectors(count: 100, seed: 1))
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 500, seed: 2))
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: lib)
        let top1 = try ScalarSIMDKernel().topK(queries: cells, candidates: lib, k: 1)
        let sorted = top1.distances.sorted()
        XCTAssertEqual(a.statistics.top1MedianDistance, sorted[(sorted.count - 1) / 2])
        XCTAssertEqual(a.statistics.effectiveUsagePenalty, 0.1 * a.statistics.top1MedianDistance, accuracy: 1e-9)
        var c = AssignmentConfiguration(); c.usagePenaltyRelative = -1
        XCTAssertThrowsError(try c.validate())
    }

    /// M1：整张同色 + cap 1 时"忽略上限"按最小超额均摊，而不是集中在少数几张；仍保证 4 邻域不重复。
    func testM1CapIgnoredSpreadsOverflowEvenly() throws {
        let grid = try MosaicGrid(columns: 30, rows: 20)   // 600 格
        let cells = FeatureMatrix(vectors: Array(repeating: FeatureVector(uniform: SIMD3(0.6, 0.02, 0.05)), count: 600))
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 3000, seed: 5))
        var c = AssignmentConfiguration(seed: 1, batchDepths: [100], exhaustiveCellLimit: 0)
        c.cap = .limited(1)
        let a = try GreedyAssigner(configuration: c).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertGreaterThan(a.statistics.capIgnoredCount, 0)
        XCTAssertLessThanOrEqual(a.statistics.maxUses, 600 / 100 + 1)
        XCTAssertEqual(neighborhoodViolations(a, .four), 0)
        // 逐格扩展上限为 0 时（全部直接进入批量加深）结果仍合法、可复现。
        var d = AssignmentConfiguration(seed: 1); d.cap = .limited(1); d.perCellExpansionLimit = 0
        let b = try GreedyAssigner(configuration: d).assign(grid: grid, cellFeatures: cells, library: lib)
        XCTAssertEqual(b.statistics.count(at: .expandedCandidates), 0)
        XCTAssertFalse(b.statistics.relaxedConstraints)
        XCTAssertEqual(try GreedyAssigner(configuration: d).assign(grid: grid, cellFeatures: cells, library: lib), b)
    }

    // MARK: 缺陷 9 / 决定 v0.3：shortage.result 显示条件

    func testShortageNoticeTruthTable() throws {
        // (可用 < 200, 实际放宽) → 是否显示
        for (below, relaxed, show) in [(false, false, false), (false, true, false), (true, false, false), (true, true, true)] {
            XCTAssertEqual(ShortageHint.shouldShow(isBelowMaterialThreshold: below, relaxedConstraints: relaxed), show, "\(below) \(relaxed)")
        }
        XCTAssertTrue(ShortageHint.shouldShow(availableCount: 199, neighborhoodRelaxedCount: 1, capIgnoredCount: 0))
        XCTAssertTrue(ShortageHint.shouldShow(availableCount: 10, neighborhoodRelaxedCount: 0, capIgnoredCount: 3))
        XCTAssertFalse(ShortageHint.shouldShow(availableCount: 200, neighborhoodRelaxedCount: 5, capIgnoredCount: 5))
        XCTAssertFalse(ShortageHint.shouldShow(availableCount: 50, neighborhoodRelaxedCount: 0, capIgnoredCount: 0))

        // 端到端四种情况。
        let grid = try MosaicGrid(columns: 10, rows: 10)
        let cells = FeatureMatrix(vectors: syntheticVectors(count: 100, seed: 2))
        let uniformCells = FeatureMatrix(vectors: Array(repeating: FeatureVector(uniform: SIMD3(0.5, 0, 0)), count: 100))
        // 充足 + 不放宽
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: FeatureMatrix(vectors: syntheticVectors(count: 400, seed: 3)))
        XCTAssertFalse(a.statistics.relaxedConstraints); XCTAssertFalse(a.statistics.shouldShowShortageNotice)
        // 不足（3 张）+ 放宽
        let b = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: FeatureMatrix(vectors: syntheticVectors(count: 3, seed: 4)))
        XCTAssertTrue(b.statistics.relaxedConstraints); XCTAssertTrue(b.statistics.shouldShowShortageNotice)
        XCTAssertGreaterThan(b.statistics.neighborhoodRelaxedCount, 0)
        XCTAssertGreaterThan(b.statistics.capIgnoredCount, 0)
        // 不足（150 张）但不放宽
        let c = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, library: FeatureMatrix(vectors: syntheticVectors(count: 150, seed: 5)))
        XCTAssertTrue(c.statistics.isBelowMaterialThreshold); XCTAssertFalse(c.statistics.relaxedConstraints)
        XCTAssertFalse(c.statistics.shouldShowShortageNotice)
        // 充足（250 张）但颜色集中、cap = 1、禁用加深 → 放宽但不显示
        var cfg = AssignmentConfiguration(cap: .limited(1), batchDepths: [], exhaustiveCellLimit: 0); cfg.k = 4; cfg.fallbackK = 4
        let d = try GreedyAssigner(configuration: cfg).assign(grid: grid, cellFeatures: uniformCells,
                                                              library: FeatureMatrix(vectors: syntheticVectors(count: 250, seed: 6)))
        XCTAssertTrue(d.statistics.relaxedConstraints); XCTAssertFalse(d.statistics.isBelowMaterialThreshold)
        XCTAssertFalse(d.statistics.shouldShowShortageNotice)
        XCTAssertEqual(d.statistics.relaxationCount, d.statistics.neighborhoodRelaxedCount)
    }

    // MARK: A-12 全 1 掩码 ≡ 无掩码

    func testA12AllOnesMaskEqualsNoMask() throws {
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 700, seed: 7))
        let grid = try MosaicGrid(columns: 15, rows: 10)
        let cells = FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: 8))
        let ones = BitMask(count: 700, allSet: true)
        let k = ScalarSIMDKernel()
        XCTAssertEqual(try k.topK(queries: cells, candidates: lib, k: 32, mask: ones), try k.topK(queries: cells, candidates: lib, k: 32))
        let g = GreedyAssigner(configuration: AssignmentConfiguration(seed: 4))
        XCTAssertEqual(try g.assign(grid: grid, cellFeatures: cells, library: lib, mask: ones),
                       try g.assign(grid: grid, cellFeatures: cells, library: lib))
    }

    // MARK: A-04 Display P3

    func testA04DisplayP3MatrixDerivedFromPrimaries() {
        let m = DisplayP3.toLinearSRGBMatrix
        let expected: [Double] = [1.2249, -0.2249, 0, -0.0421, 1.0421, 0, -0.0196, -0.0786, 1.0983]
        for i in 0..<9 { XCTAssertEqual(m[i], expected[i], accuracy: 1e-4, "m[\(i)]") }
        // 白点保持：每行和 = 1。
        for r in 0..<3 { XCTAssertEqual(m[r * 3] + m[r * 3 + 1] + m[r * 3 + 2], 1, accuracy: 1e-12) }
    }

    func testA04P3BufferIsConvertedBeforeFeatures() throws {
        // 同样的字节，标 P3 与标 sRGB 得到不同特征；P3 特征 = 先手动转 sRGB 再提取。
        let bytes: [UInt8] = Array(repeating: [200, 100, 50, 255], count: 16).flatMap { $0 }
        let asSRGB = try PixelBuffer(width: 4, height: 4, bytes: bytes)
        let asP3 = try PixelBuffer(width: 4, height: 4, colorSpace: .displayP3, bytes: bytes)
        let ex = FeatureExtractor()
        let fs = try ex.extract(from: asSRGB), fp = try ex.extract(from: asP3)
        XCTAssertNotEqual(fs.vector, fp.vector)
        let lin = DisplayP3.toLinearSRGB(LinearRGB(srgb8Red: 200, green: 100, blue: 50))
        let expected = OKLab(lin).simd
        for i in 0..<4 {
            XCTAssertEqual(fp.vector.block(i).x, expected.x, accuracy: 1e-5)
            XCTAssertEqual(fp.vector.block(i).y, expected.y, accuracy: 1e-5)
            XCTAssertEqual(fp.vector.block(i).z, expected.z, accuracy: 1e-5)
        }
        // P3 更"饱和"：同字节的 P3 红在 sRGB 里 a* 更大。
        XCTAssertGreaterThan(fp.vector.block(0).y, fs.vector.block(0).y)
        // sRGB 缓冲区不会被二次转换。
        XCTAssertEqual(asSRGB.convertedToSRGB().bytes, asSRGB.bytes)
        XCTAssertEqual(try ex.extract(from: asSRGB.convertedToSRGB()), fs)
        // P3 → sRGB 字节转换后按 sRGB 提取，与直接提取 P3 一致（8 位量化误差内）。
        let conv = asP3.convertedToSRGB()
        XCTAssertEqual(conv.colorSpace, .sRGB)
        XCTAssertEqual(try ex.extract(from: conv).vector.block(0).x, fp.vector.block(0).x, accuracy: 3e-3)
        // 中性灰在两个空间中相同。
        let gray: [UInt8] = Array(repeating: [128, 128, 128, 255], count: 4).flatMap { $0 }
        XCTAssertEqual(try ex.extract(from: PixelBuffer(width: 2, height: 2, colorSpace: .displayP3, bytes: gray)).vector.block(0).x,
                       try ex.extract(from: PixelBuffer(width: 2, height: 2, bytes: gray)).vector.block(0).x, accuracy: 1e-5)
    }

    // MARK: A-19 原图叠加

    func testA19OverlayAlphaFormula() throws {
        XCTAssertEqual(OverlayBlend.blend(tile: 200, target: 100, alpha: 0), 200)        // α=0 等于块像素
        XCTAssertEqual(OverlayBlend.blend(tile: 200, target: 100, alpha: 0.15), 185)     // 0.85·200 + 0.15·100
        XCTAssertEqual(OverlayBlend.blend(tile: 200, target: 100, alpha: 0.3), 170)      // 0.7·200 + 0.3·100
        XCTAssertEqual(OverlayBlend.blend(tile: 0, target: 255, alpha: 0.3), 77)         // 76.5 → 77（四舍五入）
        XCTAssertEqual(OverlayBlend.blend(tile: 10, target: 250, alpha: 0.9), OverlayBlend.blend(tile: 10, target: 250, alpha: 0.3)) // 钳到 0.3
        XCTAssertEqual(OverlayBlend.blend(tile: 10, target: 250, alpha: -1), 10)
        XCTAssertEqual(OverlayBlend.blend(tile: 10, target: 250, alpha: .nan), 10)
        XCTAssertEqual(OverlayBlend.clampAlpha(0.2), 0.2)
        for t in stride(from: 0, through: 255, by: 15) {
            for g in stride(from: 0, through: 255, by: 15) {
                for a: Float in [0, 0.1, 0.15, 0.3] {
                    let expect = UInt8(((1 - a) * Float(t) + a * Float(g)).rounded())
                    XCTAssertEqual(OverlayBlend.blend(tile: UInt8(t), target: UInt8(g), alpha: a), expect)
                }
            }
        }
        let tile = try PixelBuffer.solid(width: 3, height: 2, red: 200, green: 0, blue: 50)
        let tgt = try PixelBuffer.solid(width: 3, height: 2, red: 100, green: 255, blue: 50)
        let out = try OverlayBlend.blend(tile: tile, target: tgt, alpha: 0.3)
        XCTAssertTrue(out.rgb(x: 2, y: 1) == (170, 77, 50))
        XCTAssertThrowsError(try OverlayBlend.blend(tile: tile, target: PixelBuffer.solid(width: 2, height: 2, red: 0, green: 0, blue: 0), alpha: 0.1))
    }

    // MARK: A-20 导出条带

    func testA20ExportStripsCoverWithoutOverlap() throws {
        for (w, h) in [(4032, 3024), (3024, 4032), (2000, 2000), (3000, 50)] {
            for d in [Density.coarse, .medium, .fine] {
                let g = try Layout.grid(width: w, height: h, density: d)
                for nominal in [4000, 6000] {
                    let size = g.exportSize(longEdge: nominal)
                    for policy in [ExportStripPolicy.default, .cellRows(1), .cellRows(7)] {
                        let strips = g.exportStrips(longEdge: nominal, policy: policy)
                        // 并集覆盖全部格子行与像素行，按序首尾相接、不重叠。
                        XCTAssertEqual(strips.first?.rows.lowerBound, 0)
                        XCTAssertEqual(strips.last?.rows.upperBound, g.rows)
                        XCTAssertEqual(strips.last?.pixelRows.upperBound, size.height)
                        for (a, b) in zip(strips, strips.dropFirst()) {
                            XCTAssertEqual(a.rows.upperBound, b.rows.lowerBound)
                            XCTAssertEqual(a.pixelRows.upperBound, b.pixelRows.lowerBound)
                        }
                        XCTAssertEqual(strips.map(\.pixelHeight).reduce(0, +), size.height)
                        for s in strips {
                            XCTAssertEqual(s.pixelHeight, s.rows.count * size.cellPixels)
                            switch policy {
                            case .maxPixelHeight(let px):
                                // 条带高度：≤ 512 px 的整行；格子本身 > 512 px 时退化为 1 行格子高度。
                                XCTAssertTrue(s.pixelHeight <= px || s.rows.count == 1)
                            case .cellRows(let n):
                                XCTAssertLessThanOrEqual(s.rows.count, n)
                            }
                        }
                    }
                }
            }
        }
        // 具体值：4032×3024 中档 4000 → 50 px/格、60 行，512 px → 每条 10 行 = 500 px，共 6 条。
        let s = try Layout.grid(width: 4032, height: 3024, density: .medium).exportStrips(longEdge: 4000)
        XCTAssertEqual(s.count, 6)
        XCTAssertEqual(s[0].pixelRows, 0..<500)
        XCTAssertEqual(s[5].rows, 50..<60)
    }

    // MARK: S1 / S3

    func testS1SinglePassVarianceMatchesTwoPassReference() throws {
        var rng = Xoshiro256StarStar(seed: 99)
        for (w, h) in [(32, 32), (7, 5), (1, 9), (1, 1), (33, 17)] {
            let bytes = (0..<(w * h * 4)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let buf = try PixelBuffer(width: w, height: h, bytes: bytes)
            let r = buf.fullRegion
            let rec = try FeatureExtractor().extract(from: buf, region: r)
            var s = 0.0, sq = 0.0
            for y in 0..<h { for x in 0..<w {
                let l = Double(OKLab(buf.linearSRGB(x: x, y: y)).L); s += l; sq += l * l
            } }
            let mean = s / Double(w * h)
            XCTAssertEqual(Double(rec.lightnessVariance), max(0, sq / Double(w * h) - mean * mean), accuracy: 1e-6, "\(w)x\(h)")
        }
    }

    func testS3PortableCbrt() {
        var rng = Xoshiro256StarStar(seed: 5)
        for _ in 0..<20_000 {
            let x = Double(rng.nextUnitFloat()) * pow(10, Double(Int(rng.next() % 12)) - 6)
            let c = PortableMath.cbrt(x)
            XCTAssertEqual(c, Foundation.cbrt(x), accuracy: max(1e-300, abs(Foundation.cbrt(x)) * 1e-15))
        }
        for x in [0.0, 1, 8, 27, 1e-30, 1e30, 0.001, 2] {
            XCTAssertEqual(PortableMath.cbrt(x), Foundation.cbrt(x), accuracy: Foundation.cbrt(x) * 1e-15)
        }
        XCTAssertEqual(PortableMath.cbrt(-8.0), -2, accuracy: 1e-15)
        XCTAssertEqual(PortableMath.cbrt(Float(0.125)), 0.5)
    }

    // MARK: S2 / S4 / S6

    /// A-16 前提：并行取样与串行逐位一致。
    func testS2ParallelSamplerEqualsSerial() throws {
        let img = try gradientImage(width: 403, height: 301)
        let layout = try Layout.grid(width: 403, height: 301, density: .medium)
        let par = try TargetSampler().cellFeatures(of: img, layout: layout)
        let ser = try (0..<layout.cellCount).map { try FeatureExtractor().extract(from: img, region: layout.cellPixelRegion($0)) }
        XCTAssertEqual(par, ser)
    }

    func testS4FeatureSpecMismatchThrows() throws {
        let img = try gradientImage(width: 64, height: 48)
        let recs = syntheticVectors(count: 300, seed: 1).map { FeatureRecord(vector: $0) }
        let cielab = FeatureTable(records: recs, spec: FeatureSpec(colorSpace: .cielab))
        XCTAssertThrowsError(try MosaicPipeline().generate(target: img, density: .custom(columns: 8), table: cielab)) { e in
            XCTAssertEqual(e as? MosaicError, .featureSpecMismatch(library: cielab.spec, target: .current))
        }
        let perceptual = FeatureTable(records: recs, spec: FeatureSpec(averaging: .perceptual))
        XCTAssertThrowsError(try MosaicPipeline().generate(target: img, density: .custom(columns: 8), table: perceptual))
        XCTAssertNoThrow(try MosaicPipeline().generate(target: img, density: .custom(columns: 8), table: FeatureTable(records: recs)))
        // 取样器与素材同为 CIELAB 时允许。
        let p = MosaicPipeline(sampler: TargetSampler(extractor: FeatureExtractor(colorSpace: .cielab)))
        XCTAssertNoThrow(try p.generate(target: img, density: .custom(columns: 8), table: cielab))
    }

    /// T3：快照外的行（未扫描或已删除或来源外）永远不会被选中；cap 与供给判断按快照张数。
    func testS6SnapshotRestrictsRowsAndDrivesCapAndSupply() throws {
        var table = FeatureTable(records: syntheticVectors(count: 1000, seed: 11).map { FeatureRecord(vector: $0, lightnessVariance: 0.01) })
        for i in stride(from: 0, to: 1000, by: 10) { table.markDeleted(i) }
        let source = BitMask(count: 1000, setIndices: 0..<900)
        let snap = try LibrarySnapshot(table: table, rowLimit: 300, sourceMask: source)   // 已扫描 300 行
        XCTAssertEqual(snap.availableCount, 270)
        XCTAssertEqual(snap.supply, .sufficient)
        let img = try gradientImage(width: 120, height: 90)
        let gen = try MosaicPipeline().generate(target: img, density: .custom(columns: 20), snapshot: snap, seed: 1)
        XCTAssertTrue(gen.assignment.tiles.allSatisfy { $0 < 300 && $0 % 10 != 0 })
        XCTAssertEqual(gen.assignment.statistics.availableCandidates, 270)
        XCTAssertEqual(gen.assignment.statistics.resolvedCap, Int((Double(gen.layout.cellCount) / 270 * 2).rounded(.up)))
        XCTAssertEqual(gen.supply, .sufficient)
        let small = try LibrarySnapshot(table: table, rowLimit: 100)
        XCTAssertEqual(small.availableCount, 90)
        XCTAssertEqual(small.supply, .insufficient(available: 90))
        XCTAssertEqual(try MosaicPipeline().generate(target: img, density: .custom(columns: 20), snapshot: small).supply,
                       .insufficient(available: 90))
        XCTAssertThrowsError(try LibrarySnapshot(table: table, sourceMask: BitMask(count: 5)))
    }
}
