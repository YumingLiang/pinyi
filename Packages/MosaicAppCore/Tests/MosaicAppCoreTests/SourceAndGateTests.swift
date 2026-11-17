import XCTest
@testable import MosaicAppCore

final class SourceAndGateTests: XCTestCase {
    func status(total: Int?, available: Int, pending: Int = 0, unavailable: Int = 0, scanning: Bool = false,
                done: Bool = true) -> IndexStatus {
        IndexStatus(assetTotal: total, available: available, pending: pending, unavailableLocal: unavailable, failed: 0,
                    isScanning: scanning, wasInterrupted: false, hasCompletedInitialScan: done)
    }

    func testAllPhotosRowTitleAndCountRule() {
        // 扫描未完成：资产总数「约 N 张」
        let pendingRow = SourceListLogic.allPhotosRow(access: .full, status: status(total: 12345, available: 300, pending: 12000, scanning: true, done: false))
        XCTAssertEqual(pendingRow.titleKey, .sourceListAll)
        XCTAssertEqual(pendingRow.countLine, LocalizedLine(.sourceListCountPending, ["12,345"]))
        // 完成：可用张数「N 张」
        let doneRow = SourceListLogic.allPhotosRow(access: .limited, status: status(total: 12345, available: 12000, unavailable: 345))
        XCTAssertEqual(doneRow.titleKey, .sourceListAllowed, "决定 8")
        XCTAssertEqual(doneRow.countLine, LocalizedLine(.sourceListCount, ["12,000"]))
        XCTAssertTrue(SourceListLogic.showsAddPhotos(access: .limited))
        XCTAssertFalse(SourceListLogic.showsAddPhotos(access: .full))
    }

    func testAlbumRowsHideEmpty() {
        let albums = [AlbumInfo(id: "1", title: "宝宝", assetCount: 300), AlbumInfo(id: "2", title: "空", assetCount: 0),
                      AlbumInfo(id: "3", title: "全在云上", assetCount: 20)]
        let pending = SourceListLogic.albumRows(albums, availableByAlbum: ["1": 10], scanComplete: false)
        XCTAssertEqual(pending.map(\.albumTitle), ["宝宝", "全在云上"])
        XCTAssertEqual(pending[0].countLine, LocalizedLine(.sourceListCountPending, ["300"]))
        let done = SourceListLogic.albumRows(albums, availableByAlbum: ["1": 290], scanComplete: true)
        XCTAssertEqual(done.map(\.albumTitle), ["宝宝"])
        XCTAssertEqual(done[0].countLine, LocalizedLine(.sourceAlbumItemCount, ["290"]))
    }

    func testSourcePickerReconcile() {
        var p = SourcePickerState()
        p.select(.album(id: "x"))
        p.reconcile(with: [SourceRow(selection: .allPhotos, titleKey: .sourceListAll, albumTitle: nil,
                                     countLine: LocalizedLine(.sourceListCount, ["1"]), count: 1)])
        XCTAssertEqual(p.selection, .allPhotos, "相簿不见了：静默回到全部照片（§2f 补充 1，不再弹提示）")
    }

    func testEmptyStates() {
        XCTAssertNil(LibraryEmptyState.evaluate(status(total: nil, available: 0)))
        XCTAssertEqual(LibraryEmptyState.evaluate(status(total: 0, available: 0)), .noPhotos)
        XCTAssertEqual(LibraryEmptyState.evaluate(status(total: 10, available: 0, unavailable: 10)), .notDownloaded)
        XCTAssertNil(LibraryEmptyState.evaluate(status(total: 10, available: 0, pending: 10, scanning: true, done: false)), "扫描中不下结论")
        XCTAssertNil(LibraryEmptyState.evaluate(status(total: 10, available: 3, unavailable: 7)))
        XCTAssertEqual(LibraryEmptyState.completionNotice(status(total: 10, available: 3, unavailable: 7)), .scanSkippedUndownloaded)
        XCTAssertEqual(LibraryEmptyState.notDownloaded.buttonKey, .emptyNotDownloadedRetry)
    }

    func testGenerateGate() {
        XCTAssertEqual(GenerateGate.decide(status: status(total: 0, available: 0), availableInSource: 0, sourceAssetTotal: 0), .emptyState(.noPhotos))
        // 扫描中，可用 < 2000 → 等
        XCTAssertEqual(GenerateGate.decide(status: status(total: 10000, available: 1999, pending: 8001, scanning: true, done: false),
                                           availableInSource: 1999, sourceAssetTotal: 10000), .waitForScan)
        // 渐进可用
        XCTAssertEqual(GenerateGate.decide(status: status(total: 10000, available: 2000, pending: 8000, scanning: true, done: false),
                                           availableInSource: 2000, sourceAssetTotal: 10000), .proceed(available: 2000))
        // 小图库扫完
        XCTAssertEqual(GenerateGate.decide(status: status(total: 150, available: 150), availableInSource: 150, sourceAssetTotal: 150), .proceed(available: 150))
        // 相簿全部未下载
        XCTAssertEqual(GenerateGate.decide(status: status(total: 150, available: 140, unavailable: 10), availableInSource: 0, sourceAssetTotal: 10), .emptyState(.notDownloaded))
    }

    func testScanFlow() {
        var f = ScanFlow()
        f.send(.started(isFirstScan: true, isResuming: true))
        XCTAssertEqual(f.titleKey, .scanResume)
        f.send(.progressed(ScanProgress(processed: 100, total: 5000, availableCount: 1999, skippedUnavailable: 0, isResuming: true)))
        XCTAssertNil(f.progressiveReadyLine)
        XCTAssertEqual(f.progressLine, LocalizedLine(.scanProgress, ["100", "5,000"]))
        f.send(.progressed(ScanProgress(processed: 2100, total: 5000, availableCount: 2000, skippedUnavailable: 0, isResuming: true)))
        XCTAssertEqual(f.progressiveReadyLine, LocalizedLine(.scanProgressiveReady, ["2,000"]))
        XCTAssertEqual(f.send(.cancelTapped), [])
        XCTAssertEqual(f.phase, .confirmingCancel)
        f.send(.cancelDismissed)
        XCTAssertEqual(f.phase, .scanning)
        // 进后台到期 → 暂停；回前台自动继续，不提示
        XCTAssertEqual(f.send(.backgroundExpired), [.cancelScan])
        XCTAssertEqual(f.send(.becameActive), [.startScan])
        XCTAssertEqual(f.titleKey, .scanTitle)
        f.send(.cancelTapped)
        XCTAssertEqual(f.send(.cancelConfirmed), [.cancelScan])
        XCTAssertEqual(f.phase, .stopped)
        XCTAssertTrue(f.canUsePartialAfterStop)
        XCTAssertEqual(f.send(.becameActive), [], "用户主动停止后不自动继续")
    }

    func testMainFlowNavigation() {
        var m = MainFlow(initialSeed: 1)
        m.send(.next)
        XCTAssertEqual(m.step, .target, "没有目标图不能下一步")
        m.send(.targetFailed)
        XCTAssertEqual(m.targetNotice, .targetUnreadable)
        m.send(.targetLoaded)
        XCTAssertEqual(m.targetButtonKey, .targetReplace)
        m.send(.next); m.send(.next)
        XCTAssertEqual(m.step, .settings)
        XCTAssertEqual(m.settings.density, .medium, "默认中档")
        _ = m.generation.send(.startTapped(available: 500))
        _ = m.generation.send(.succeeded(runID: 1, GenerationOutcome(seed: 1, shouldShowShortageNotice: false, cellCount: 4800)))
        m.syncWithGeneration()
        XCTAssertEqual(m.step, .result)
        _ = m.generation.send(.backToSettings)
        m.syncWithGeneration()
        XCTAssertEqual(m.step, .settings)
        m.send(.back)
        XCTAssertEqual(m.step, .source)
    }

    func testSettingsAndTargetPolicy() {
        XCTAssertEqual(GenerationSettings(overlayAlpha: 0.9).overlayAlpha, 0.3)
        XCTAssertEqual(GenerationSettings(overlayAlpha: -1).overlayAlpha, 0)
        XCTAssertEqual(DensityChoice.fine.density.columns, 120)
        XCTAssertEqual(DensityChoice.coarse.titleKey, .densityCoarse)
        XCTAssertTrue(TargetImagePolicy.downsampledSize(width: 4032, height: 3024)! == (2048, 1536))
        XCTAssertTrue(TargetImagePolicy.downsampledSize(width: 100, height: 50)! == (100, 50), "不放大")
        XCTAssertNil(TargetImagePolicy.downsampledSize(width: 0, height: 5))
    }

    func testHiddenEntryTaps() {
        var c = HiddenEntryTapCounter()
        XCTAssertFalse(c.tap(at: 0)); XCTAssertFalse(c.tap(at: 0.5)); XCTAssertFalse(c.tap(at: 1.0))
        XCTAssertFalse(c.tap(at: 3.0), "间隔过长重新计数")
        for t in [3.2, 3.4, 3.6] { XCTAssertFalse(c.tap(at: t)) }
        XCTAssertTrue(c.tap(at: 3.8))
        XCTAssertEqual(c.count, 0)
    }
}
