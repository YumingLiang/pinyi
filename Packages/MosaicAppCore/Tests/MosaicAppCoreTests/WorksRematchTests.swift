import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 4b 缺图补格（hd-export-req-v0.2 F2 / F5；quick-start-req-v0.4 §4.8 5a / 5b，验收 8 / 9）：
/// 作品里原照片取不到（删除或后来被隐藏）的格子，换成本机、可见、清晰度 ≥ 256 px 的最相近照片；
/// 实在找不到才留白并计入 droppedPhotoCount。替换持久（原子写回 + 重画预览），照片恢复后不改回。
@MainActor
final class WorksRematchTests: XCTestCase {
    typealias RGB = (UInt8, UInt8, UInt8)

    static let extractor = MosaicPipeline().sampler.extractor

    static func solid(_ c: RGB, width: Int = 8, height: Int = 8) -> PixelBuffer {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { bytes += [c.0, c.1, c.2, 255] }
        return try! PixelBuffer(width: width, height: height, bytes: bytes)
    }

    /// 300×200 的目标图，按 cols × rows 每格涂一种颜色（与 `sampleLayout` 的 targetSize / targetCrop 一致）。
    static func target(cols: Int, rows: Int, colors: [RGB], width: Int = 300, height: Int = 200) -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colors[(y * rows / height) * cols + (x * cols / width)]
                let o = (y * width + x) * 4
                bytes[o] = c.0; bytes[o + 1] = c.1; bytes[o + 2] = c.2
            }
        }
        return try! PixelBuffer(width: width, height: height, bytes: bytes)
    }

    /// 假索引：每张照片一个纯色特征。
    static func snapshot(_ photos: [(String, RGB)]) -> IndexSnapshot {
        let records = photos.map { try! extractor.extract(from: solid($0.1)) }
        let table = FeatureTable(records: records)
        return IndexSnapshot(library: try! LibrarySnapshot(table: table), assetIDsByRow: photos.map { $0.0 })
    }

    /// 能控制 target 读回内容的假图片：`readTarget` 返回给定像素。
    final class TargetImages: WorkImageEncoding, Sendable {
        let inner = FakeWorkImages()
        let target: Locked<PixelBuffer?>
        init(target: PixelBuffer?) { self.target = Locked(target) }
        func writePreview(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double, maxLongEdge: Int,
                          into directory: URL) async throws -> WorkImageFile {
            try await inner.writePreview(layout: layout, target: target, overlayAlpha: overlayAlpha, maxLongEdge: maxLongEdge, into: directory)
        }
        func writeTarget(_ t: PixelBuffer, maxLongEdge: Int, into directory: URL) async throws -> WorkImageFile {
            try await inner.writeTarget(t, maxLongEdge: maxLongEdge, into: directory)
        }
        func readTarget(at url: URL) async throws -> PixelBuffer {
            _ = try await inner.readTarget(at: url)
            guard let t = target.get() else { throw ExportError.encodingFailed }
            return t
        }
    }

    struct Harness {
        let dir = makeTempDir()
        let images: TargetImages
        let existence = FakeExistence()
        let probe: FakeResolutionProbe
        let snap: Locked<IndexSnapshot?>
        let snapshotCalls = Locked(0)
        let store: FileWorksStore
        let controller: WorksController
        let exporter = RecordingWorkExporter()
        let ids: [String]
        let cols: Int

        @MainActor init(ids: [String], cols: Int, colors: [RGB], index: [(String, RGB)], unusable: Set<String> = [],
                        hang: Bool = false, withTargetCopy: Bool = true) {
            self.ids = ids
            self.cols = cols
            let rows = ids.count / cols
            let t = WorksRematchTests.target(cols: cols, rows: rows, colors: colors)
            images = TargetImages(target: withTargetCopy ? t : nil)
            probe = FakeResolutionProbe(unusable: unusable, hang: hang)
            snap = Locked(WorksRematchTests.snapshot(index))
            store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
            let snapBox = snap, calls = snapshotCalls
            let rematcher = IndexWorkRematcher(snapshot: {
                calls.update { $0 += 1 }
                guard let s = snapBox.get() else { throw WorkRematchError.indexUnavailable }
                return s
            }, existence: existence, sharpness: LocalResolutionChecker(probe: probe))
            controller = WorksController(store: store, existence: existence, images: images, rematcher: rematcher)
            controller.exportHandler = exporter
        }

        func save(target: Bool = true) async throws -> WorkID {
            let t = try PixelBuffer(width: 300, height: 200, bytes: [UInt8](repeating: 0, count: 300 * 200 * 4))
            return try await store.save(WorkDraft(layout: sampleLayout(ids, cols: cols), target: target ? t : nil,
                                                  overlayAlpha: 0.15, tier: "uhd", seed: 7, origin: .savedManually)).summary.id
        }
    }

    // 3 × 2：a 蓝、b 红、c 绿 / d 黄、e 青、f 品红
    static let cellColors: [RGB] = [(30, 30, 200), (200, 30, 30), (30, 200, 30), (200, 200, 30), (30, 200, 200), (200, 30, 200)]
    static let workPhotos: [(String, RGB)] = [("a", (30, 30, 200)), ("b", (200, 30, 30)), ("c", (30, 200, 30)),
                                              ("d", (200, 200, 30)), ("e", (30, 200, 200)), ("f", (200, 30, 200))]

    /// 缺图格换成「可见 + 通过清晰度探测」的最相近照片：更近的隐藏照片、更近的糊照片都被跳过；
    /// 隐藏照片根本不送去探测；写回布局 + 重画预览，`works.replaced` 计格数，`works.missing` 不出现；重导出用替换后的布局。
    func testMissingCellReplacedByNearestSharpVisiblePhoto() async throws {
        let index = Self.workPhotos + [("hiddenRed", (200, 30, 30)), ("blurryRed", (204, 30, 30)), ("red2", (212, 34, 30)),
                                       ("red3", (235, 60, 60)), ("gray", (128, 128, 128))]
        let h = Harness(ids: ["a", "b", "c", "d", "e", "f"], cols: 3, colors: Self.cellColors, index: index, unusable: ["blurryRed"])
        let id = try await h.save()
        await h.controller.start()
        let before = try XCTUnwrap(h.controller.state.summaries.first)

        h.existence.hide("b", "hiddenRed")   // b 在作品里，后来被隐藏；hiddenRed 本来就是隐藏的（索引里还留着）
        await h.controller.open(id)
        let expected = sampleLayout(["a", "red2", "c", "d", "e", "f"], cols: 3)
        XCTAssertEqual(h.controller.openedWork?.layout, expected)
        XCTAssertFalse(h.probe.calls.contains("hiddenRed"), "隐藏照片不送去探测，更不会被选上")
        XCTAssertTrue(h.probe.calls.contains("blurryRed"), "更近的那张被探测出来不够清楚")
        XCTAssertTrue(h.probe.calls.contains("red2"))
        XCTAssertEqual(h.images.inner.state.get().previews, 2, "预览重新生成")
        XCTAssertNotEqual(h.controller.state.opened?.summary.previewURL, before.previewURL)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(h.controller.state.opened?.summary.previewURL)),
                       FakeWorkImages.previewBytes(expected))
        XCTAssertEqual(h.controller.state.replacedLine, LocalizedLine(.worksReplaced, ["1"]))
        XCTAssertNil(h.controller.state.missingLine, "都补上了，不提示缺失")
        XCTAssertEqual(h.images.inner.state.get().targets, 1, "目标图副本不重写")

        let disk = try await FileWorksStore(directory: h.dir, images: h.images).load(id)
        XCTAssertEqual(disk.layout, expected)
        XCTAssertEqual(disk.meta.replacedCellCount, 1)
        XCTAssertEqual(disk.meta.droppedPhotoCount, 0)
        XCTAssertNotNil(disk.targetURL, "target.jpg 不动")

        // 高清重导出：用替换后的布局，没有 b
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.exporter.calls.last?.0, expected)
        XCTAssertEqual(h.images.inner.state.get().previews, 2, "已处理过，不再重画")
        // 再导出成功：自动保存查重命中
        await h.controller.exportSucceeded(layout: expected)
        let count = await h.store.list().count
        XCTAssertEqual(count, 1)

        // 取消隐藏：不改回去
        h.existence.unhide("b")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, expected)
        h.controller.stop()
    }

    /// 优先避开作品里已有的照片和相邻重复：两个相邻缺图格都是红，最近的候选是作品里别处用过的照片 → 依次取 red2、red3。
    func testAvoidsPhotosAlreadyInWorkAndNeighbourRepeats() async throws {
        // 4 × 2：格 0、1 红（缺 m0 m1），格 3 用了 inWorkRed（特征最红，但已在作品里、且不和 0 相邻）
        let colors: [RGB] = [(200, 30, 30), (200, 30, 30), (30, 200, 30), (30, 30, 200),
                             (200, 200, 30), (30, 200, 200), (200, 30, 200), (128, 128, 128)]
        let ids = ["m0", "m1", "g", "inWorkRed", "y", "cy", "mg", "gr"]
        let index: [(String, RGB)] = [("g", (30, 200, 30)), ("inWorkRed", (200, 30, 30)), ("y", (200, 200, 30)),
                                      ("cy", (30, 200, 200)), ("mg", (200, 30, 200)), ("gr", (128, 128, 128)),
                                      ("red2", (210, 34, 30)), ("red3", (225, 45, 40))]
        let h = Harness(ids: ids, cols: 4, colors: colors, index: index)
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("m0", "m1")
        await h.controller.open(id)
        let layout = try XCTUnwrap(h.controller.openedWork?.layout)
        XCTAssertEqual(layout.cellAssignments[0].localIdentifier, "red2")
        XCTAssertEqual(layout.cellAssignments[1].localIdentifier, "red3", "相邻格不重复，且避开作品里已有的 inWorkRed")
        XCTAssertEqual(Array(layout.cellAssignments[2...].map(\.localIdentifier)), Array(ids[2...]), "其余格子不动")
        XCTAssertEqual(h.controller.state.replacedLine, LocalizedLine(.worksReplaced, ["2"]))
        h.controller.stop()
    }

    /// 找不到替代（候选只有隐藏的和糊的）才留白，并计入 droppedPhotoCount；`works.missing` 显示。
    func testNoAcceptableCandidateLeavesBlankAndCounts() async throws {
        let index = Self.workPhotos.filter { $0.0 != "a" && $0.0 != "c" } + [("hiddenRed", (200, 30, 30)), ("blurryRed", (204, 30, 30))]
        // 索引里能选的只有：隐藏的 hiddenRed、糊的 blurryRed，以及作品里的 d e f（也设成糊的）→ 没有一张合格。
        let h = Harness(ids: ["a", "b", "c", "d", "e", "f"], cols: 3, colors: Self.cellColors, index: index,
                        unusable: ["blurryRed", "d", "e", "f"])
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("b", "hiddenRed")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "", "c", "d", "e", "f"], cols: 3))
        XCTAssertEqual(h.controller.state.opened?.missingCount, 1)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]))
        XCTAssertNil(h.controller.state.replacedLine)
        let meta = try await h.store.load(id).meta
        XCTAssertEqual(meta.droppedPhotoCount, 1)
        XCTAssertEqual(meta.replacedCellCount, 0)
        XCTAssertEqual(h.images.inner.state.get().previews, 2, "留白也要重画预览，隐藏照片不能留在旧预览里")
        h.controller.stop()
    }

    /// 索引里没有可用照片：留白计数（不是失败）。
    func testEmptyIndexLeavesBlank() async throws {
        let h = Harness(ids: ["a", "b", "c"], cols: 3, colors: Array(Self.cellColors.prefix(3)), index: [])
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("b")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "", "c"], cols: 3))
        let meta = try await h.store.load(id).meta
        XCTAssertEqual(meta.droppedPhotoCount, 1)
        h.controller.stop()
    }

    /// 索引暂时取不到（还没加载完）：不写回、不留白，只计数；下次打开索引好了再补上。
    func testIndexUnavailableDoesNotRewrite() async throws {
        let h = Harness(ids: ["a", "b", "c", "d", "e", "f"], cols: 3, colors: Self.cellColors,
                        index: Self.workPhotos + [("red2", (212, 34, 30))])
        let saved = h.snap.get()
        h.snap.set(nil)
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("b")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "b", "c", "d", "e", "f"], cols: 3))
        XCTAssertEqual(h.controller.state.opened?.missingCount, 1)
        XCTAssertEqual(h.images.inner.state.get().previews, 1)
        h.snap.set(saved)
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "red2", "c", "d", "e", "f"], cols: 3))
        h.controller.stop()
    }

    /// 没有缺图：不取索引、不探测、不改写。
    func testNoMissingDoesNotTouchIndexOrWork() async throws {
        let h = Harness(ids: ["a", "b", "c"], cols: 3, colors: Array(Self.cellColors.prefix(3)), index: Self.workPhotos)
        let id = try await h.save()
        await h.controller.start()
        let metaURL = h.dir.appendingPathComponent(id.directoryName).appendingPathComponent(FileWorksStore.metaFileName)
        let metaBefore = try Data(contentsOf: metaURL)
        await h.controller.open(id)
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.snapshotCalls.get(), 0)
        XCTAssertEqual(h.probe.calls, [])
        XCTAssertEqual(h.images.inner.state.get().previews, 1)
        XCTAssertEqual(try Data(contentsOf: metaURL), metaBefore)
        XCTAssertNil(h.controller.state.replacedLine)
        h.controller.stop()
    }

    /// 受限访问：不补格、不改写（只计数）。
    func testLimitedAccessDoesNotRematch() async throws {
        let h = Harness(ids: ["a", "b", "c"], cols: 3, colors: Array(Self.cellColors.prefix(3)),
                        index: Self.workPhotos + [("red2", (212, 34, 30))])
        let id = try await h.save()
        await h.controller.start()
        h.existence.fullAccess.set(false)
        h.existence.hide("b")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "b", "c"], cols: 3))
        XCTAssertEqual(h.controller.state.opened?.missingCount, 1)
        XCTAssertEqual(h.snapshotCalls.get(), 0)
        XCTAssertEqual(h.images.inner.state.get().previews, 1)
        h.controller.stop()
    }

    /// 补格中途取消（关掉查看页）：不写回半成品，作品逐字节不变；下次打开照常补上。
    func testCancelDuringRematchWritesNothing() async throws {
        let h = Harness(ids: ["a", "b", "c", "d", "e", "f"], cols: 3, colors: Self.cellColors,
                        index: Self.workPhotos + [("red2", (212, 34, 30))], hang: true)
        let id = try await h.save()
        await h.controller.start()
        let dir = h.dir.appendingPathComponent(id.directoryName)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let metaBefore = try Data(contentsOf: dir.appendingPathComponent(FileWorksStore.metaFileName))
        h.existence.hide("b")

        let c = h.controller
        let task = Task { @MainActor in await c.open(id) }
        while h.probe.calls.isEmpty { await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        await task.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), filesBefore)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(FileWorksStore.metaFileName)), metaBefore)
        XCTAssertEqual(h.images.inner.state.get().previews, 1)
        let disk = try await h.store.load(id)
        XCTAssertEqual(disk.layout, sampleLayout(["a", "b", "c", "d", "e", "f"], cols: 3))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).filter { $0.hasPrefix(".") }, [])

        h.probe.state.update { $0.hang = false }
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "red2", "c", "d", "e", "f"], cols: 3))
        h.controller.stop()
    }

    /// 没有目标图副本（从作品再导出时自动存的那种）：用相邻格照片特征的平均估目标特征。
    func testWithoutTargetCopyUsesNeighbourFeatures() async throws {
        // 3 × 1：x 红、缺、z 红 → 邻居都是红，应选红色候选而不是绿色
        let index: [(String, RGB)] = [("x", (200, 30, 30)), ("z", (200, 30, 30)), ("red2", (212, 34, 30)), ("green", (30, 200, 30))]
        let h = Harness(ids: ["x", "gone", "z"], cols: 3, colors: [(200, 30, 30), (200, 30, 30), (200, 30, 30)],
                        index: index, withTargetCopy: false)
        let id = try await h.save(target: false)
        await h.controller.start()
        h.existence.hide("gone")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["x", "red2", "z"], cols: 3))
        h.controller.stop()
    }

    /// 目标图副本与生成时尺寸不同（被缩小过）：按比例换算格子区域。
    func testCellRegionScalesToTargetCopy() {
        let layout = sampleLayout(["a", "b", "c", "d", "e", "f"], cols: 3)   // 300×200，3×2
        XCTAssertEqual(IndexWorkRematcher.cellRegion(4, layout: layout, targetWidth: 300, targetHeight: 200),
                       PixelRegion(x: 100, y: 100, width: 100, height: 100))
        XCTAssertEqual(IndexWorkRematcher.cellRegion(4, layout: layout, targetWidth: 150, targetHeight: 100),
                       PixelRegion(x: 50, y: 50, width: 50, height: 50))
    }
}
