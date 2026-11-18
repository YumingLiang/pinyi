import XCTest
@testable import MosaicAppCore
import MosaicCore

/// S3：掩码从生成走到预览和导出计划。无形状时结果与原来一致。不测 CoreText，也不做选形状界面。
final class ShapeS3Tests: XCTestCase {
    func testNilMaskMatchesOmittedArgumentAndIgnoresBackground() async throws {
        let snap = try snapshot(count: 40)
        let target = try gradient(w: 80, h: 60)
        let runner = GenerationRunner()
        let settings = GenerationSettings(density: .coarse, overlayAlpha: 0.2)
        let plain = try await runner.run(target: target, snapshot: snap, settings: settings, seed: 3)
        let explicit = try await runner.run(target: target, snapshot: snap, settings: settings, seed: 3,
                                            activeCells: nil, shapeBackground: .black)
        XCTAssertNil(plain.generation.activeCells)
        XCTAssertNil(explicit.generation.activeCells)
        XCTAssertNil(plain.shapePlacement)
        XCTAssertEqual(plain.generation.assignment.tiles, explicit.generation.assignment.tiles)
        let preview = try PreviewRenderer.render(plain.generation, table: snap.library.table, cellPixels: 2)
        let previewWithIgnoredBackground = try PreviewRenderer.render(plain.generation, table: snap.library.table,
                                                                      cellPixels: 2, background: .black)
        XCTAssertEqual(preview.bytes, previewWithIgnoredBackground.bytes)
        let layout = MosaicLayout(product: plain, overlayAlpha: 0.2)
        XCTAssertEqual(layout.formatVersion, 1)
        XCTAssertNil(layout.shape)
        XCTAssertEqual(layout.params.overlayAlpha, 0.2)
        let json = String(data: try JSONEncoder().encode(layout), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"shape\""))
        let request = ExportRequest(product: plain, target: target, overlayAlpha: 0.2, tier: .share)
        XCTAssertEqual(request.overlayAlpha, 0.2)
    }

    func testRunnerKeepsOutsideCellsUnassignedAndReshuffleReusesMask() async throws {
        let snap = try snapshot(count: 80)
        let grid = try ShapeLayoutRules.preset(.circle, density: .coarse)
        let target = try ShapeTarget.render(mask: grid.mask, gradient: ShapePaletteBuilder.gradient(for: .blue, photoColors: []),
                                            background: .black)
        let runner = GenerationRunner()
        var product = try await runner.run(target: target, snapshot: snap, settings: GenerationSettings(density: .coarse, overlayAlpha: 0.25),
                                           seed: 11, activeCells: grid.mask, shapeBackground: .black)
        XCTAssertEqual(product.generation.activeCells, grid.mask)
        XCTAssertEqual(product.shapeBackground, .black)
        XCTAssertEqual(product.generation.assignment.statistics.cellCount, grid.mask.activeCount)
        for index in 0..<grid.mask.cellCount {
            let tile = product.generation.assignment.tiles[index]
            if grid.mask.isActive(index) {
                XCTAssertGreaterThanOrEqual(tile, 0)
                XCTAssertNotNil(product.cellAssetIDs[index])
            } else {
                XCTAssertEqual(tile, -1)
                XCTAssertNil(product.cellAssetIDs[index])
            }
        }
        let assigned = product.generation.assignment.tiles.filter { $0 >= 0 }.count
        XCTAssertEqual(assigned, grid.mask.activeCount, "形状外不占照片配额")

        let again = try await runner.reshuffle(product, target: target, settings: GenerationSettings(density: .coarse), seed: 99)
        XCTAssertEqual(again.generation.activeCells, grid.mask)
        XCTAssertEqual(again.shapeBackground, .black)
        for index in 0..<grid.mask.cellCount where !grid.mask.isActive(index) {
            XCTAssertEqual(again.generation.assignment.tiles[index], -1)
        }

        let preview = try PreviewRenderer.render(product.generation, table: snap.library.table, cellPixels: 2, background: .black)
        let sample = try XCTUnwrap((0..<grid.mask.cellCount).first { !grid.mask.isActive($0) })
        let col = sample % grid.layout.columns, row = sample / grid.layout.columns
        XCTAssertEqual(preview.rgb(x: col * 2, y: row * 2).r, 0)
        XCTAssertEqual(preview.rgb(x: col * 2, y: row * 2).g, 0)
        XCTAssertEqual(preview.rgb(x: col * 2, y: row * 2).b, 0)

        let tiles = product.generation.assignment.tiles
        product.setShapeBackground(.white)
        XCTAssertEqual(product.generation.assignment.tiles, tiles, "改背景不重新匹配")
        XCTAssertEqual(product.shapeBackground, .white)
        let layout = MosaicLayout(product: product, overlayAlpha: 0.25)
        XCTAssertEqual(layout.params.overlayAlpha, 0)
        XCTAssertEqual(layout.formatVersion, MosaicLayout.shapeFormatVersion)
        XCTAssertEqual(layout.shape?.background, .white)
        XCTAssertEqual(layout.shape?.mask, grid.mask)
        let back = try JSONDecoder().decode(MosaicLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(back.shape, layout.shape)
        XCTAssertEqual(back.formatVersion, 2)
        let forced = ExportRequest(layout: layout, target: target, overlayAlpha: 0.25, tier: .uhd)
        XCTAssertEqual(forced.overlayAlpha, 0)

        let photoFP = WorkFingerprint.of(MosaicLayout(product: try await runner.run(target: target, snapshot: snap,
                                                                                     settings: GenerationSettings(density: .coarse), seed: 1),
                                                      overlayAlpha: 0))
        XCTAssertEqual(photoFP.count, WorkFingerprint.prefix.count + 16)
    }

    func testStripPlanSkipsOutsideCellsAndKeepsPhotoOrder() throws {
        let columns = 4, rows = 6
        let plain = ShapeStripExport.steps(columns: columns, rows: rows, cellPixels: 256, shape: nil)
        XCTAssertEqual(plain.map(\.index), Array(0..<(columns * rows)))
        XCTAssertTrue(plain.allSatisfy(\.countsInFillStats))
        var mask = try CellMask(columns: columns, rows: rows, allActive: true)
        mask = try CellMask(columns: columns, rows: rows, bits: {
            var bits = BitMask(count: columns * rows, allSet: true)
            bits[0] = false
            bits[columns * rows - 1] = false
            return bits
        }())
        let shape = ShapePlacement(background: .black, mask: mask)
        let steps = ShapeStripExport.steps(columns: columns, rows: rows, cellPixels: 100, shape: shape)
        XCTAssertEqual(steps.map(\.index), Array(0..<(columns * rows)), "条带内仍是行优先，整表顺序不变")
        XCTAssertEqual(steps.filter { !$0.countsInFillStats }.map(\.index), [0, columns * rows - 1])
        XCTAssertEqual(steps[0].background, .black)
        XCTAssertEqual(steps.filter(\.countsInFillStats).count, mask.activeCount)
        let mismatched = ShapePlacement(background: .white, mask: try CellMask(columns: 2, rows: 2, allActive: false))
        let fallback = ShapeStripExport.steps(columns: columns, rows: rows, cellPixels: 10, shape: mismatched)
        XCTAssertTrue(fallback.allSatisfy(\.countsInFillStats), "掩码尺寸不对时不涂背景")
    }

    func testShapeBackgroundDoesNotChangePhotoFingerprint() throws {
        let cells = (0..<4).map { MosaicLayout.CellAssignment(localIdentifier: "p\($0)") }
        let photo = MosaicLayout(cols: 2, rows: 2, cellAssignments: cells,
                                 targetSize: .init(width: 32, height: 32),
                                 targetCrop: CropRect(x: 0, y: 0, width: 32, height: 32),
                                 params: .init(overlayAlpha: 0.1, density: "coarse", seed: 7))
        var other = photo
        other.params.overlayAlpha = 0.2
        XCTAssertEqual(WorkFingerprint.of(photo), WorkFingerprint.of(other))
        let mask = try CellMask(columns: 2, rows: 2, allActive: false)
        let shaped = MosaicLayout(cols: 2, rows: 2, cellAssignments: cells,
                                  targetSize: photo.targetSize, targetCrop: photo.targetCrop,
                                  params: photo.params, shape: ShapePlacement(background: .white, mask: mask))
        XCTAssertNotEqual(WorkFingerprint.of(photo), WorkFingerprint.of(shaped))
        let black = MosaicLayout(cols: 2, rows: 2, cellAssignments: cells,
                                 targetSize: photo.targetSize, targetCrop: photo.targetCrop,
                                 params: .init(overlayAlpha: 0, density: "coarse", seed: 7),
                                 shape: ShapePlacement(background: .black, mask: mask))
        XCTAssertNotEqual(WorkFingerprint.of(shaped), WorkFingerprint.of(black))
    }

    private func gradient(w: Int, h: Int) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                bytes[o] = UInt8(x * 255 / max(w - 1, 1))
                bytes[o + 1] = UInt8(y * 255 / max(h - 1, 1))
                bytes[o + 2] = 40
            }
        }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }

    private func snapshot(count: Int) throws -> IndexSnapshot {
        let records = (0..<count).map { i -> FeatureRecord in
            let l = Float(i % 20) / 20
            return FeatureRecord(vector: FeatureVector(uniform: SIMD3(l, 0.02, -0.01)), lightnessVariance: 0.02, aspectRatio: 1)
        }
        let library = try LibrarySnapshot(table: FeatureTable(records: records))
        return IndexSnapshot(library: library, assetIDsByRow: (0..<count).map { "a\($0)" })
    }
}
