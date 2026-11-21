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
                          fallbacks: [Int: PixelBuffer], into directory: URL) async throws -> WorkImageFile {
            try await inner.writePreview(layout: layout, target: target, overlayAlpha: overlayAlpha, maxLongEdge: maxLongEdge,
                                         fallbacks: fallbacks, into: directory)
        }
        func readImage(at url: URL) async throws -> PixelBuffer { try await inner.readImage(at: url) }
        func writeFallback(_ image: PixelBuffer, into directory: URL) async throws -> WorkImageFile {
            try await inner.writeFallback(image, into: directory)
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
        /// true = 取索引快照时卡住（模拟补格进行中），直到改回 false 或任务被取消。
        let hang: Locked<Bool>
        let snap: Locked<IndexSnapshot?>
        let snapshotCalls = Locked(0)
        let store: FileWorksStore
        let controller: WorksController
        let exporter = RecordingWorkExporter()
        let ids: [String]
        let cols: Int

        @MainActor init(ids: [String], cols: Int, colors: [RGB], index: [(String, RGB)],
                        hang: Bool = false, withTargetCopy: Bool = true) {
            self.ids = ids
            self.cols = cols
            let rows = ids.count / cols
            let t = WorksRematchTests.target(cols: cols, rows: rows, colors: colors)
            images = TargetImages(target: withTargetCopy ? t : nil)
            self.hang = Locked(hang)
            snap = Locked(WorksRematchTests.snapshot(index))
            store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
            let snapBox = snap, calls = snapshotCalls, hangBox = self.hang
            let rematcher = IndexWorkRematcher(snapshot: {
                calls.update { $0 += 1 }
                while hangBox.get() { try await Task.sleep(nanoseconds: 1_000_000) }   // 取消时 sleep 抛 CancellationError
                guard let s = snapBox.get() else { throw WorkRematchError.indexUnavailable }
                return s
            }, existence: existence)
            controller = WorksController(store: store, existence: existence, images: images, rematcher: rematcher)
            controller.exportHandler = exporter
        }

        /// 「杀掉 App 重开」：新建 store / 补格器（新清晰度缓存）/ controller，同一个作品目录和相册。
        @MainActor func relaunched() -> WorksController {
            let snapBox = snap
            let rematcher = IndexWorkRematcher(snapshot: {
                guard let s = snapBox.get() else { throw WorkRematchError.indexUnavailable }
                return s
            }, existence: existence)
            let c = WorksController(store: FileWorksStore(directory: dir, images: images), existence: existence,
                                    images: images, rematcher: rematcher)
            c.exportHandler = exporter
            return c
        }

        func save(target: Bool = true) async throws -> WorkID {
            // 与作品里存的目标图副本一致（App 里预览就是用它叠加的）
            let t = try images.target.get() ?? PixelBuffer(width: 300, height: 200, bytes: [UInt8](repeating: 0, count: 300 * 200 * 4))
            return try await store.save(WorkDraft(layout: sampleLayout(ids, cols: cols), target: target ? t : nil,
                                                  overlayAlpha: 0.15, tier: "uhd", seed: 7, origin: .savedManually)).summary.id
        }
    }

    // 3 × 2：a 蓝、b 红、c 绿 / d 黄、e 青、f 品红
    static let cellColors: [RGB] = [(30, 30, 200), (200, 30, 30), (30, 200, 30), (200, 200, 30), (30, 200, 200), (200, 30, 200)]
    static let workPhotos: [(String, RGB)] = [("a", (30, 30, 200)), ("b", (200, 30, 30)), ("c", (30, 200, 30)),
                                              ("d", (200, 200, 30)), ("e", (30, 200, 200)), ("f", (200, 30, 200))]

    /// 缺图格换成「可见」的最相近照片（一次匹配，不做逐张清晰度探测，架构师 11-17）：更近的隐藏照片被跳过；
    /// 写回布局 + 重画预览，`works.replaced` 计格数，`works.missing` 不出现；重导出用替换后的布局。
    func testMissingCellReplacedByNearestVisiblePhoto() async throws {
        let index = Self.workPhotos + [("hiddenRed", (200, 30, 30)), ("red1", (204, 30, 30)), ("red2", (212, 34, 30)),
                                       ("red3", (235, 60, 60)), ("gray", (128, 128, 128))]
        let h = Harness(ids: ["a", "b", "c", "d", "e", "f"], cols: 3, colors: Self.cellColors, index: index)
        let id = try await h.save()
        await h.controller.start()
        let before = try XCTUnwrap(h.controller.state.summaries.first)

        h.existence.hide("b", "hiddenRed")   // b 在作品里，后来被隐藏；hiddenRed 本来就是隐藏的（索引里还留着）
        await h.controller.open(id)
        await repairOpened(h.controller)
        let expected = sampleLayout(["a", "red1", "c", "d", "e", "f"], cols: 3)
        XCTAssertEqual(h.controller.openedWork?.layout, expected, "最近的 hiddenRed 被隐藏，选下一张可见的 red1")
        XCTAssertFalse(h.controller.openedWork!.layout.cellAssignments.contains { $0.localIdentifier == "hiddenRed" })
        XCTAssertEqual(h.images.inner.state.get().previews, 2, "预览重新生成")
        XCTAssertNotEqual(h.controller.state.opened?.summary.previewURL, before.previewURL)
        XCTAssertEqual(try FakeWorkImages.previewHeader(XCTUnwrap(h.controller.state.opened?.summary.previewURL)),
                       FakeWorkImages.previewBytes(expected))
        XCTAssertNil(h.controller.state.opened?.summary.meta.fallbackFile, "都补上了，没有兜底图")
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
        await repairOpened(h.controller)
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
        await repairOpened(h.controller)
        let layout = try XCTUnwrap(h.controller.openedWork?.layout)
        XCTAssertEqual(layout.cellAssignments[0].localIdentifier, "red2")
        XCTAssertEqual(layout.cellAssignments[1].localIdentifier, "red3", "相邻格不重复，且避开作品里已有的 inWorkRed")
        XCTAssertEqual(Array(layout.cellAssignments[2...].map(\.localIdentifier)), Array(ids[2...]), "其余格子不动")
        XCTAssertEqual(h.controller.state.replacedLine, LocalizedLine(.worksReplaced, ["2"]))
        h.controller.stop()
    }

    /// 找不到替代（候选只有隐藏的）才兜底，按格计入 fallbackCellCount（droppedPhotoCount 照旧）；`works.missing` 显示。
    func testNoAcceptableCandidateLeavesBlankAndCounts() async throws {
        // 索引里除了缺失的 b，只有隐藏的 hiddenRed、hiddenRed2 → 没有一张可见的候选。
        let index: [(String, RGB)] = [("b", (200, 30, 30)), ("hiddenRed", (200, 30, 30)), ("hiddenRed2", (190, 40, 30))]
        let h = Harness(ids: ["a", "b", "c", "d", "e", "f"], cols: 3, colors: Self.cellColors, index: index)
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("b", "hiddenRed", "hiddenRed2")
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.openedWork?.layout,
                       sampleColorLayout(["a", "", "c", "d", "e", "f"], color: CellColor(r: 200, g: 30, b: 30), cols: 3),
                       "b 被隐藏且没有合格候选 → 填目标图这一格的平均色（红），不用旧预览裁切")
        XCTAssertEqual(h.images.inner.state.get().lastFallbacks, [1: .init(r: 200, g: 30, b: 30)], "预览里这一格是目标色")
        XCTAssertNotEqual(FakeWorkImages.color(of: "b"), .init(r: 200, g: 30, b: 30))
        XCTAssertEqual(h.images.inner.state.get().fallbackWrites, 0, "不写进 WorkFallbackImages")
        XCTAssertEqual(h.controller.state.opened?.missingCount, 1)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]))
        XCTAssertNil(h.controller.state.replacedLine)
        let meta = try await h.store.load(id).meta
        XCTAssertEqual(meta.droppedPhotoCount, 1)
        XCTAssertEqual(meta.replacedCellCount, 0)
        XCTAssertEqual(meta.fallbackCellCount, 1)
        XCTAssertEqual(h.images.inner.state.get().previews, 2, "兜底也要重画预览（兜底格不再按 ID 取图）")
        h.controller.stop()
    }

    /// 索引里没有可用照片：留白计数（不是失败）。
    func testEmptyIndexLeavesBlank() async throws {
        let h = Harness(ids: ["a", "b", "c"], cols: 3, colors: Array(Self.cellColors.prefix(3)), index: [])
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("b")
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleColorLayout(["a", "", "c"], color: CellColor(r: 200, g: 30, b: 30), cols: 3))
        let meta = try await h.store.load(id).meta
        XCTAssertEqual(meta.droppedPhotoCount, 1)
        h.controller.stop()
    }

    /// 索引暂时取不到（还没加载完）：不写回、不兜底、不提示，只在 meta 记数；下次打开索引好了再补上（提示一次）。
    func testIndexUnavailableDoesNotRewrite() async throws {
        let h = Harness(ids: ["a", "b", "c", "d", "e", "f"], cols: 3, colors: Self.cellColors,
                        index: Self.workPhotos + [("red2", (212, 34, 30))])
        let saved = h.snap.get()
        h.snap.set(nil)
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("b")
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "b", "c", "d", "e", "f"], cols: 3))
        XCTAssertEqual(h.controller.state.opened?.missingCount, 0, "作品没改写，不提示")
        XCTAssertNil(h.controller.state.missingLine)
        XCTAssertEqual(h.images.inner.state.get().previews, 1)
        h.controller.close()
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertNil(h.controller.state.missingLine, "再开一次也不重复提示")
        let pendingMeta = try await h.store.load(id).meta
        XCTAssertEqual(pendingMeta.missingCount, 1, "没处理的记着（性能页）")
        h.snap.set(saved)
        h.controller.close()
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "red2", "c", "d", "e", "f"], cols: 3))
        XCTAssertEqual(h.controller.state.replacedLine, LocalizedLine(.worksReplaced, ["1"]))
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
        await repairOpened(h.controller)
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.snapshotCalls.get(), 0)
        XCTAssertEqual(h.images.inner.state.get().previews, 1)
        XCTAssertEqual(try Data(contentsOf: metaURL), metaBefore)
        XCTAssertNil(h.controller.state.replacedLine)
        h.controller.stop()
    }

    /// 受限访问：不补格、不改写、不提示（只在 meta 记数）。
    func testLimitedAccessDoesNotRematch() async throws {
        let h = Harness(ids: ["a", "b", "c"], cols: 3, colors: Array(Self.cellColors.prefix(3)),
                        index: Self.workPhotos + [("red2", (212, 34, 30))])
        let id = try await h.save()
        await h.controller.start()
        h.existence.fullAccess.set(false)
        h.existence.hide("b")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "b", "c"], cols: 3))
        XCTAssertEqual(h.controller.state.opened?.missingCount, 0)
        XCTAssertNil(h.controller.state.missingLine)
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
        await c.open(id)
        let task = Task { @MainActor in
            guard let work = c.openedWork else { return }
            _ = await c.reconcileMissing(work)
        }
        while h.snapshotCalls.get() == 0 { await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        await task.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), filesBefore)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(FileWorksStore.metaFileName)), metaBefore)
        XCTAssertEqual(h.images.inner.state.get().previews, 1)
        let disk = try await h.store.load(id)
        XCTAssertEqual(disk.layout, sampleLayout(["a", "b", "c", "d", "e", "f"], cols: 3))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).filter { $0.hasPrefix(".") }, [])

        h.hang.set(false)
        await h.controller.open(id)
        await repairOpened(h.controller)
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
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["x", "red2", "z"], cols: 3))
        h.controller.stop()
    }

    // MARK: 提示只出一次（QA H8 / H8b）

    /// `works.replaced` 只在本次真的换了格子时出一次：同一作品第二次打开、再导出、杀掉 App 重开都不再出。
    func testReplacedNoticeShownOnlyOnce() async throws {
        let h = Harness(ids: ["a", "b", "c", "d", "e", "f"], cols: 3, colors: Self.cellColors,
                        index: Self.workPhotos + [("red2", (212, 34, 30))])
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("b")
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.state.replacedLine, LocalizedLine(.worksReplaced, ["1"]), "第一次：出")
        XCTAssertNil(h.controller.state.missingLine)

        // 第二次打开
        h.controller.close()
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertNil(h.controller.state.replacedLine, "第二次打开：不出")
        XCTAssertNil(h.controller.state.missingLine)

        // 再导出
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertNil(h.controller.state.replacedLine, "再导出：不出")
        XCTAssertNil(h.controller.state.missingLine)
        XCTAssertEqual(h.exporter.calls.last?.0, sampleLayout(["a", "red2", "c", "d", "e", "f"], cols: 3))
        h.controller.stop()

        // 杀掉 App 重开
        let c2 = h.relaunched()
        await c2.start()
        await c2.open(id)
        XCTAssertEqual(c2.openedWork?.layout, sampleLayout(["a", "red2", "c", "d", "e", "f"], cols: 3))
        XCTAssertNil(c2.state.replacedLine, "重开：不出")
        XCTAssertNil(c2.state.missingLine)
        XCTAssertEqual(h.images.inner.state.get().previews, 2, "只在第一次重画过预览")
        c2.stop()
    }

    /// 留白（兜底）的 `works.missing` 同样只出一次：第二次打开、再导出、重开都不出（索引里一直没有可用的替代）。
    func testBlankNoticeShownOnlyOnce() async throws {
        let h = Harness(ids: ["a", "b", "c"], cols: 3, colors: Array(Self.cellColors.prefix(3)),
                        index: [("b", (200, 30, 30)), ("hiddenRed", (204, 30, 30))])   // 能选的只有隐藏的
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("b", "hiddenRed")
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]), "第一次：出")
        XCTAssertNil(h.controller.state.replacedLine)

        h.controller.close()
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertNil(h.controller.state.missingLine, "第二次打开：不出（留白格重找了一次，仍没有，不写回）")
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertNil(h.controller.state.missingLine, "再导出：不出")
        XCTAssertEqual(h.exporter.calls.last?.0, sampleColorLayout(["a", "", "c"], color: CellColor(r: 200, g: 30, b: 30), cols: 3))
        XCTAssertEqual(h.exporter.fallbacks.last, [1: .init(r: 200, g: 30, b: 30)], "导出填同一颜色")
        h.controller.stop()

        let c2 = h.relaunched()
        await c2.start()
        await c2.open(id)
        XCTAssertNil(c2.state.missingLine, "重开：不出")
        XCTAssertNil(c2.state.replacedLine)
        XCTAssertEqual(h.images.inner.state.get().previews, 2)
        c2.stop()
    }

    /// H8（copy v1.3）：缺图轻提示几秒后自动消失，不打断操作；消失后不会再出（只出一次的规则不变）。
    func testCellNoticeAutoDismissesAfterAFewSeconds() async throws {
        let h = Harness(ids: ["a", "b", "c", "d", "e", "f"], cols: 3, colors: Self.cellColors,
                        index: Self.workPhotos + [("red2", (212, 34, 30))])
        let id = try await h.save()
        XCTAssertEqual(h.controller.cellNoticeDuration, .seconds(4), "默认几秒")
        h.controller.cellNoticeDuration = .milliseconds(80)
        await h.controller.start()
        h.existence.hide("b")
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.state.replacedLine, LocalizedLine(.worksReplaced, ["1"]), "出现")
        try await Self.waitUntil { h.controller.state.replacedLine == nil }
        XCTAssertNil(h.controller.state.missingLine)
        XCTAssertEqual(h.controller.state.opened?.id, id, "查看页不受影响")
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "red2", "c", "d", "e", "f"], cols: 3), "作品不回退")
        // 再导出：不再出
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertNil(h.controller.state.replacedLine)
        h.controller.stop()
    }

    /// 留白提示（`works.missing`）同样自动消失；到点前关掉查看页再打开别的不会误清，重开同一张也不再出。
    func testMissingNoticeAutoDismissesAndCloseCancels() async throws {
        let h = Harness(ids: ["a", "b", "c"], cols: 3, colors: Array(Self.cellColors.prefix(3)),
                        index: [("b", (200, 30, 30)), ("hiddenRed", (204, 30, 30))])   // 能选的只有隐藏的
        let id = try await h.save()
        h.controller.cellNoticeDuration = .milliseconds(80)
        await h.controller.start()
        h.existence.hide("b", "hiddenRed")
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]))
        try await Self.waitUntil { h.controller.state.missingLine == nil }
        XCTAssertEqual(h.controller.state.opened?.id, id)
        // 手动收起：没有提示时什么都不变
        let before = h.controller.state.opened
        h.controller.dismissCellNotice()
        XCTAssertEqual(h.controller.state.opened, before)
        h.controller.close()
        XCTAssertNil(h.controller.state.opened)
        h.controller.stop()
    }

    private static func waitUntil(timeout: Duration = .seconds(3), _ cond: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = clock.now + timeout
        while clock.now < deadline {
            if cond() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待超时")
    }

    /// 补格只匹配一次、不请求任何图像：可见性只查一次（所有格子的候选并起来），不探测清晰度；
    /// 隐藏照片（索引里还留着）永远不进补格结果。
    func testRematchIsSingleMatchAndNeverPicksHidden() async throws {
        // 6 格全缺；索引里离每格最近的都是隐藏照片，其次才是可见的
        var index: [(String, RGB)] = []
        for (i, c) in Self.cellColors.enumerated() {
            index.append(("hidden\(i)", c))
            index.append(("ok\(i)", (min(255, c.0 + 12), min(255, c.1 + 12), min(255, c.2 + 12))))
        }
        let ids = ["m0", "m1", "m2", "m3", "m4", "m5"]
        let h = Harness(ids: ids, cols: 3, colors: Self.cellColors, index: index)
        let id = try await h.save()
        await h.controller.start()
        h.existence.hide("m0", "m1", "m2", "m3", "m4", "m5")
        for i in 0..<6 { h.existence.hide("hidden\(i)") }
        let callsBefore = h.existence.calls.get()
        await h.controller.open(id)
        await repairOpened(h.controller)
        let layout = try XCTUnwrap(h.controller.openedWork?.layout)
        XCTAssertEqual(layout.cellAssignments.map(\.localIdentifier), (0..<6).map { "ok\($0)" })
        XCTAssertFalse(layout.cellAssignments.contains { $0.localIdentifier.hasPrefix("hidden") }, "隐藏照片永远不进补格结果")
        XCTAssertEqual(h.existence.calls.get() - callsBefore, 2, "打开时查一次原照片 + 补格查一次候选可见性")
        XCTAssertEqual(h.snapshotCalls.get(), 1, "只取一次索引、只匹配一次")
        XCTAssertEqual(h.images.inner.state.get().imageReads, 0, "补格不读任何图像")
        h.controller.stop()
    }

    /// 之前留白的格子，后来有了合格的相近照片（新照片进了索引）：补上，按 `works.replaced` 出一次，之后不再出。
    func testBlankCellUpgradedLaterNotifiesReplacedOnce() async throws {
        let base: [(String, RGB)] = [("a", (30, 30, 200)), ("c", (30, 200, 30))]
        let h = Harness(ids: ["a", "b", "c"], cols: 3, colors: Array(Self.cellColors.prefix(3)), index: [])
        let id = try await h.save()
        await h.controller.start()
        h.existence.delete("b")   // 删除 → 和隐藏一样填目标色（Q1 取消 4b）
        await h.controller.open(id)
        await repairOpened(h.controller)
        let firstLayout = try XCTUnwrap(h.controller.openedWork?.layout)
        XCTAssertEqual(firstLayout.cellAssignments.map(\.localIdentifier), ["a", "", "c"])
        XCTAssertNotNil(firstLayout.cellAssignments[1].fill)
        XCTAssertFalse(firstLayout.cellAssignments[1].fallback)
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["1"]))
        XCTAssertNil(h.controller.state.opened?.summary.meta.fallbackFile)

        h.snap.set(Self.snapshot(base + [("red2", (212, 34, 30))]))   // 用户新拍了一张、扫描进了索引
        h.controller.close()
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "red2", "c"], cols: 3), "留白格升级成照片")
        XCTAssertEqual(h.controller.state.replacedLine, LocalizedLine(.worksReplaced, ["1"]), "按 works.replaced 出一次")
        XCTAssertNil(h.controller.state.missingLine)
        let meta = try await h.store.load(id).meta
        XCTAssertEqual(meta.replacedCellCount, 1)
        XCTAssertEqual(meta.droppedPhotoCount, 1, "历史累计，不回退")
        XCTAssertEqual(meta.fallbackCellCount, 1, "历史累计，不回退")
        XCTAssertNil(meta.fallbackFile)
        XCTAssertEqual(h.images.inner.state.get().previews, 3)

        h.controller.close()
        await h.controller.open(id)
        await repairOpened(h.controller)
        XCTAssertNil(h.controller.state.replacedLine, "之后不再出")
        h.controller.stop()
        let c2 = h.relaunched()
        await c2.start()
        await c2.open(id)
        XCTAssertNil(c2.state.replacedLine)
        XCTAssertNil(c2.state.missingLine)
        c2.stop()
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
