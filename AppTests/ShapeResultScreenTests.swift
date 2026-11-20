import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
import MosaicCore
import MosaicAppCore
@testable import PhotoMosaic

/// 形状从「用形状拼」进入，不选用户目标图。fd3c7f0 上结果页仍出现，但 `AppModel.renderPreview` 和
/// `canExport` 都要求 `coordinator.target`，预览保持空白、导出保持禁用。
/// 这是 AppModel 集成测试，不是 XCUITest，也不打开可见界面或真机。
/// 结果页「导出」按钮经档位页调用 `model.saveTapped()`，这里测的就是这个方法。
@MainActor
final class ShapeResultScreenTests: XCTestCase {
    private let tile = (r: UInt8(20), g: UInt8(180), b: UInt8(40))

    func testSelectedPhotoStaysPhotoThroughConfirmAndGeneration() async throws {
        let harness = try await makeHarness()
        defer { harness.model.coordinator.stop(); try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let ready = await waitUntil {
            model.coordinator.state.indexStatus.hasCompletedInitialScan && model.coordinator.state.indexStatus.available > 0
        }
        XCTAssertTrue(ready, "合成素材没有扫进索引")
        XCTAssertTrue(model.flow.offersShapeEntry)
        let photo = try PixelBuffer(width: 64, height: 48, bytes: [UInt8](repeating: 9, count: 64 * 48 * 4))
        model.coordinator.setTarget(photo)
        XCTAssertFalse(model.flow.offersShapeEntry, "目标页在照片选上后不再提供图形入口")
        model.beginShape()
        XCTAssertNil(model.flow.shape)
        XCTAssertEqual(model.flow.step, .target)
        model.flowSend(.next)
        model.flowSend(.next)
        XCTAssertEqual(model.flow.step, .settings)
        XCTAssertNil(model.flow.shape, "确认页没有形状、预设、文字、配色或背景")
        XCTAssertEqual(model.coordinator.target?.width, photo.width)
        await model.coordinator.generateTapped()
        await passShortagePrompt(model)
        await model.coordinator.settle()
        guard case .result = model.flow.generation.phase else {
            return XCTFail("照片没有生成 \(model.flow.generation.phase)")
        }
        XCTAssertNil(model.coordinator.product?.shapeFrame, "生成用的是已选照片，不是爱心")
        XCTAssertEqual(model.coordinator.target?.bytes.prefix(12), photo.bytes.prefix(12))
    }

    func testPhotoModeWithoutTargetHasNoPreviewAndDoesNotExport() async throws {
        let harness = try await makeHarness()
        defer { harness.model.coordinator.stop(); try? FileManager.default.removeItem(at: harness.root) }
        let ready = await waitUntil {
            harness.model.coordinator.state.indexStatus.hasCompletedInitialScan
                && harness.model.coordinator.state.indexStatus.available > 0
        }
        XCTAssertTrue(ready, "合成素材没有扫进索引")
        XCTAssertNil(harness.model.flow.shape)
        XCTAssertNil(harness.model.coordinator.target)
        XCTAssertNil(harness.model.resultImage)
        XCTAssertFalse(harness.model.canExport)

        harness.model.generateTapped()
        await passShortagePrompt(harness.model)
        let failed = await waitUntil {
            if case .failed = harness.model.flow.generation.phase { return true }
            return false
        }
        XCTAssertTrue(failed, "没有用户目标图的照片生成应失败，实际 \(harness.model.flow.generation.phase)")
        XCTAssertNotEqual(harness.model.flow.step, .result)
        XCTAssertNil(harness.model.coordinator.product)
        XCTAssertNil(harness.model.resultImage)
        XCTAssertFalse(harness.model.canExport)
        harness.model.saveTapped()
        try? await Task.sleep(nanoseconds: 200_000_000)
        await harness.model.coordinator.settle()
        XCTAssertEqual(harness.library.attemptCount, 0)
        XCTAssertNotEqual(harness.model.exportPhase, .saved)
    }

    func testShapeEntryShowsPreviewAndEnablesExportWithoutUserPhoto() async throws {
        let harness = try await makeHarness()
        defer { harness.model.coordinator.stop(); try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let library = harness.library
        let ready = await waitUntil {
            model.coordinator.state.indexStatus.hasCompletedInitialScan && model.coordinator.state.indexStatus.available > 0
        }
        XCTAssertTrue(ready, "合成素材没有扫进索引")

        model.beginShape()
        XCTAssertNotNil(model.flow.shape)
        model.setDensity(.coarse)
        model.flowSend(.next)
        XCTAssertEqual(model.flow.step, .settings)
        await model.coordinator.generateTapped()
        await passShortagePrompt(model)
        await model.coordinator.settle()

        guard case .result = model.flow.generation.phase else {
            return XCTFail("没有进入结果页 \(model.flow.generation.phase)")
        }
        XCTAssertEqual(model.flow.step, .result)
        XCTAssertNotNil(model.coordinator.product?.shapeFrame)
        XCTAssertNil(model.coordinator.target, "这条路径没有用户目标图")
        XCTAssertFalse(model.allowsWorkSave)
        XCTAssertTrue(model.canExport, "结果已经生成，导出不应因为没有用户目标图而禁用")

        let product = try XCTUnwrap(model.coordinator.product)
        let mask = try XCTUnwrap(product.shapeFrame).mask
        let previewCell = MosaicPreviewRenderer.cellPixels(for: product.generation)
        let shown = await waitUntil { model.resultImage?.width == mask.columns * previewCell }
        let image = try XCTUnwrap(model.resultImage, "结果页没有可显示的预览")
        XCTAssertTrue(shown)
        XCTAssertEqual(image.height, mask.rows * previewCell)
        let previewBytes = try bitmap(image)
        let inside = try XCTUnwrap((0..<mask.cellCount).first { mask.isActive($0) })
        let previewPixel = pixelFromTop(previewBytes, width: image.width, columns: mask.columns, cellPixels: previewCell, index: inside)
        assertNear(previewPixel, tile, tolerance: 24, label: "预览内格")

        XCTAssertEqual(library.attemptCount, 0)
        model.saveTapped()
        let saved = await waitUntil { if case .saved = model.exportPhase { return true }; return false }
        XCTAssertTrue(saved, "saveTapped 后不是已写入相册：\(model.exportPhase)")
        await model.coordinator.settle()
        XCTAssertEqual(library.successCount, 1)
        XCTAssertEqual(library.attemptCount, 1)
        let jpegData = try XCTUnwrap(library.lastJPEG)
        let jpeg = try XCTUnwrap(decodeJPEG(jpegData))
        XCTAssertGreaterThan(jpeg.width, 8)
        let exportCell = jpeg.width / mask.columns
        XCTAssertEqual(jpeg.width, mask.columns * exportCell)
        let exportPixel = pixelFromTop(try bitmap(jpeg), width: jpeg.width, columns: mask.columns, cellPixels: exportCell, index: inside)
        assertNear(exportPixel, tile, tolerance: 36, label: "导出内格")

        model.dismissExportResult()
        library.setWrite(.fail)
        model.saveTapped()
        let failed = await waitUntil { if case .failed(.other) = model.exportPhase { return true }; return false }
        XCTAssertTrue(failed, "相册写入失败后不是 .failed(.other)：\(model.exportPhase)")
        await model.coordinator.settle()
        XCTAssertEqual(library.successCount, 1)
        XCTAssertEqual(library.attemptCount, 2)

        model.dismissExportResult()
        library.setAddOnly(.denied)
        model.saveTapped()
        let denied = await waitUntil { if case .failed(.addDenied) = model.exportPhase { return true }; return false }
        XCTAssertTrue(denied, "拒绝添加权限后不是 .failed(.addDenied)：\(model.exportPhase)")
        await model.coordinator.settle()
        XCTAssertEqual(library.attemptCount, 2, "权限被拒时不应再调用相册写入")
    }

    func testShapePreviewHintAndStaleParametersDoNotExportOldResult() async throws {
        let harness = try await makeHarness()
        defer { harness.model.coordinator.stop(); try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let ready = await waitUntil {
            model.coordinator.state.indexStatus.hasCompletedInitialScan && model.coordinator.state.indexStatus.available > 0
        }
        XCTAssertTrue(ready, "合成素材没有扫进索引")
        XCTAssertFalse(model.showsFinishedPreviewHint)
        model.beginShape()
        let source = model.flow.source.selection
        model.setDensity(.coarse)
        model.flowSend(.next)
        await model.coordinator.generateTapped()
        await passShortagePrompt(model)
        await model.coordinator.settle()
        guard case .result = model.flow.generation.phase else {
            return XCTFail("没有进入结果页 \(model.flow.generation.phase)")
        }
        let shown = await waitUntil { model.resultImage != nil }
        XCTAssertTrue(shown)
        XCTAssertTrue(model.showsFinishedPreviewHint, "有效成品才显示双指放大提示")
        XCTAssertTrue(model.canExport)
        XCTAssertFalse(model.allowsWorkSave)

        model.setShapePalette(.blue)
        XCTAssertTrue(model.shapeEditsNeedRegeneration)
        XCTAssertFalse(model.canExport, "新配色还没生成，不能把旧图导出成新结果")
        XCTAssertFalse(model.showsFinishedPreviewHint)
        model.saveTapped()
        try? await Task.sleep(nanoseconds: 200_000_000)
        await model.coordinator.settle()
        XCTAssertEqual(harness.library.attemptCount, 0)

        model.setShapePalette(.auto)
        XCTAssertFalse(model.shapeEditsNeedRegeneration)
        XCTAssertTrue(model.canExport)
        let seed = model.coordinator.product?.generation.seed
        model.startNewMosaicTapped()
        XCTAssertNil(model.unsavedPrompt)
        XCTAssertEqual(model.flow.step, .settings)
        XCTAssertEqual(model.flow.shape?.preset, .heart)
        XCTAssertEqual(model.flow.source.selection, source)
        model.setShapePalette(.blue)
        model.flowSend(.back)
        XCTAssertEqual(model.flow.step, .result)
        XCTAssertEqual(model.flow.shape?.palette, .auto)
        XCTAssertEqual(model.flow.source.selection, source)
        XCTAssertEqual(model.coordinator.product?.generation.seed, seed)
        XCTAssertTrue(model.canExport)
        XCTAssertTrue(model.showsFinishedPreviewHint)
    }

    /// 配置里的正文经 `startFromSettings` → `generateText`。调用的是 AppModel 方法，不是 SwiftUI 点击，也不是 XCUITest。
    func testShapeConfigTextReachesPreviewAndJPEG() async throws {
        let harness = try await makeHarness()
        defer { harness.model.coordinator.stop(); try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let ready = await waitUntil {
            model.coordinator.state.indexStatus.hasCompletedInitialScan && model.coordinator.state.indexStatus.available > 0
        }
        XCTAssertTrue(ready, "合成素材没有扫进索引")
        model.beginShape()
        model.setShapeUsesText(true)
        model.setShapeTextLine(0, "满月快乐呀")
        XCTAssertEqual(model.flow.shape?.textLines.first, "")
        XCTAssertEqual(model.shapeTextNotice, .lineTooLong(line: 0))
        model.setShapeTextLine(0, "😀")
        XCTAssertEqual(model.shapeTextNotice, .unsupported)
        XCTAssertFalse(model.shapeTextCanGenerate)
        await model.startFromSettings()
        XCTAssertNil(model.coordinator.product, "超限和 emoji 不能进入生成")

        model.setShapeTextLine(0, "生日快乐\n宝贝")
        XCTAssertEqual(TextDraftEditor.committedLines(model.flow.shape?.textLines ?? []), ["生日快乐", "宝贝"])
        XCTAssertNil(model.shapeTextNotice)
        model.setShapeTextLine(0, "生日快乐\n宝贝\n呀")
        XCTAssertEqual(TextDraftEditor.committedLines(model.flow.shape?.textLines ?? []), ["生日快乐", "宝贝"])
        XCTAssertEqual(model.shapeTextNotice, .tooManyLines)
        XCTAssertTrue(model.shapeTextCanGenerate)
        XCTAssertEqual(model.flow.settings.density, .fine)
        XCTAssertEqual(model.flow.shape?.background, .white)
        model.flowSend(.next)
        await model.startFromSettings()
        await passShortagePrompt(model)
        await model.coordinator.settle()
        guard case .result = model.flow.generation.phase else {
            return XCTFail("配置正文没有进入结果页 \(model.flow.generation.phase)")
        }
        XCTAssertEqual(model.flow.shape?.usesText, true)
        XCTAssertEqual(TextDraftEditor.committedLines(model.flow.shape?.textLines ?? []), ["生日快乐", "宝贝"])
        XCTAssertFalse(model.allowsWorkSave)
        XCTAssertNil(model.coordinator.target)
        let product = try XCTUnwrap(model.coordinator.product)
        let mask = try XCTUnwrap(product.shapeFrame).mask
        XCTAssertEqual(max(mask.columns, mask.rows), 120)
        XCTAssertEqual(model.coordinator.state.flow.settings.density, .fine)
        let previewCell = MosaicPreviewRenderer.cellPixels(for: product.generation)
        let shown = await waitUntil { model.resultImage?.width == mask.columns * previewCell }
        XCTAssertTrue(shown, "文字结果没有按网格尺寸显示预览")
        XCTAssertTrue(model.showsFinishedPreviewHint)
        let image = try XCTUnwrap(model.resultImage)
        XCTAssertEqual(image.width, mask.columns * previewCell)
        XCTAssertEqual(image.height, mask.rows * previewCell)
        let inside = try XCTUnwrap((0..<mask.cellCount).first { mask.isActive($0) })
        let outside = try XCTUnwrap((0..<mask.cellCount).first { !mask.isActive($0) })
        let previewBytes = try bitmap(image)
        assertNear(pixelFromTop(previewBytes, width: image.width, columns: mask.columns, cellPixels: previewCell, index: inside),
                   tile, tolerance: 24, label: "配置正文预览内格")
        assertNear(pixelFromTop(previewBytes, width: image.width, columns: mask.columns, cellPixels: previewCell, index: outside),
                   (r: 255, g: 255, b: 255), tolerance: 8, label: "配置正文预览掩码外")
        model.saveTapped()
        let saved = await waitUntil { if case .saved = model.exportPhase { return true }; return false }
        XCTAssertTrue(saved, "saveTapped 后不是已写入相册：\(model.exportPhase)")
        let jpeg = try XCTUnwrap(decodeJPEG(try XCTUnwrap(harness.library.lastJPEG)))
        let exportCell = jpeg.width / mask.columns
        XCTAssertGreaterThan(exportCell, 0)
        XCTAssertEqual(jpeg.width, mask.columns * exportCell)
        XCTAssertEqual(jpeg.height, mask.rows * exportCell)
        let exportBytes = try bitmap(jpeg)
        assertNear(pixelFromTop(exportBytes, width: jpeg.width, columns: mask.columns, cellPixels: exportCell, index: inside),
                   tile, tolerance: 36, label: "配置正文导出内格")
        assertNear(pixelFromTop(exportBytes, width: jpeg.width, columns: mask.columns, cellPixels: exportCell, index: outside),
                   (r: 255, g: 255, b: 255), tolerance: 8, label: "配置正文导出掩码外")
    }

    func testOfficialTextGroupsReachPreviewPixelsAndJPEG() async throws {
        let groups: [[String]] = [
            TextComposition.lines(from: "520"),
            TextComposition.lines(from: "满月快乐"),
            TextComposition.lines(from: "LOVE"),
            TextComposition.lines(from: "生日快乐\n宝贝"),
        ]
        XCTAssertEqual(groups[3], ["生日快乐", "宝贝"])
        var problems: [String] = []
        for lines in groups {
            let label = lines.joined(separator: "/")
            let harness = try await makeHarness()
            defer { harness.model.coordinator.stop(); try? FileManager.default.removeItem(at: harness.root) }
            let model = harness.model
            let ready = await waitUntil {
                model.coordinator.state.indexStatus.hasCompletedInitialScan && model.coordinator.state.indexStatus.available > 0
            }
            XCTAssertTrue(ready, "合成素材没有扫进索引")
            do {
                try await model.generateText(lines: lines, palette: .warmRed, background: .white)
            } catch {
                problems.append("\(label) \(error)")
                continue
            }
            await passShortagePrompt(model)
            await model.coordinator.settle()
            guard case .result = model.flow.generation.phase else {
                problems.append("\(label) 没有进入结果页 \(model.flow.generation.phase)")
                continue
            }
            let product = try XCTUnwrap(model.coordinator.product)
            let mask = try XCTUnwrap(product.shapeFrame).mask
            XCTAssertEqual(max(mask.columns, mask.rows), 120, "\(lines)")
            XCTAssertEqual(model.coordinator.state.flow.settings.density, .fine, "\(lines)")
            XCTAssertNil(model.coordinator.target)
            XCTAssertFalse(model.allowsWorkSave, "\(lines)")
            let previewCell = MosaicPreviewRenderer.cellPixels(for: product.generation)
            let shown = await waitUntil { model.resultImage?.width == mask.columns * previewCell }
            XCTAssertTrue(shown, "\(lines) 没有按网格尺寸显示预览")
            XCTAssertTrue(model.showsFinishedPreviewHint, "\(lines)")
            let image = try XCTUnwrap(model.resultImage)
            XCTAssertEqual(image.width, mask.columns * previewCell, "\(lines)")
            XCTAssertEqual(image.height, mask.rows * previewCell, "\(lines)")
            attachRaster(image, name: "preview-\(label)")
            attachMask(mask, name: label)
            let inside = try XCTUnwrap((0..<mask.cellCount).first { mask.isActive($0) })
            let previewPixel = pixelFromTop(try bitmap(image), width: image.width, columns: mask.columns,
                                            cellPixels: previewCell, index: inside)
            assertNear(previewPixel, tile, tolerance: 24, label: "\(lines) 预览内格")
            model.saveTapped()
            let saved = await waitUntil { if case .saved = model.exportPhase { return true }; return false }
            XCTAssertTrue(saved, "\(lines) 导出 \(model.exportPhase)")
            let jpeg = try XCTUnwrap(decodeJPEG(try XCTUnwrap(harness.library.lastJPEG)))
            let exportCell = jpeg.width / mask.columns
            let exportPixel = pixelFromTop(try bitmap(jpeg), width: jpeg.width, columns: mask.columns,
                                           cellPixels: exportCell, index: inside)
            assertNear(exportPixel, tile, tolerance: 36, label: "\(lines) 导出内格")
            attachRaster(jpeg, name: "jpeg-\(label)")
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// 测试里光栅出的图，不是界面截图，也不证明肉眼可读。
    private func attachRaster(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachMask(_ mask: CellMask, name: String) {
        let w = mask.columns, h = mask.rows
        guard w > 0, h > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for index in 0..<mask.cellCount where mask.isActive(index) {
            ctx.fill(CGRect(x: index % w, y: h - 1 - index / w, width: 1, height: 1))
        }
        guard let image = ctx.makeImage() else { return }
        attachRaster(image, name: "mask-\(name)")
    }

    private struct Harness {
        var root: URL
        var library: MemoryAlbum
        var model: AppModel
    }

    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shape-screen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = MemoryAlbum(count: 24)
        let thumbs = SolidThumbs(r: tile.r, g: tile.g, b: tile.b)
        var config = PhotoIndex.Configuration()
        config.batchSize = 24
        config.maxConcurrentRequests = 8
        config.minRowsPerCommit = 1
        config.minRowsForTimedCommit = 1
        config.commitDutyFactor = 0
        let dependencies = AppDependencies(
            library: library,
            thumbnails: thumbs,
            indexStore: JSONIndexStore(directory: root.appendingPathComponent("Index", isDirectory: true),
                                       backupExclusion: FileBackupExclusion()),
            clock: SystemClock(),
            lifecycle: QuietLifecycle(),
            preferences: OnboardedPreferences(),
            generator: GenerationRunner.production(pipeline: MosaicPipeline(assigner: GreedyAssigner(kernel: KernelProvider.make())),
                                                   perf: nil),
            exporter: LiveMosaicExporter(thumbnails: thumbs),
            memory: NullMemory(),
            perf: PerfRecorder(),
            indexConfiguration: config,
            initialSeed: 7)
        let model = AppModel(buildFlags: BuildFlags(internalTools: true), dependencies: dependencies,
                             detailThumbnails: PhotoKitThumbnails(),
                             worksDirectory: root.appendingPathComponent("Works", isDirectory: true),
                             lifecycle: AppLifecycle(), relay: ExportSuccessRelay())
        model.coordinator.start()
        await model.coordinator.settle()
        return Harness(root: root, library: library, model: model)
    }

    /// 合成库只有 24 张，低于 200 张门槛。界面会先问「照片比较少」，点继续才真正开始。
    private func passShortagePrompt(_ model: AppModel) async {
        if model.flow.generation.shortagePrompt {
            model.send(.shortageContinue)
            return
        }
        _ = await waitUntil(seconds: 5) { model.flow.generation.shortagePrompt }
        if model.flow.generation.shortagePrompt { model.send(.shortageContinue) }
    }

    private func waitUntil(seconds: Double = 90, _ condition: @escaping () -> Bool) async -> Bool {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func pixelFromTop(_ bytes: [UInt8], width: Int, columns: Int, cellPixels: Int, index: Int) -> (UInt8, UInt8, UInt8) {
        let column = index % columns
        let row = index / columns
        let x = column * cellPixels + cellPixels / 2
        let y = row * cellPixels + cellPixels / 2
        let o = y * width * 4 + x * 4
        guard o >= 0, o + 2 < bytes.count else { return (0, 0, 0) }
        return (bytes[o], bytes[o + 1], bytes[o + 2])
    }

    private func assertNear(_ pixel: (UInt8, UInt8, UInt8), _ expected: (r: UInt8, g: UInt8, b: UInt8), tolerance: Int, label: String) {
        for pair in [(pixel.0, expected.r), (pixel.1, expected.g), (pixel.2, expected.b)] {
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

    private func decodeJPEG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

private final class MemoryAlbum: PhotoLibraryClient, @unchecked Sendable {
    enum Write: Sendable { case succeed, fail }
    private let assets: [AssetMetadata]
    private let lock = NSLock()
    private var write = Write.succeed
    private var addOnly = PhotoAuthorization.authorized
    private var successes: [Data] = []
    private var attempts = 0

    init(count: Int) {
        assets = (0..<count).map {
            AssetMetadata(id: "synth-\($0)", modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                          pixelWidth: 800, pixelHeight: 800)
        }
    }

    func setWrite(_ write: Write) { lock.lock(); self.write = write; lock.unlock() }
    func setAddOnly(_ auth: PhotoAuthorization) { lock.lock(); addOnly = auth; lock.unlock() }
    var successCount: Int { lock.lock(); defer { lock.unlock() }; return successes.count }
    var attemptCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    var lastJPEG: Data? { lock.lock(); defer { lock.unlock() }; return successes.last }

    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() async -> PhotoAuthorization { .authorized }
    func assetCount() async -> Int { assets.count }
    func assetMetadata(in range: Range<Int>) async -> [AssetMetadata] {
        let lo = max(0, range.lowerBound), hi = min(assets.count, range.upperBound)
        return lo < hi ? Array(assets[lo..<hi]) : []
    }
    func albums() async -> [AlbumInfo] { [] }
    func assetIDs(inAlbum albumID: String) async throws -> [String] { [] }
    func addOnlyAuthorizationStatus() -> PhotoAuthorization { lock.lock(); defer { lock.unlock() }; return addOnly }
    func requestAddOnlyAuthorization() async -> PhotoAuthorization { addOnlyAuthorizationStatus() }
    func saveImageToLibrary(fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)
        let shouldFail: Bool = {
            lock.lock()
            defer { lock.unlock() }
            attempts += 1
            if write == .succeed { successes.append(data) }
            return write == .fail
        }()
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
    }
}

private struct SolidThumbs: ThumbnailProviding {
    var r: UInt8, g: UInt8, b: UInt8
    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
        }
        guard let tile = try? PixelBuffer(width: 8, height: 8, bytes: bytes) else { return .failed }
        return .image(tile)
    }
}

private struct QuietLifecycle: LifecycleEvents {
    func events() -> AsyncStream<LifecycleEvent> { AsyncStream { _ in } }
    @MainActor func beginBackgroundWork(_ work: BackgroundWork) {}
    @MainActor func endBackgroundWork(_ work: BackgroundWork) {}
}

private struct OnboardedPreferences: PreferenceStore {
    func bool(_ key: PreferenceKey) -> Bool { key == .onboardingCompleted }
    func set(_ value: Bool, for key: PreferenceKey) {}
}

private struct NullMemory: MemoryFootprintReading {
    func physFootprintBytes() -> UInt64? { nil }
}
