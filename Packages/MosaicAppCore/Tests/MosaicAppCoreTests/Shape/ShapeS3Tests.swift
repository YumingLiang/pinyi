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
        XCTAssertNil(plain.shapeFrame)
        XCTAssertEqual(plain.generation.assignment.tiles, explicit.generation.assignment.tiles)
        let preview = try PreviewRenderer.render(plain.generation, table: snap.library.table, cellPixels: 2)
        let previewWithIgnoredBackground = try PreviewRenderer.render(plain.generation, table: snap.library.table,
                                                                      cellPixels: 2, background: .black)
        XCTAssertEqual(preview.bytes, previewWithIgnoredBackground.bytes)
        let layout = MosaicLayout(product: plain, overlayAlpha: 0.2)
        XCTAssertEqual(layout.formatVersion, 1)
        XCTAssertNil(layout.shapeFrame)
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
        XCTAssertEqual(layout.formatVersion, 1, "S3 不把运行时掩码写成 manifest v2")
        XCTAssertEqual(layout.shapeFrame?.background, .white)
        XCTAssertEqual(layout.shapeFrame?.mask, grid.mask)
        let encoded = try JSONEncoder().encode(layout)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"shape\""))
        XCTAssertFalse(json.contains("\"formatVersion\":2"))
        let back = try JSONDecoder().decode(MosaicLayout.self, from: encoded)
        XCTAssertNil(back.shapeFrame, "写盘往返丢掉运行时掩码，所以不能靠它保存形状")
        XCTAssertEqual(back.formatVersion, 1)
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
        let shape = ShapeFrame(background: .black, mask: mask)
        let steps = ShapeStripExport.steps(columns: columns, rows: rows, cellPixels: 100, shape: shape)
        XCTAssertEqual(steps.map(\.index), Array(0..<(columns * rows)), "条带内仍是行优先，整表顺序不变")
        XCTAssertEqual(steps.filter { !$0.countsInFillStats }.map(\.index), [0, columns * rows - 1])
        XCTAssertEqual(steps[0].background, .black)
        XCTAssertEqual(steps.filter(\.countsInFillStats).count, mask.activeCount)
        let mismatched = ShapeFrame(background: .white, mask: try CellMask(columns: 2, rows: 2, allActive: false))
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
                                  params: photo.params, shapeFrame: ShapeFrame(background: .white, mask: mask))
        XCTAssertEqual(WorkFingerprint.of(photo), WorkFingerprint.of(shaped), "运行时掩码不进指纹，也不进 JSON")
    }

    /// 导出循环的同一套记账：形状外 `record` 不加，形状内的白格 / 糊格才加。掩码来自预设圆，不是手写两位。
    func testFillStatsUseTheSameRecordAsExport() throws {
        let grid = try ShapeLayoutRules.preset(.circle, density: .coarse)
        let frame = ShapeFrame(background: .black, mask: grid.mask)
        let steps = ShapeStripExport.steps(columns: grid.layout.columns, rows: grid.layout.rows,
                                           cellPixels: 32, shape: frame)
        XCTAssertEqual(steps.map(\.index), Array(0..<grid.mask.cellCount))
        var stats = ExportFillStats()
        var outside = 0
        for step in steps {
            if let background = step.background {
                XCTAssertEqual(background, .black)
                stats.record(step: step, fill: .blank)
                stats.record(step: step, fill: .blurryFallback)
                outside += 1
                continue
            }
            let insideBlank = step.index % 2 == 0
            stats.record(step: step, fill: insideBlank ? .blank : .blurryFallback)
        }
        XCTAssertEqual(outside, grid.mask.cellCount - grid.mask.activeCount)
        XCTAssertEqual(stats.total, grid.mask.activeCount)
        XCTAssertGreaterThan(stats.blank, 0)
        XCTAssertGreaterThan(stats.blurryFallback, 0)
        XCTAssertEqual(stats.blank + stats.blurryFallback, grid.mask.activeCount)
    }

    func testShapeResultIsNotSaved() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileWorksStore(directory: dir, images: FakeWorkImages())
        var layout = sampleLayout(["a", "", "c"])
        layout.shapeFrame = ShapeFrame(background: .black, mask: try CellMask(columns: layout.cols, rows: layout.rows, allActive: false))
        do {
            _ = try await store.save(WorkDraft(layout: layout, target: nil, overlayAlpha: 0, origin: .savedManually))
            XCTFail("形状结果不能存盘")
        } catch let error as WorksError {
            XCTAssertEqual(error, .unsupportedShapeSave)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        var filled = sampleLayout(["a", "", "c"])
        filled.cellAssignments[1].fill = CellColor(r: 1, g: 2, b: 3)
        do {
            _ = try await store.save(WorkDraft(layout: filled, target: nil, overlayAlpha: 0, origin: .savedManually))
            XCTFail("fc 仍要拒绝")
        } catch let error as WorksError {
            XCTAssertEqual(error, .unsupportedFilledCells)
        }
    }

    func testManifestContractRoundTripAndRejectsPartialV2() throws {
        let mask = try CellMask(columns: 2, rows: 2, bitsV1: [0b0000_0101])
        let manifest = ShapeManifest(
            spec: ShapeSpec(source: .preset(ShapePresetID(rawValue: "heart")), palette: .auto, background: .white),
            mask: mask,
            paletteStops: [[0.62, 0.12, 0.05], [0.70, 0.08, 0.10]])
        let data = try JSONEncoder().encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["source"] as? [String: Any])?["preset"] as? String, "heart")
        XCTAssertEqual(object["color"] as? String, "auto")
        XCTAssertEqual(object["background"] as? String, "white")
        XCTAssertNil(object["outline"])
        let back = try JSONDecoder().decode(ShapeManifest.self, from: data)
        XCTAssertEqual(back, manifest)
        let text = ShapeManifest(spec: ShapeSpec(source: .text(lines: ["生日快乐", "宝贝"]), palette: .warmRed, background: .black),
                                 mask: mask)
        XCTAssertEqual(try JSONDecoder().decode(ShapeManifest.self, from: JSONEncoder().encode(text)), text)
        let partial = Data(#"{"background":"white","mask":{"columns":2,"rows":2,"encoding":"bits-v1","data":"BQ=="}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ShapeManifest.self, from: partial), "缺 source / color 不是 v2")
        let unknown = Data(#"{"source":{"preset":"clover"},"color":"auto","background":"white","mask":{"columns":2,"rows":2,"encoding":"bits-v1","data":"BQ=="}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ShapeManifest.self, from: unknown))
        let legacy = Data(#"{"cells":[{"crop":[0,0,1,1],"id":"a"},{"crop":[0,0,1,1],"id":""}],"cols":2,"formatVersion":1,"params":{"density":"coarse","overlayAlpha":0.1,"seed":7},"rows":1,"targetCrop":[0,0,8,8],"targetSize":{"height":8,"width":8}}"#.utf8)
        let old = try JSONDecoder().decode(MosaicLayout.self, from: legacy)
        XCTAssertEqual(old.formatVersion, 1)
        XCTAssertNil(old.shapeFrame)
        XCTAssertEqual(old.cellAssignments[1].localIdentifier, "")
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
