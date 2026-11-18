import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 作品里用到的照片后来被隐藏（需求 v0.4 §4.8 5a / 5b，验收 8、9；photo-picker-v0.1 §5.1「我的作品」）：
/// 按 ID 取不到 → 和已删除走同一条缺图路径：格子清成缺图格、重导出不含它、预览重新生成并原子写回；没有缺图就不动。
/// 另含作品 manifest 两个可选字段（targetLocalLongSide / overlayDegradeFactor，§6.1）的解码兼容。
@MainActor
final class WorksHiddenPhotoTests: XCTestCase {
    private struct Harness {
        let dir = makeTempDir()
        let images = FakeWorkImages()
        let existence = FakeExistence()
        let store: FileWorksStore
        let controller: WorksController
        let exporter = RecordingWorkExporter()
        let relay = ExportSuccessRelay()

        @MainActor init() {
            store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
            controller = WorksController(store: store, existence: existence, images: images)
            controller.attach(resultContext: {
                WorkResultContext(layout: nil, target: nil, overlayAlpha: 0, tier: nil, resultRevision: 0)
            }, relay: relay)
            controller.exportHandler = exporter
        }

        func saveWork(_ ids: [String], target: PixelBuffer? = nil) async throws -> WorkID {
            try await store.save(WorkDraft(layout: sampleLayout(ids), target: target, overlayAlpha: 0.15, tier: "uhd",
                                           seed: 7, origin: .autoSavedOnExport)).summary.id
        }

        func workDir(_ id: WorkID) -> URL { dir.appendingPathComponent(id.directoryName) }
        func files(_ id: WorkID) throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: workDir(id).path))
        }
        func tempLeftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        }
    }

    /// 验收 8 / 9：隐藏一张已用在作品里的照片 → 打开：那几格清成缺图格、预览重画（新预览里没有它）、列表缩略图跟着换；
    /// 高清重导出的布局里没有它；再导出成功后自动保存命中查重，不多出一份。
    func testHiddenPhotoIsDroppedFromReexportAndPreviewRegenerated() async throws {
        let h = Harness()
        let id = try await h.saveWork(["a", "b", "c", "a", "b", "d"], target: try smallTarget())
        await h.controller.start()
        let before = try XCTUnwrap(h.controller.state.summaries.first)
        XCTAssertEqual(h.images.state.get().previews, 1)

        h.existence.hide("b")
        await h.controller.open(id)
        let cleared = sampleColorLayout(["a", "", "c", "a", "", "d"], color: smallTargetColor)
        XCTAssertEqual(h.controller.openedWork?.layout, cleared,
                       "用到 b 的两格：b 被隐藏、没有候选 → 填目标图这一格的平均色（不用旧预览裁切）")
        XCTAssertEqual(h.images.state.get().previews, 2, "预览重新生成了一次")
        XCTAssertEqual(h.images.state.get().reads, 1, "重画预览时读回目标图副本做叠加")

        // 新预览：内容不含 b，文件名换了，旧预览删掉；查看页和列表都指向新预览（列表缩略图按 previewURL 刷新）
        let opened = try XCTUnwrap(h.controller.state.opened)
        XCTAssertNotEqual(opened.summary.previewURL, before.previewURL)
        let previewData = try FakeWorkImages.previewHeader(opened.summary.previewURL)
        let bColor = FakeWorkImages.color(of: "b")
        let fill = FakeWorkImages.RGB8(r: 200, g: 200, b: 200)
        XCTAssertNotEqual(fill, bColor)
        XCTAssertEqual(previewData, FakeWorkImages.previewBytes(cleared, fallbacks: [1: fill, 4: fill]),
                       "b 的两格填目标平均色，不含旧预览（b）的像素")
        XCTAssertEqual(h.images.state.get().fallbackWrites, 0, "纯色格不写进 WorkFallbackImages")
        XCTAssertGreaterThanOrEqual(h.existence.metadataCalls.get(), 1, "按只读元数据分了原因")
        XCTAssertFalse(String(decoding: previewData, as: UTF8.self).contains(",b,"), "新预览不再按 ID 取 b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: before.previewURL.path), "旧预览（还看得到 b）已删")
        XCTAssertEqual(h.controller.state.summaries.first?.previewURL, opened.summary.previewURL)
        XCTAssertEqual(opened.missingCount, 2, "按格算")
        XCTAssertEqual(h.controller.state.missingLine, LocalizedLine(.worksMissing, ["2"]))
        XCTAssertNil(opened.summary.meta.fallbackFile, "没有兜底图")
        XCTAssertEqual(try h.files(id), [FileWorksStore.metaFileName, FileWorksStore.layoutFileName, "target.jpg",
                                         opened.summary.previewURL.lastPathComponent])
        XCTAssertEqual(try h.tempLeftovers(), [], "临时目录清掉了")

        // 写回磁盘：新进程重开也是处理后的布局、新预览、新指纹
        let reopened = try await FileWorksStore(directory: h.dir, images: h.images).load(id)
        XCTAssertEqual(reopened.layout, cleared)
        XCTAssertEqual(reopened.summary.previewURL, opened.summary.previewURL)
        XCTAssertEqual(reopened.meta.fingerprint, WorkFingerprint.of(cleared), "#17 起指纹是 WorkFingerprint")
        XCTAssertEqual(reopened.meta.droppedPhotoCount, 1)
        XCTAssertEqual(reopened.meta.photoCount, 3)
        XCTAssertEqual(reopened.meta.missingCount, 0, "都处理过了")

        // 高清重导出：布局里没有 b；预览不再重画（已经处理过）
        await h.controller.exportOpenedTapped(purpose: .save)
        let exported = try XCTUnwrap(h.exporter.calls.last?.0)
        XCTAssertEqual(exported, cleared)
        XCTAssertFalse(exported.cellAssignments.contains { $0.localIdentifier == "b" })
        XCTAssertEqual(h.exporter.calls.last?.1, true)
        XCTAssertEqual(h.exporter.fallbacks.last, [1: fill, 4: fill], "重导出填同一颜色（与预览一致）")
        XCTAssertEqual(h.exporter.fallbacks.last, h.images.state.get().lastFallbacks)
        XCTAssertEqual(h.images.state.get().previews, 2)

        // 再导出成功 → 自动保存按新指纹查重命中
        await h.controller.exportSucceeded(layout: exported)
        let count = await h.store.list().count
        XCTAssertEqual(count, 1, "处理后的作品再导出不重复保存")
        h.controller.stop()
    }

    /// 没有缺图：打开、导出都不重画预览，作品文件逐字节不变。
    func testNoMissingPhotoLeavesPreviewUntouched() async throws {
        let h = Harness()
        let id = try await h.saveWork(["a", "b", "c"], target: try smallTarget())
        await h.controller.start()
        let summary = try XCTUnwrap(h.controller.state.summaries.first)
        let metaBefore = try Data(contentsOf: h.workDir(id).appendingPathComponent(FileWorksStore.metaFileName))
        let previewBefore = try Data(contentsOf: summary.previewURL)

        await h.controller.open(id)
        await h.controller.exportOpenedTapped(purpose: .share)
        await h.controller.open(id)
        XCTAssertEqual(h.images.state.get().previews, 1, "预览没重画")
        XCTAssertEqual(h.controller.state.opened?.summary.previewURL, summary.previewURL)
        XCTAssertEqual(h.controller.state.opened?.missingCount, 0)
        XCTAssertNil(h.controller.state.missingLine)
        XCTAssertEqual(h.exporter.calls.first?.0, sampleLayout(["a", "b", "c"]))
        XCTAssertEqual(try Data(contentsOf: h.workDir(id).appendingPathComponent(FileWorksStore.metaFileName)), metaBefore)
        XCTAssertEqual(try Data(contentsOf: summary.previewURL), previewBefore)
        h.controller.stop()
    }

    /// 5b：取消隐藏后作品不改回去（和删除后恢复一致），也不再重画。导出前才隐藏的照片同样在导出前处理掉。
    func testUnhideDoesNotRevertAndHideBeforeExportIsHandled() async throws {
        let h = Harness()
        let id = try await h.saveWork(["a", "b", "c"])
        await h.controller.start()
        await h.controller.open(id)
        XCTAssertEqual(h.images.state.get().previews, 1)

        h.existence.hide("c")   // 查看页开着时去「照片」App 隐藏
        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.exporter.calls.last?.0, sampleColorLayout(["a", "b", ""], color: MissingCellFill.neutral))
        XCTAssertEqual(h.images.state.get().previews, 2)

        h.existence.unhide("c")
        h.controller.close()
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleColorLayout(["a", "b", ""], color: MissingCellFill.neutral), "取消隐藏后不改回去")
        XCTAssertEqual(h.controller.state.opened?.missingCount, 0, "没有新变化，不再提示")
        XCTAssertEqual(h.images.state.get().previews, 2)
        h.controller.stop()
    }

    /// 其他作品不受影响：没用到这张照片的作品不动；用到它的作品要打开时才处理。
    func testOtherWorksUntouched() async throws {
        let h = Harness()
        let withB = try await h.saveWork(["a", "b", "c"])
        let withoutB = try await h.saveWork(["x", "y", "z"])
        let alsoB = try await h.saveWork(["b", "q", "r"])
        await h.controller.start()
        h.existence.hide("b")

        await h.controller.open(withoutB)
        XCTAssertEqual(h.images.state.get().previews, 3)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["x", "y", "z"]))
        await h.controller.open(withB)
        XCTAssertEqual(h.images.state.get().previews, 4)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleColorLayout(["a", "", "c"], color: MissingCellFill.neutral))
        let untouched = try await h.store.load(alsoB)
        XCTAssertEqual(untouched.layout, sampleLayout(["b", "q", "r"]))
        h.controller.stop()
    }

    /// 受限访问 / 无权限：没选进来的照片也取不到，不能当成被删 / 被隐藏——不改作品、**不提示**（每次打开都不出），
    /// 没处理的缺失数只记在 meta.missingCount（性能页）；导出时这些格子拿不准原因、按隐藏处理：临时填目标平均色，不出白格、不存盘。
    func testLimitedAccessOnlyCountsAndDoesNotRewrite() async throws {
        let h = Harness()
        let id = try await h.saveWork(["a", "b", "c"])
        await h.controller.start()
        h.existence.fullAccess.set(false)
        h.existence.hide("a", "b", "c")
        for _ in 0..<2 {
            await h.controller.open(id)
            XCTAssertEqual(h.controller.state.opened?.missingCount, 0, "作品没改写，不提示")
            XCTAssertNil(h.controller.state.missingLine)
            XCTAssertNil(h.controller.state.replacedLine)
            h.controller.close()
        }
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleLayout(["a", "b", "c"]))
        XCTAssertEqual(h.images.state.get().previews, 1)
        let onDisk = try await h.store.load(id)
        XCTAssertEqual(onDisk.layout, sampleLayout(["a", "b", "c"]))
        XCTAssertEqual(onDisk.meta.droppedPhotoCount, 0)
        XCTAssertEqual(onDisk.meta.missingCount, 3, "没处理的缺失数记着（性能页）")
        let filesBefore = try h.files(id)

        await h.controller.exportOpenedTapped(purpose: .save)
        XCTAssertEqual(h.exporter.calls.last?.0, sampleLayout(["a", "b", "c"]), "布局不改（自动保存查重照样命中）")
        let gray = FakeWorkImages.RGB8(r: 128, g: 128, b: 128)
        XCTAssertEqual(h.exporter.fallbacks.last, [0: gray, 1: gray, 2: gray],
                       "受限访问拿不准是隐藏还是删除 → 按隐藏处理：导出临时填目标平均色（这里没有目标图副本，中性灰），不用当前预览裁切")
        XCTAssertNil(h.controller.state.missingLine)
        XCTAssertEqual(try h.files(id), filesBefore, "临时兜底不存盘")
        XCTAssertEqual(h.images.state.get().fallbackWrites, 0)
        h.controller.stop()
    }

    /// 重画预览失败（如空间不够）：作品原样保留、不留临时文件，提示照常；下次打开再试。
    func testPreviewFailureKeepsWorkIntact() async throws {
        let h = Harness()
        let id = try await h.saveWork(["a", "b", "c"])
        await h.controller.start()
        let before = try await h.store.load(id)
        h.images.state.update { $0.failAt = .preview }
        h.existence.hide("b")
        await h.controller.open(id)
        XCTAssertEqual(h.controller.state.opened?.missingCount, 0, "没写回成功，作品没变，不提示")
        let after = try await h.store.load(id)
        XCTAssertEqual(after.layout, before.layout)
        XCTAssertEqual(after.summary.previewURL, before.summary.previewURL)
        XCTAssertEqual(try h.files(id), [FileWorksStore.metaFileName, FileWorksStore.layoutFileName, "preview.jpg"])
        XCTAssertEqual(try h.tempLeftovers(), [])

        h.images.state.update { $0.failAt = nil }
        await h.controller.open(id)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleColorLayout(["a", "", "c"], color: MissingCellFill.neutral))
        XCTAssertEqual(h.controller.state.opened?.missingCount, 1, "这次真的兜底了，提示一次")
        h.controller.stop()
    }

    /// 打开和导出前同时触发：同一作品串行，只处理一次。
    func testConcurrentDropsAreSerialized() async throws {
        let h = Harness()
        let id = try await h.saveWork(["a", "b", "c"])
        let store = h.store
        async let first = store.dropMissingPhotos(["b"], for: id)
        async let second = store.dropMissingPhotos(["b"], for: id)
        let (w1, w2) = try await (first, second)
        XCTAssertEqual(w1.layout, sampleColorLayout(["a", "", "c"], color: MissingCellFill.neutral))
        XCTAssertEqual(w2.layout, sampleColorLayout(["a", "", "c"], color: MissingCellFill.neutral))
        XCTAssertEqual(h.images.state.get().previews, 2, "第二次发现没东西可去，不再重画")
        let meta = try await store.load(id).meta
        XCTAssertEqual(meta.droppedPhotoCount, 1)
        XCTAssertEqual(try h.files(id).filter { $0.hasPrefix("preview") }.count, 1, "只剩一份预览")
    }

    /// 老版本（本改动之前）存的作品：没有新字段、预览叫 preview.jpg、指纹为空，同样能处理。
    func testLegacyWorkWithHiddenPhoto() async throws {
        let h = Harness()
        let legacyID = WorkID()
        let legacyDir = h.workDir(legacyID)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try FileWorksStore.encoder().encode(sampleLayout(["m", "n", "o"])).write(to: legacyDir.appendingPathComponent("layout.json"))
        try Data("P".utf8).write(to: legacyDir.appendingPathComponent("preview.jpg"))
        let legacyMeta = #"{"formatVersion":1,"id":"\#(legacyID.directoryName)","createdAt":1000,"columns":3,"rows":1,"missingCount":1}"#
        try Data(legacyMeta.utf8).write(to: legacyDir.appendingPathComponent("meta.json"))
        await h.controller.start()
        h.existence.hide("n")
        await h.controller.open(legacyID)
        XCTAssertEqual(h.controller.openedWork?.layout, sampleColorLayout(["m", "", "o"], color: MissingCellFill.neutral),
                       "隐藏 → 填色（没有目标图副本时中性灰）")
        XCTAssertEqual(h.controller.state.opened?.missingCount, 1, "旧 meta 里记的缺失数不重复累计")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir.appendingPathComponent("preview.jpg").path))
        h.controller.stop()
    }

    func testClearingAssetsCountsUniquePhotosAndKeepsCrop() {
        var layout = sampleLayout(["a", "b", "a", "c", "", "b"])
        layout.cellAssignments[2].crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let (out, dropped) = layout.clearingAssets(["a", "zzz"])
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(out.cellAssignments.map(\.localIdentifier), ["", "b", "", "c", "", "b"])
        XCTAssertEqual(out.cellAssignments[2].crop, CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        XCTAssertEqual(layout.clearingAssets([]).droppedPhotos, 0)
        XCTAssertEqual(layout.clearingAssets(["zzz"]).layout, layout)
    }

    // MARK: manifest 新字段（photo-picker-v0.1 §6.1）

    /// 旧 meta（没有新字段）解码缺省为 nil / 0。
    func testLegacyMetaDecodesNewFieldsAsNil() throws {
        let id = WorkID()
        let json = #"{"formatVersion":1,"id":"\#(id.directoryName)","createdAt":1000,"columns":3,"rows":1,"overlayAlpha":0.2}"#
        let meta = try FileWorksStore.decoder().decode(WorkMeta.self, from: Data(json.utf8))
        XCTAssertNil(meta.targetLocalLongSide)
        XCTAssertNil(meta.overlayDegradeFactor)
        XCTAssertEqual(meta.droppedPhotoCount, 0)
        // nil 不写出字段（旧版 App 读新文件也不受影响）
        let out = String(decoding: try FileWorksStore.encoder().encode(meta), as: UTF8.self)
        XCTAssertFalse(out.contains("targetLocalLongSide"))
        XCTAssertFalse(out.contains("overlayDegradeFactor"))
    }

    /// 新字段往返；作品被改写（缺图处理、改缺失数）时保留。
    func testNewMetaFieldsRoundTripAndSurviveRewrites() async throws {
        var meta = WorkMeta(id: WorkID(), createdAt: Date(timeIntervalSince1970: 1000), columns: 3, rows: 1, tier: "uhd",
                            photoCount: 3, missingCount: 0, overlayAlpha: 0.2, seed: 7, fingerprint: "f", origin: .savedManually,
                            previewFile: "preview.jpg", previewPixelWidth: 30, previewPixelHeight: 10, targetFile: nil,
                            targetLocalLongSide: 812, overlayDegradeFactor: 0.6875)
        let decoded = try FileWorksStore.decoder().decode(WorkMeta.self, from: FileWorksStore.encoder().encode(meta))
        XCTAssertEqual(decoded, meta)
        XCTAssertEqual(decoded.targetLocalLongSide, 812)
        XCTAssertEqual(decoded.overlayDegradeFactor, 0.6875)

        // 写进一个已存的作品，再经 setMissingCount / dropMissingPhotos 改写，字段还在
        let h = Harness()
        let id = try await h.saveWork(["a", "b", "c"])
        let metaURL = h.workDir(id).appendingPathComponent(FileWorksStore.metaFileName)
        meta = try FileWorksStore.decoder().decode(WorkMeta.self, from: Data(contentsOf: metaURL))
        meta.targetLocalLongSide = 812
        meta.overlayDegradeFactor = 0.6875
        try FileWorksStore.encoder().encode(meta).write(to: metaURL, options: .atomic)
        try await h.store.setMissingCount(1, for: id)
        _ = try await h.store.dropMissingPhotos(["b"], for: id)
        let after = try await FileWorksStore(directory: h.dir, images: h.images).load(id).meta
        XCTAssertEqual(after.targetLocalLongSide, 812)
        XCTAssertEqual(after.overlayDegradeFactor, 0.6875)
        XCTAssertEqual(after.droppedPhotoCount, 1)
    }
}
