import CoreGraphics
import ImageIO
import Photos
import UniformTypeIdentifiers
import XCTest
import MosaicCore
import MosaicAppCore
@testable import PhotoMosaic

/// 模拟器上的真实预览和导出。走 `MosaicPreviewRenderer` 与 `LiveMosaicExporter`。
///
/// 实际执行 28 组，不是 10×5×2＝100。未跑的 72 组是除爱心以外的 9 个形状 × 除蓝以外的 4 个配色 × 黑白。
/// 夹具缩略图是固定的红 220,30,30，用来确认形状内画的是这张图，不是背景，也不是特征色块。
/// 形状内只取一格中心。容差 12（预览）/ 28（JPEG）能分开这张红图和黑白底，也能挡住大约 0.3 的绿色；
/// 不能据此说轻微叠加的像素差是绝对 0。形状外只抽四角和至多两个其他外格的中心像素，不是整张逐像素比较。
/// 另有 10 个方向锚点（每个预设 1 个，不计入这 28 组）。方向断言不调用 `sample()`。
@MainActor
final class ShapeApplePixelTests: XCTestCase {
    private struct PixelCase: Equatable, Hashable {
        var preset: ShapePresetID
        var palette: ShapePalette
        var background: ShapeBackground
    }

    /// 10 个形状只配蓝、黑白都导出；爱心再补其余 4 个配色的黑白导出。爱心×蓝不重复。
    private static func executedCases() -> [PixelCase] {
        var cases: [PixelCase] = []
        for preset in PresetShapes.registry.map(\.id) {
            for background in [ShapeBackground.white, ShapeBackground.black] {
                cases.append(PixelCase(preset: preset, palette: .blue, background: background))
            }
        }
        for palette in ShapePalette.allCases where palette != .blue {
            for background in [ShapeBackground.white, ShapeBackground.black] {
                cases.append(PixelCase(preset: .heart, palette: palette, background: background))
            }
        }
        return cases
    }

    func testExecutedMatrixIsTwentyEightNotOneHundred() {
        let cases = Self.executedCases()
        XCTAssertEqual(PresetShapes.registry.count * ShapePalette.allCases.count * 2, 100)
        XCTAssertEqual(cases.count, 28)
        XCTAssertEqual(Set(cases).count, 28)
        let whitePalettes = Set(cases.filter { $0.preset == .heart && $0.background == .white }.map(\.palette))
        XCTAssertEqual(whitePalettes, Set(ShapePalette.allCases))
    }

    func testExecutedCasesRenderPhotoInsideAndExport() async throws {
        for item in Self.executedCases() {
            try await check(preset: item.preset, palette: item.palette, background: item.background)
        }
    }

    /// 上下方向。不调用 `sample()`：生产绘制和 `sample()` 一起翻转时，这里仍按位图第一行是上方来读。
    /// 不对称形状用「内格照片、垂直镜像在形状外的背景」。对称形状用上红下蓝的照片，预览和导出各自对绝对颜色，不拿两张图互相比。
    /// 这 10 个预设各 1 次，不放进 28 组，也不是 100 组。
    func testVerticalDirectionAnchorsInPreviewAndExport() async throws {
        let anchors = try Self.directionAnchors()
        XCTAssertEqual(anchors.count, 10)
        XCTAssertEqual(Self.executedCases().count, 28)
        for name in [ShapePresetID.birthdayCake, .house] {
            let anchor = try XCTUnwrap(anchors.first { $0.preset == name })
            XCTAssertNotNil(anchor.mirrorOutside, "\(anchor.basis)")
        }
        for anchor in anchors {
            let product = try await shapeProduct(preset: anchor.preset, palette: .blue, background: .black, density: anchor.density)
            let mask = try XCTUnwrap(product.shapeFrame).mask
            XCTAssertEqual(mask.columns, anchor.columns)
            XCTAssertEqual(mask.rows, anchor.rows)
            XCTAssertTrue(mask.isActive(anchor.inside), anchor.basis)
            if let mirror = anchor.mirrorOutside {
                XCTAssertFalse(mask.isActive(mirror), anchor.basis)
                XCTAssertNotEqual(anchor.inside / mask.columns, mirror / mask.columns, anchor.basis)
                try await checkDirection(product, mask: mask, thumbs: CountingThumbs(), anchor: anchor)
            } else {
                XCTAssertNil(anchor.mirrorOutside)
                try await checkDirection(product, mask: mask, thumbs: SplitVerticalThumbs(), anchor: anchor)
            }
        }
    }

    /// 正对照直接调用 `ImageIOWorkImages.loadImage`，次数加 1。不经过作品列表。
    /// 随后 `limitedAccess` 只是内存标记，这条路径不会再调用 loadImage。这不是真机 PhotoKit，也不是设备上的旧预览 0 次。
    /// 取证会话在正对照和保护路径之间不 reset。没手动刷新时，不能把 0 当成测量结果。
    func testProbePositiveControlThenLimitedFlagDoesNotRead() async throws {
        PreviewReadProbe.reset()
        var session = PreviewReadSession(baselineCount: PreviewReadProbe.fileReadCount, at: Date())
        XCTAssertEqual(session.baseline.count, 0)
        XCTAssertFalse(session.canUseAsMeasurement, "只有起点、还没刷新，不能把 0 当成没读过")
        XCTAssertNil(session.deltaSinceBaseline)

        let before = PreviewReadProbe.fileReadCount
        XCTAssertTrue(PreviewReadProbe.positiveControl())
        session.noteControl(delta: PreviewReadProbe.fileReadCount - before)
        XCTAssertEqual(session.controlDelta, 1, "正对照必须真的走进 loadImage，并且只加 1")
        XCTAssertFalse(session.canUseAsMeasurement, "正对照增量不是操作后的手动刷新")
        XCTAssertEqual(PreviewReadProbe.fileReadCount, session.baseline.count + 1, "正对照不清零")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shape-preview-read-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTinyJPEG(to: url)
        let meta = WorkMeta(id: WorkID(), createdAt: Date(), columns: 2, rows: 2, tier: nil, photoCount: 1,
                            missingCount: 0, overlayAlpha: 0, seed: 1, fingerprint: "x", origin: .savedManually,
                            previewFile: "preview.jpg", previewPixelWidth: 2, previewPixelHeight: 2, targetFile: nil)
        let summary = WorkSummary(meta: meta, previewURL: url)
        var state = WorksState()
        state.limitedAccess = true
        let skipped = state.decodePreview(for: summary) { ImageIOWorkImages.loadImage($0, maxPixel: 32) }
        XCTAssertNil(skipped)
        XCTAssertEqual(PreviewReadProbe.fileReadCount, 1, "保护路径没有再读；探针仍接着正对照的 1 次")

        session.noteRefresh(count: PreviewReadProbe.fileReadCount, at: Date())
        XCTAssertTrue(session.canUseAsMeasurement)
        XCTAssertEqual(session.deltaSinceBaseline, 1)
        let refreshed = try XCTUnwrap(session.refreshed)
        XCTAssertGreaterThanOrEqual(refreshed.at, session.baseline.at)

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let canConfirm = await PhotoKitExistenceChecker().canConfirmMissing()
        XCTAssertEqual(canConfirm, status == .authorized, "这只是模拟器当前授权，不是隐藏或受限场景")
    }

    /// 未刷新的会话即使起点是 0，也不是测量值。
    func testUnrefreshedZeroIsNotAMeasurement() {
        let session = PreviewReadSession(baselineCount: 0, at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(session.canUseAsMeasurement)
        XCTAssertNil(session.deltaSinceBaseline)
        XCTAssertNil(session.controlDelta)
    }

    /// 多个线程同时记一次读取，总数必须正好等于次数。锁在 `LockedState` 里，不靠 MainActor。
    func testConcurrentFileReadCountMatchesIterations() {
        PreviewReadProbe.reset()
        let iterations = 128
        recordPreviewReadsOnBackgroundThreads(iterations)
        XCTAssertEqual(PreviewReadProbe.fileReadCount, iterations)
    }

    /// 并发正对照各自直接调用一次 `loadImage`，增量等于成功次数。不经过作品列表。
    func testConcurrentPositiveControlIncrementsOnceEach() async {
        PreviewReadProbe.reset()
        let iterations = 8
        let results = await positiveControlsOffMainActor(iterations)
        XCTAssertEqual(results.count, iterations)
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(PreviewReadProbe.fileReadCount, iterations)
    }

    private func check(preset: ShapePresetID, palette: ShapePalette, background: ShapeBackground) async throws {
        let product = try await shapeProduct(preset: preset, palette: palette, background: background)
        let mask = try XCTUnwrap(product.shapeFrame).mask
        let outsideCells = representativeOutside(mask)
        let outsideTotal = (0..<mask.cellCount).reduce(into: 0) { if !mask.isActive($1) { $0 += 1 } }
        XCTAssertGreaterThanOrEqual(outsideCells.count, 4, "四角应在形状外。抽到 \(outsideCells.count)/\(outsideTotal)，不是全像素比较")
        XCTAssertLessThan(outsideCells.count, outsideTotal, "抽样 \(outsideCells.count) 格，外格共 \(outsideTotal)，不是全像素比较")
        let overlay = try solid(width: 32, height: 32, r: 0, g: 255, b: 0)
        let thumbs = CountingThumbs()

        let inside = try XCTUnwrap((0..<mask.cellCount).first { mask.isActive($0) })
        let blocks = try XCTUnwrap(MosaicPreviewRenderer.colorBlocks(product))
        let blockBytes = try bitmap(blocks)
        for outside in outsideCells {
            try assertCell(blockBytes, image: blocks, mask: mask, index: outside, background: background, tolerance: 2,
                           label: "\(preset.rawValue) \(palette) \(background) colorBlocks \(outside) \(outsideCells.count)/\(outsideTotal)")
        }
        let blockInside = sample(blockBytes, image: blocks, columns: mask.columns, rows: mask.rows,
                                 cellPixels: blocks.width / mask.columns, index: inside)

        let rendered = await MosaicPreviewRenderer.thumbnails(product, target: overlay, overlayAlpha: 0.3, thumbnails: thumbs)
        let preview = try XCTUnwrap(rendered)
        let previewBytes = try bitmap(preview)
        let cp = MosaicPreviewRenderer.cellPixels(for: product.generation)
        XCTAssertEqual(preview.width, mask.columns * cp)
        for outside in outsideCells {
            try assertCell(previewBytes, image: preview, mask: mask, index: outside, background: background, tolerance: 2,
                           label: "\(preset.rawValue) \(background) preview \(outside) \(outsideCells.count)/\(outsideTotal)")
            // 黑底上绿色通道 < 40 能挡住大约 0.3 的纯绿（约 76）。更淡的叠加仍可能通过，不是绝对 0。
            if background == .black {
                assertNotTinted(previewBytes, image: preview, mask: mask, index: outside, label: "preview overlay \(outside)")
            }
        }
        try assertFetchesStayInside(thumbs.idsSnapshot(), product: product)
        let previewInside = sample(previewBytes, image: preview, columns: mask.columns, rows: mask.rows, cellPixels: cp, index: inside)
        // 容差 12 能分开红图和黑白底。不能证明轻微叠加为绝对 0。形状内仍只抽这一格。
        assertPhotoSwatch(previewInside, tolerance: 12, label: "\(preset.rawValue) \(palette) \(background) preview inside")
        assertNotSame(previewInside, blockInside, label: "预览不是特征色块")

        let request = ExportRequest(product: product, target: overlay, overlayAlpha: 0.3, tier: .share)
        XCTAssertEqual(request.overlayAlpha, 0)
        thumbs.reset()
        let url = try await LiveMosaicExporter(thumbnails: thumbs).export(request) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }
        let jpeg = try XCTUnwrap(decodeJPEG(url))
        let plan = request.plan(availableMemoryBytes: LiveMosaicExporter.availableMemory())
        let jpegBytes = try bitmap(jpeg)
        XCTAssertEqual(jpeg.width, mask.columns * plan.cellPixels)
        for outside in outsideCells {
            try assertCell(jpegBytes, image: jpeg, mask: mask, index: outside, background: background, tolerance: 18,
                           label: "\(preset.rawValue) \(background) export \(outside) \(outsideCells.count)/\(outsideTotal)")
            if background == .black {
                assertNotTinted(jpegBytes, image: jpeg, mask: mask, index: outside, label: "export overlay \(outside)")
            }
        }
        try assertFetchesStayInside(thumbs.idsSnapshot(), product: product)
        let exportInside = sample(jpegBytes, image: jpeg, columns: mask.columns, rows: mask.rows,
                                  cellPixels: plan.cellPixels, index: inside)
        // 容差 28 是 JPEG 误差。能分开红图和黑白底，不能证明轻微叠加为绝对 0。
        assertPhotoSwatch(exportInside, tolerance: 28, label: "\(preset.rawValue) \(palette) \(background) export inside")
        if background == .black {
            for outside in outsideCells {
                let previewOutside = sample(previewBytes, image: preview, columns: mask.columns, rows: mask.rows, cellPixels: cp, index: outside)
                let exportOutside = sample(jpegBytes, image: jpeg, columns: mask.columns, rows: mask.rows,
                                           cellPixels: plan.cellPixels, index: outside)
                for pair in [(previewOutside.0, exportOutside.0), (previewOutside.1, exportOutside.1), (previewOutside.2, exportOutside.2)] {
                    XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), 18, "预览和导出的形状外抽样格 \(outside) 颜色应一致")
                }
            }
        }
    }

    /// 四角，加上一个不在边上的外格（如果有）和最后一个外格。有上限，不是把外格都查完。
    private func representativeOutside(_ mask: CellMask) -> [Int] {
        var picked: [Int] = []
        func add(_ index: Int) {
            guard (0..<mask.cellCount).contains(index), !mask.isActive(index), !picked.contains(index) else { return }
            picked.append(index)
        }
        add(0)
        add(mask.columns - 1)
        add((mask.rows - 1) * mask.columns)
        add(mask.cellCount - 1)
        let inset = (0..<mask.cellCount).first { index in
            let column = index % mask.columns
            let row = index / mask.columns
            let border = column == 0 || row == 0 || column == mask.columns - 1 || row == mask.rows - 1
            return !border && !mask.isActive(index)
        }
        if let inset { add(inset) }
        if let last = (0..<mask.cellCount).last(where: { !mask.isActive($0) }) { add(last) }
        return picked
    }

    private struct DirectionAnchor {
        var preset: ShapePresetID
        var density: DensityChoice
        var columns: Int
        var rows: Int
        var inside: Int
        var mirrorOutside: Int?
        var basis: String
    }

    /// 粗档优先。粗档没有「内格的垂直镜像在形状外」时才改中档、细档，并写进 `basis`。三档都没有就保持粗档，改用上下分色照片。
    private static func directionAnchors() throws -> [DirectionAnchor] {
        var anchors: [DirectionAnchor] = []
        for preset in PresetShapes.registry.map(\.id) {
            let coarse = try ShapeLayoutRules.preset(preset, density: .coarse).mask
            if let pair = farthestMirrorPair(coarse) {
                anchors.append(anchor(preset, .coarse, coarse, pair, "粗档有镜像对"))
                continue
            }
            var finer: DirectionAnchor?
            for density in [DensityChoice.medium, .fine] {
                let mask = try ShapeLayoutRules.preset(preset, density: density.density).mask
                if let pair = farthestMirrorPair(mask) {
                    finer = anchor(preset, density, mask, pair, "粗档没有镜像对，改用\(density == .medium ? "中档" : "细档")")
                    break
                }
            }
            if let finer {
                anchors.append(finer)
                continue
            }
            let inside = try XCTUnwrap((0..<coarse.cellCount).first { coarse.isActive($0) })
            let row = inside / coarse.columns
            let column = inside % coarse.columns
            anchors.append(DirectionAnchor(
                preset: preset, density: .coarse, columns: coarse.columns, rows: coarse.rows,
                inside: inside, mirrorOutside: nil,
                basis: "\(preset.rawValue) 粗档上下对称，没有镜像对；内格 r\(row) c\(column)，夹具上红 220,30,30 下蓝 30,30,220"))
        }
        return anchors
    }

    private static func anchor(_ preset: ShapePresetID, _ density: DensityChoice, _ mask: CellMask,
                               _ pair: (inside: Int, outside: Int), _ why: String) -> DirectionAnchor {
        let insideRow = pair.inside / mask.columns
        let insideColumn = pair.inside % mask.columns
        let outsideRow = pair.outside / mask.columns
        return DirectionAnchor(
            preset: preset, density: density, columns: mask.columns, rows: mask.rows,
            inside: pair.inside, mirrorOutside: pair.outside,
            basis: "\(preset.rawValue) \(why)：内格 r\(insideRow) c\(insideColumn) 应为照片红，垂直镜像 r\(outsideRow) 在形状外应为黑底")
    }

    /// 同一列里，形状内格子与它的垂直镜像（行号 `rows - 1 - row`）相距最远、且镜像在形状外的一对。
    private static func farthestMirrorPair(_ mask: CellMask) -> (inside: Int, outside: Int)? {
        var best: (distance: Int, inside: Int, outside: Int)?
        for index in 0..<mask.cellCount where mask.isActive(index) {
            let column = index % mask.columns
            let row = index / mask.columns
            let mirroredRow = mask.rows - 1 - row
            if mirroredRow == row { continue }
            let mirrored = mirroredRow * mask.columns + column
            guard !mask.isActive(mirrored) else { continue }
            let distance = abs(row - mirroredRow)
            if best == nil || distance > best!.distance {
                best = (distance, index, mirrored)
            }
        }
        return best.map { ($0.inside, $0.outside) }
    }

    private enum DirectionSlot { case upper, center, lower }

    private func checkDirection(_ product: GenerationProduct, mask: CellMask, thumbs: any ThumbnailProviding,
                                anchor: DirectionAnchor) async throws {
        let unusedTarget = try solid(width: 8, height: 8, r: 0, g: 255, b: 0)
        let rendered = await MosaicPreviewRenderer.thumbnails(product, target: unusedTarget, overlayAlpha: 0, thumbnails: thumbs)
        let preview = try XCTUnwrap(rendered)
        let previewBytes = try bitmap(preview)
        let previewCell = MosaicPreviewRenderer.cellPixels(for: product.generation)
        XCTAssertGreaterThanOrEqual(previewCell, 8, anchor.basis)
        XCTAssertEqual(preview.width, mask.columns * previewCell)
        XCTAssertEqual(preview.height, mask.rows * previewCell)
        try assertDirectionPixels(previewBytes, width: preview.width, cellPixels: previewCell, anchor: anchor,
                                  tolerance: 12, backgroundTolerance: 2, label: "preview")

        let request = ExportRequest(product: product, target: unusedTarget, overlayAlpha: 0, tier: .share)
        let url = try await LiveMosaicExporter(thumbnails: thumbs).export(request) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }
        let jpeg = try XCTUnwrap(decodeJPEG(url))
        let jpegBytes = try bitmap(jpeg)
        let exportCell = jpeg.width / mask.columns
        XCTAssertGreaterThanOrEqual(exportCell, 8, anchor.basis)
        XCTAssertEqual(jpeg.width, mask.columns * exportCell)
        XCTAssertEqual(jpeg.height, mask.rows * exportCell)
        try assertDirectionPixels(jpegBytes, width: jpeg.width, cellPixels: exportCell, anchor: anchor,
                                  tolerance: 28, backgroundTolerance: 18, label: "export")
    }

    private func assertDirectionPixels(_ bytes: [UInt8], width: Int, cellPixels: Int, anchor: DirectionAnchor,
                                       tolerance: Int, backgroundTolerance: Int, label: String) throws {
        if let mirror = anchor.mirrorOutside {
            let inside = pixelFromTop(bytes, width: width, columns: anchor.columns, cellPixels: cellPixels,
                                      index: anchor.inside, slot: .center)
            let outside = pixelFromTop(bytes, width: width, columns: anchor.columns, cellPixels: cellPixels,
                                       index: mirror, slot: .center)
            assertNear(inside, (220, 30, 30), tolerance: tolerance, label: "\(anchor.basis) \(label) 内格")
            assertNear(outside, (0, 0, 0), tolerance: backgroundTolerance, label: "\(anchor.basis) \(label) 镜像外格")
        } else {
            let upper = pixelFromTop(bytes, width: width, columns: anchor.columns, cellPixels: cellPixels,
                                     index: anchor.inside, slot: .upper)
            let lower = pixelFromTop(bytes, width: width, columns: anchor.columns, cellPixels: cellPixels,
                                     index: anchor.inside, slot: .lower)
            assertNear(upper, (220, 30, 30), tolerance: tolerance, label: "\(anchor.basis) \(label) 上")
            assertNear(lower, (30, 30, 220), tolerance: tolerance, label: "\(anchor.basis) \(label) 下")
        }
    }

    /// 位图第一行是上方。故意不调用 `sample()`。
    private func pixelFromTop(_ bytes: [UInt8], width: Int, columns: Int, cellPixels: Int, index: Int,
                              slot: DirectionSlot) -> (UInt8, UInt8, UInt8) {
        let column = index % columns
        let row = index / columns
        let x = column * cellPixels + cellPixels / 2
        let yInCell: Int
        switch slot {
        case .upper: yInCell = cellPixels / 4
        case .center: yInCell = cellPixels / 2
        case .lower: yInCell = cellPixels - 1 - cellPixels / 4
        }
        let y = row * cellPixels + yInCell
        let o = y * width * 4 + x * 4
        guard o >= 0, o + 2 < bytes.count else {
            XCTFail("方向锚点越界 row \(row) x \(x) y \(y)")
            return (0, 0, 0)
        }
        return (bytes[o], bytes[o + 1], bytes[o + 2])
    }

    private func shapeProduct(preset: ShapePresetID, palette: ShapePalette, background: ShapeBackground,
                              density: DensityChoice = .coarse) async throws -> GenerationProduct {
        let choice = ShapeChoice(preset: preset, palette: palette, background: background)
        let grid = try ShapeGenerationPlan.grid(choice, density: density.density)
        let target = try ShapeGenerationPlan.target(choice, grid: grid, photoColors: [])
        let snap = try snapshot(count: 40)
        return try await GenerationRunner().run(target: target, snapshot: snap,
                                                settings: GenerationSettings(density: density, overlayAlpha: 0.3),
                                                seed: 5, activeCells: grid.mask, shapeBackground: background)
    }

    private func snapshot(count: Int) throws -> IndexSnapshot {
        let records = (0..<count).map { i -> FeatureRecord in
            let l = Float(i % 20) / 20
            return FeatureRecord(vector: FeatureVector(uniform: SIMD3(l, 0.08, -0.02)), lightnessVariance: 0.02, aspectRatio: 1)
        }
        return IndexSnapshot(library: try LibrarySnapshot(table: FeatureTable(records: records)),
                             assetIDsByRow: (0..<count).map { "asset-\($0)" })
    }

    private func assertCell(_ bytes: [UInt8], image: CGImage, mask: CellMask, index: Int, background: ShapeBackground,
                            tolerance: Int, label: String) throws {
        let expected: UInt8 = background == .black ? 0 : 255
        let pixel = sample(bytes, image: image, columns: mask.columns, rows: mask.rows,
                           cellPixels: image.width / mask.columns, index: index)
        for channel in [pixel.0, pixel.1, pixel.2] {
            XCTAssertLessThanOrEqual(abs(Int(channel) - Int(expected)), tolerance, "\(label) \(pixel)")
        }
    }

    private func assertNear(_ pixel: (UInt8, UInt8, UInt8), _ expected: (UInt8, UInt8, UInt8), tolerance: Int, label: String) {
        for pair in [(pixel.0, expected.0), (pixel.1, expected.1), (pixel.2, expected.2)] {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), tolerance, "\(label) \(pixel)")
        }
    }

    private func assertPhotoSwatch(_ pixel: (UInt8, UInt8, UInt8), tolerance: Int, label: String) {
        let swatch = (UInt8(220), UInt8(30), UInt8(30))
        for pair in [(pixel.0, swatch.0), (pixel.1, swatch.1), (pixel.2, swatch.2)] {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), tolerance, "\(label) \(pixel)")
        }
        XCTAssertGreaterThan(abs(Int(pixel.0) - 255) + abs(Int(pixel.1) - 255) + abs(Int(pixel.2) - 255), 80, "\(label) 不是白底")
        XCTAssertGreaterThan(Int(pixel.0) + Int(pixel.1) + Int(pixel.2), 80, "\(label) 不是黑底")
    }

    private func assertNotSame(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), label: String) {
        let delta = abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2))
        XCTAssertGreaterThan(delta, 40, label)
    }

    private func assertNotTinted(_ bytes: [UInt8], image: CGImage, mask: CellMask, index: Int, label: String) {
        let pixel = sample(bytes, image: image, columns: mask.columns, rows: mask.rows,
                           cellPixels: image.width / mask.columns, index: index)
        XCTAssertLessThan(Int(pixel.1), 40, "\(label) 形状外不应被绿色叠加染色 \(pixel)")
    }

    private func assertFetchesStayInside(_ ids: [String], product: GenerationProduct) throws {
        let mask = try XCTUnwrap(product.shapeFrame).mask
        var inside = Set<String>()
        for index in 0..<mask.cellCount {
            guard let id = product.cellAssetIDs[index] else { continue }
            if mask.isActive(index) { inside.insert(id) }
            else { XCTFail("形状外格子不应分配照片") }
        }
        XCTAssertFalse(inside.isEmpty)
        XCTAssertEqual(Set(ids), inside)
    }

    private func sample(_ bytes: [UInt8], image: CGImage, columns: Int, rows: Int, cellPixels: Int, index: Int) -> (UInt8, UInt8, UInt8) {
        let column = index % columns, row = index / columns
        let x = column * cellPixels + cellPixels / 2
        // 第一行是图像上方，和 PixelBuffer / ImagePixels 的上下文一致。
        // 386cb88 按高度翻转后，形状内中心读到的是背景（白底 255,255,255，黑底 0,0,0）。
        let y = row * cellPixels + cellPixels / 2
        let o = y * image.width * 4 + x * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2])
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

    private func writeTinyJPEG(to url: URL) throws {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.2, 0.4, 0.6, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(ctx.makeImage())
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return XCTFail("写不出 jpeg")
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}

/// 文件级函数，不在测试类的 MainActor 上。`concurrentPerform` 会换线程调用计数。
private func recordPreviewReadsOnBackgroundThreads(_ iterations: Int) {
    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
        PreviewReadProbe.recordFileRead()
    }
}

/// `Task.detached` 不继承调用方 actor。每个任务直接跑一次正对照。
private func positiveControlsOffMainActor(_ iterations: Int) async -> [Bool] {
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<iterations {
            group.addTask {
                await Task.detached { PreviewReadProbe.positiveControl() }.value
            }
        }
        var values: [Bool] = []
        for await value in group { values.append(value) }
        return values
    }
}

private struct SplitVerticalThumbs: ThumbnailProviding {
    let tile: PixelBuffer

    init() {
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        for row in 0..<8 {
            let upper = row < 4
            for column in 0..<8 {
                let o = (row * 8 + column) * 4
                bytes[o] = upper ? 220 : 30
                bytes[o + 1] = 30
                bytes[o + 2] = upper ? 30 : 220
            }
        }
        tile = try! PixelBuffer(width: 8, height: 8, bytes: bytes)
    }

    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        .image(tile)
    }
}

private final class CountingThumbs: ThumbnailProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private let tile: PixelBuffer

    init() {
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = 220
            bytes[i + 1] = 30
            bytes[i + 2] = 30
        }
        tile = try! PixelBuffer(width: 8, height: 8, bytes: bytes)
    }

    func idsSnapshot() -> [String] { withLock { ids } }
    func reset() { withLock { ids.removeAll() } }

    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        record(assetID)
        return .image(tile)
    }

    private func record(_ id: String) { withLock { ids.append(id) } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
