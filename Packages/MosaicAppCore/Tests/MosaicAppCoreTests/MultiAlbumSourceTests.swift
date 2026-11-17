import XCTest
@testable import MosaicAppCore

/// 相簿多选 + 记住来源（quick-start v1.0 §1a、§2f、验收 9–12；design/photo-picker-v0.1 §6.4）
/// + 按集合取图的 isHidden 后置过滤（多选 PR 合并条件）。
final class MultiAlbumSourceTests: XCTestCase {

    // MARK: 规范化 / 恢复（纯函数）

    func testNormalizing() {
        XCTAssertNil(SourceSelection.albums(normalizing: []), "0 个不允许保存")
        XCTAssertNil(SourceSelection.albums(normalizing: ["", ""]))
        XCTAssertEqual(SourceSelection.albums(normalizing: ["A"]), .album(id: "A"), "只勾 1 个存成单个相簿")
        XCTAssertEqual(SourceSelection.albums(normalizing: ["B", "A", "B"]), .albums(ids: ["B", "A"]), "按勾选顺序、去重")
        XCTAssertEqual(SourceSelection.albums(normalizing: ["A", AlbumEntry.allPhotosID]), .allPhotos, "含全部照片 → 全部照片")
    }

    func testKeepingSelectableDropsSilentlyAndFallsBack() {
        let s = SourceSelection.albums(ids: ["A", "gone", "B"])
        XCTAssertEqual(s.keepingSelectable(["A", "B"]), .albums(ids: ["A", "B"]), "删掉其中一个只少这一个（验收 6）")
        XCTAssertEqual(s.keepingSelectable(["B"]), .album(id: "B"))
        XCTAssertEqual(s.keepingSelectable([]), .allPhotos, "全部失效回到全部照片")
        XCTAssertEqual(SourceSelection.album(id: "X").keepingSelectable([]), .allPhotos)
        XCTAssertEqual(SourceSelection.allPhotos.keepingSelectable([]), .allPhotos)
        XCTAssertEqual(s.albumIDs, ["A", "gone", "B"])
        XCTAssertTrue(SourceSelection.allPhotos.isAllPhotos)
        XCTAssertFalse(s.isAllPhotos)
    }

    func testUnionDedupKeepsFirstOrder() {
        XCTAssertEqual(MaterialUnion.union([["a", "b", "c"], ["b", "c", "d"], []]), ["a", "b", "c", "d"], "并集，不是相加")
        XCTAssertEqual(MaterialUnion.union([]), [])
        XCTAssertEqual(MaterialUnion.union([["x", "x"]]), ["x"])
    }

    // MARK: 记住来源（§1a）

    func testStoreRoundTripAndLegacyFormat() throws {
        let data = InMemoryPreferenceData()
        let store = SourceSelectionStore(backend: data)
        XCTAssertNil(store.load())
        store.save(.albums(ids: ["A", "B"]))
        XCTAssertEqual(store.load(), .albums(ids: ["A", "B"]))
        store.save(.album(id: "A"))
        XCTAssertEqual(store.load(), .album(id: "A"))
        // 旧版本写的单选格式（Swift 合成 Codable）直接能解
        data.setData(Data(#"{"album":{"id":"T"}}"#.utf8), forKey: SourceSelectionStore.key)
        XCTAssertEqual(store.load(), .album(id: "T"))
        data.setData(Data(#"{"allPhotos":{}}"#.utf8), forKey: SourceSelectionStore.key)
        XCTAssertEqual(store.load(), .allPhotos)
        data.setData(Data("garbage".utf8), forKey: SourceSelectionStore.key)
        XCTAssertNil(store.load(), "解不出来按全部照片处理")
        // 只存相簿 ID：JSON 里没有照片 ID
        store.save(.albums(ids: ["A", "B"]))
        let json = String(decoding: data.data(forKey: SourceSelectionStore.key) ?? Data(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"A\"") && json.contains("\"B\""), json)
    }

    // MARK: 勾选（§2f）

    func testDraft() {
        var d = AlbumSelectionDraft(from: .allPhotos)
        XCTAssertEqual(d.ids, [], "从全部照片进列表：一个都不预先勾")
        XCTAssertFalse(d.canFinish)
        XCTAssertNil(d.selection)
        d.toggle("A", selectable: true); d.toggle("B", selectable: true); d.toggle("U", selectable: false)
        XCTAssertEqual(d.ids, ["A", "B"], "打不开的不能勾")
        XCTAssertTrue(d.canFinish)
        XCTAssertEqual(d.selection, .albums(ids: ["A", "B"]))
        d.toggle("A", selectable: true)
        XCTAssertEqual(d.selection, .album(id: "B"))
        d.keep([])
        XCTAssertFalse(d.canFinish)
        XCTAssertEqual(AlbumSelectionDraft(from: .albums(ids: ["X", "Y"])).ids, ["X", "Y"], "从相簿来源进来保留上次的勾选")
    }

    func testTextFormats() {
        XCTAssertEqual(MultiAlbumText.bar(selected: 0, union: nil), LocalizedLine(.sourceSelectionNone, []))
        XCTAssertEqual(MultiAlbumText.bar(selected: 2, union: AlbumUnionCount(count: 1234, pending: false)),
                       LocalizedLine(.sourceSelectionSummary, ["2", "1,234"]))
        XCTAssertEqual(MultiAlbumText.bar(selected: 3, union: AlbumUnionCount(count: 50, pending: true)),
                       LocalizedLine(.sourceSelectionSummaryPending, ["3", "50"]))
        // 验收 7 / 12：1、2、3 个相簿三种格式，名字按勾选顺序
        XCTAssertEqual(MultiAlbumText.materialSummary(names: ["旅行"], count: 300),
                       LocalizedLine(.quickSourceSummary, ["旅行", "300"]))
        XCTAssertEqual(MultiAlbumText.materialSummary(names: ["宝宝", "旅行"], count: 1500),
                       LocalizedLine(.quickSourceSummaryTwo, ["宝宝", "旅行", "1,500"]))
        XCTAssertEqual(MultiAlbumText.materialSummary(names: ["宝宝", "旅行", "猫"], count: 9),
                       LocalizedLine(.quickSourceSummaryMany, ["宝宝", "3", "9"]))
        for k in L10nKey.allMultiAlbum { XCTAssertTrue(L10nKey.allUsed.contains(k), k.rawValue) }
    }

    // MARK: isHidden 后置过滤（合并条件）

    func testVisibleAssetFilterDropsHiddenKeepsOrder() {
        struct A { let id: String; let hidden: Bool }
        let items = [A(id: "1", hidden: false), A(id: "2", hidden: true), A(id: "3", hidden: false), A(id: "4", hidden: true)]
        XCTAssertEqual(VisibleAssetFilter.accepting(items, isHidden: \.hidden).map(\.id), ["1", "3"])
        XCTAssertEqual(VisibleAssetFilter.accepting([A](), isHidden: \.hidden).count, 0)
        XCTAssertEqual(VisibleAssetFilter.accepting([A(id: "h", hidden: true)], isHidden: \.hidden).count, 0)
    }

    func testVisibleIndexMapIdentityWhenNothingHidden() {
        let m = VisibleIndexMap(rawCount: 5, isHidden: { _ in false })
        XCTAssertTrue(m.isIdentity)
        XCTAssertEqual(m.count, 5)
        XCTAssertEqual(m.rawIndex(forVisible: 4), 4)
        XCTAssertNil(m.rawIndex(forVisible: 5))
        XCTAssertEqual(m.visibleIndex(forRaw: 2), 2)
        XCTAssertNil(m.visibleIndex(forRaw: -1))
    }

    func testVisibleIndexMapSkipsHidden() {
        let hidden: Set<Int> = [0, 3, 4, 7]
        let m = VisibleIndexMap(rawCount: 8, isHidden: { hidden.contains($0) })
        XCTAssertFalse(m.isIdentity)
        XCTAssertEqual(m.count, 4)
        XCTAssertEqual((0..<m.count).compactMap { m.rawIndex(forVisible: $0) }, [1, 2, 5, 6])
        XCTAssertEqual(m.visibleIndex(forRaw: 5), 2)
        XCTAssertNil(m.visibleIndex(forRaw: 3), "隐藏项在网格里没有下标")
        XCTAssertNil(m.visibleIndex(forRaw: 8))
        let all = VisibleIndexMap(rawCount: 3, isHidden: { _ in true })
        XCTAssertEqual(all.count, 0)
        XCTAssertNil(all.rawIndex(forVisible: 0))
        XCTAssertEqual(VisibleIndexMap(rawCount: 0, isHidden: { _ in true }).count, 0)
    }

    // MARK: 协调器（真索引、假相册）

    /// 300 张：A = a0..a149，B = a100..a249（重叠 50），C = a0..a29，U 打不开（在列表里但取不到）。
    @MainActor
    private func harness(prefs: InMemoryPreferenceData = InMemoryPreferenceData(), assets: Int = 300,
                         thumbnails: GatedThumbnails = GatedThumbnails()) -> CoordinatorHarness {
        CoordinatorHarness(assets: assets, thumbnails: thumbnails, preferenceData: prefs, configureLibrary: { lib in
            lib.state.update { s in
                s.albums = [AlbumInfo(id: "A", title: "宝宝", assetCount: 150), AlbumInfo(id: "B", title: "旅行", assetCount: 150),
                            AlbumInfo(id: "C", title: "猫", assetCount: 30), AlbumInfo(id: "U", title: "坏的", assetCount: 5)]
                s.albumMembers = ["A": (0..<150).map { "a\($0)" }, "B": (100..<250).map { "a\($0)" },
                                  "C": (0..<30).map { "a\($0)" }]
            }
        })
    }

    @MainActor
    private func ready(_ h: CoordinatorHarness) async {
        let c = h.coordinator
        c.start(); await c.settle()
        await waitFor(c, "扫描完成") { SourceListLogic.isScanComplete($0.indexStatus) }
        await c.refreshAlbums()
    }

    @MainActor
    func testPickTwoOverlappingAlbumsCountsUnionAndPersists() async throws {
        let prefs = InMemoryPreferenceData()
        let h = harness(prefs: prefs)
        let c = h.coordinator
        await ready(h)
        XCTAssertEqual(c.state.albumRows.map(\.albumID), ["A", "B", "C", "U"])
        XCTAssertEqual(c.state.albumRows.last?.isUnreadable, true, "打不开的相簿还在列表里，置灰")

        c.openAlbumList()
        XCTAssertEqual(c.state.flow.source.draft?.ids, [])
        XCTAssertEqual(c.state.flow.source.draftBarLine, LocalizedLine(.sourceSelectionNone, []))
        XCTAssertFalse(c.finishAlbumSelection(), "没勾选「完成」不可点")
        c.toggleAlbum("U")
        XCTAssertEqual(c.state.flow.source.draft?.ids, [], "打不开的不能勾")
        c.toggleAlbum("A"); c.toggleAlbum("B")
        await waitFor(c, "合计") { $0.flow.source.draftUnion?.count == 250 }
        XCTAssertEqual(c.state.flow.source.draftBarLine, LocalizedLine(.sourceSelectionSummary, ["2", "250"]),
                       "去重合计 = 并集 250，不是 300")
        XCTAssertTrue(c.finishAlbumSelection())
        XCTAssertNil(c.state.flow.source.draft)
        XCTAssertEqual(c.state.flow.source.selection, .albums(ids: ["A", "B"]))
        XCTAssertEqual(SourceSelectionStore(backend: prefs).load(), .albums(ids: ["A", "B"]), "记住整组")
        XCTAssertEqual(c.state.materialSummary(allPhotosTitle: "全部照片"),
                       LocalizedLine(.quickSourceSummaryTwo, ["宝宝", "旅行", "250"]))

        c.openAlbumList()
        XCTAssertEqual(c.state.flow.source.draft?.ids, ["A", "B"], "再进列表保留上次的勾选")
        c.toggleAlbum("C")
        XCTAssertTrue(c.finishAlbumSelection())
        await waitFor(c, "三个的合计") { $0.flow.source.selectionUnion?.count == 250 }
        XCTAssertEqual(c.state.materialSummary(allPhotosTitle: "全部照片"),
                       LocalizedLine(.quickSourceSummaryMany, ["宝宝", "3", "250"]))

        c.selectSource(.allPhotos)
        XCTAssertEqual(c.state.flow.source.selection, .allPhotos, "点全部照片清空相簿勾选")
        XCTAssertEqual(SourceSelectionStore(backend: prefs).load(), .allPhotos)
        c.openAlbumList()
        XCTAssertEqual(c.state.flow.source.draft?.ids, [], "从全部照片进来不预先勾")
        c.closeAlbumList()
        XCTAssertEqual(c.state.flow.source.selection, .allPhotos, "关掉列表不改来源")
        c.stop()
    }

    @MainActor
    func testRestoreDropsMissingSilentlyAndFallsBack() async throws {
        let prefs = InMemoryPreferenceData()
        SourceSelectionStore(backend: prefs).save(.albums(ids: ["A", "gone", "U", "B"]))
        let h = harness(prefs: prefs)
        let c = h.coordinator
        XCTAssertEqual(c.state.flow.source.selection, .albums(ids: ["A", "gone", "U", "B"]), "启动即恢复")
        await ready(h)
        XCTAssertEqual(c.state.flow.source.selection, .albums(ids: ["A", "B"]), "删掉的、打不开的静默去掉")
        c.stop()

        let prefs2 = InMemoryPreferenceData()
        SourceSelectionStore(backend: prefs2).save(.albums(ids: ["gone1", "gone2"]))
        let h2 = harness(prefs: prefs2)
        await ready(h2)
        XCTAssertEqual(h2.coordinator.state.flow.source.selection, .allPhotos, "全部失效回到全部照片")
        XCTAssertEqual(SourceSelectionStore(backend: prefs2).load(), .allPhotos)
        h2.coordinator.stop()

        let prefs3 = InMemoryPreferenceData()
        SourceSelectionStore(backend: prefs3).save(.album(id: "gone"))
        let h3 = harness(prefs: prefs3)
        await ready(h3)
        XCTAssertEqual(h3.coordinator.state.flow.source.selection, .allPhotos, "单个记住的相簿没了：静默回全部照片（§1a 验收 2）")
        h3.coordinator.stop()
    }

    @MainActor
    func testAlbumRemovedLaterOnlyDropsThatOne() async throws {
        let h = harness()
        let c = h.coordinator
        await ready(h)
        c.openAlbumList(); c.toggleAlbum("A"); c.toggleAlbum("B"); c.toggleAlbum("C")
        XCTAssertTrue(c.finishAlbumSelection())
        h.library.state.update { s in s.albums.removeAll { $0.id == "B" }; s.albumMembers["B"] = nil }
        await c.refreshAlbums()
        XCTAssertEqual(c.state.flow.source.selection, .albums(ids: ["A", "C"]), "删掉其中一个，只少这一个（验收 6）")
        c.stop()
    }

    /// 200 张门槛按去重合计算（验收 4）；生成用的素材是并集（验收 2）。
    @MainActor
    func testShortageUsesDedupedUnion() async throws {
        let h = harness()
        let c = h.coordinator
        await ready(h)
        c.setTarget(try CoordinatorHarness.target())
        c.openAlbumList(); c.toggleAlbum("A"); c.toggleAlbum("C")   // 并集 150 < 200
        XCTAssertTrue(c.finishAlbumSelection())
        await c.generateTapped()
        XCTAssertTrue(c.state.flow.generation.shortagePrompt, "并集 150 张，弹 shortage")
        c.send(.shortageBack); await c.settle()

        c.openAlbumList(); c.toggleAlbum("C"); c.toggleAlbum("B")    // A ∪ B = 250
        XCTAssertTrue(c.finishAlbumSelection())
        XCTAssertEqual(c.state.flow.source.selection, .albums(ids: ["A", "B"]))
        await c.generateTapped(); await c.settle()
        XCTAssertFalse(c.state.flow.generation.shortagePrompt, "并集 250 张，不弹")
        await waitFor(c, "结果") { if case .result = $0.flow.generation.phase { return true }; return false }
        c.stop()
    }

    @MainActor
    func testSnapshotIsDedupedUnionAndSkipsUnreadable() async throws {
        let h = harness()
        await ready(h)
        let index = h.coordinator.index
        let two = try await index.snapshot(for: .albums(ids: ["A", "B"]))
        XCTAssertEqual(two.library.availableCount, 250, "并集，重叠的那批只算一次")
        let withBad = try await index.snapshot(for: .albums(ids: ["U", "C"]))
        XCTAssertEqual(withBad.library.availableCount, 30, "打不开的相簿跳过")
        do {
            _ = try await index.snapshot(for: .albums(ids: ["U", "gone"]))
            XCTFail("全部打不开要抛 albumUnreadable")
        } catch { XCTAssertEqual(error as? PhotoIndexError, .albumUnreadable) }
        h.coordinator.stop()
    }

    // MARK: 2f 补充（00:15）

    /// 补充 1：本次手动选的单个相簿不见了，也静默去掉回全部照片；来源标签和确认页摘要立即是处理后的结果。
    @MainActor
    func testInSessionSingleAlbumGoneIsSilentAndSummaryUpdates() async throws {
        let h = harness()
        let c = h.coordinator
        await ready(h)
        c.selectSource(.album(id: "C"))
        XCTAssertEqual(c.state.materialSummary(allPhotosTitle: "全部照片"), LocalizedLine(.quickSourceSummary, ["猫", "30"]))
        h.library.state.update { s in s.albums.removeAll { $0.id == "C" }; s.albumMembers["C"] = nil }
        await c.refreshAlbums()
        XCTAssertEqual(c.state.flow.source.selection, .allPhotos)
        XCTAssertFalse(c.state.isMaterialCountLoading)
        XCTAssertEqual(c.state.materialSummary(allPhotosTitle: "全部照片"),
                       LocalizedLine(.quickSourceSummary, ["全部照片", CountFormat.grouped(c.state.allPhotosRow.count)]))

        // 多相簿去掉一个：摘要马上换成剩下的那个（单相簿格式）
        c.openAlbumList(); c.toggleAlbum("A"); c.toggleAlbum("B")
        XCTAssertTrue(c.finishAlbumSelection())
        h.library.state.update { s in s.albums.removeAll { $0.id == "B" }; s.albumMembers["B"] = nil }
        await c.refreshAlbums()
        XCTAssertEqual(c.state.flow.source.selection, .album(id: "A"))
        XCTAssertEqual(c.state.materialSummary(allPhotosTitle: "全部照片"), LocalizedLine(.quickSourceSummary, ["宝宝", "150"]))

        // 列表开着时被选中的那个打不开了（还在列表里）：勾选静默去掉
        c.openAlbumList()
        h.library.state.update { s in s.albumMembers["A"] = nil }
        await c.refreshAlbums()
        XCTAssertEqual(c.state.flow.source.draft?.ids, [])
        XCTAssertEqual(c.state.flow.source.selection, .allPhotos)
        c.stop()
    }

    /// 补充 1：生成前（列表已加载）所选相簿刚被删掉：按 ID 再核对一次，静默去掉后再生成，不拿失效的选择去生成。
    @MainActor
    func testGenerateRechecksSelectionAfterLoad() async throws {
        let h = harness()
        let c = h.coordinator
        await ready(h)
        c.setTarget(try CoordinatorHarness.target())
        c.openAlbumList(); c.toggleAlbum("A"); c.toggleAlbum("B")
        XCTAssertTrue(c.finishAlbumSelection())
        h.library.state.update { s in s.albumMembers["A"] = nil }   // 列表还没刷新
        await c.generateTapped()
        XCTAssertEqual(c.state.flow.source.selection, .album(id: "B"))
        XCTAssertTrue(c.state.flow.generation.shortagePrompt, "只剩 B 的 150 张，按剩下的判断门槛")
        c.stop()
    }

    /// 补充 2：`albums.limited_note` +「增加可用照片」只在受限访问时显示；文案进了 allUsed。
    func testLimitedNoteOnlyWhenLimited() {
        XCTAssertTrue(SourceListLogic.showsAlbumsLimitedNote(access: .limited))
        XCTAssertFalse(SourceListLogic.showsAlbumsLimitedNote(access: .full))
        XCTAssertEqual(L10nKey.albumsLimitedNote.rawValue, "albums.limited_note")
        XCTAssertTrue(L10nKey.allUsed.contains(.albumsLimitedNote))
        XCTAssertTrue(L10nKey.allUsed.contains(.sourceAddPhotos))
    }

    /// 补充 3：启动时相簿列表加载完之前张数是「加载中」；这时点「开始拼图」先等失效相簿去掉再开始，按钮显示加载状态。
    @MainActor
    func testStartBeforeAlbumsLoadedWaitsAndNeverUsesStaleSelection() async throws {
        let prefs = InMemoryPreferenceData()
        SourceSelectionStore(backend: prefs).save(.albums(ids: ["A", "gone", "B"]))
        let gate = GatePoint()
        let h = harness(prefs: prefs)
        h.library.albumsGate.set(gate)
        let c = h.coordinator
        XCTAssertTrue(c.state.isMaterialCountLoading, "启动即恢复，列表没加载：加载中")
        XCTAssertFalse(c.state.albumsLoaded)

        // 记录每次进入「生成中」时的来源
        let seen = Locked<[SourceSelection]>([])
        let waiting = Locked<[Bool]>([])
        let token = c.observe { s in
            waiting.update { $0.append(s.isWaitingForAlbums) }
            if case .running = s.flow.generation.phase { seen.update { $0.append(s.flow.source.selection) } }
        }
        c.start()
        await gate.reached.wait()
        // 扫描本身先做完（扫描结束后的相簿刷新同样停在闸门上），让「开始拼图」只卡在相簿列表上
        await waitFor(c, "扫描完成") { SourceListLogic.isScanComplete($0.indexStatus) }
        XCTAssertFalse(c.state.albumsLoaded)
        XCTAssertTrue(c.state.isMaterialCountLoading, "列表还在加载：不显示旧数字")
        c.setTarget(try CoordinatorHarness.target())
        let tap = Task { await c.generateTapped() }
        await waitFor(c, "按钮加载状态") { $0.isWaitingForAlbums }
        XCTAssertEqual(h.generator.calls.get(), 0, "列表加载完之前不开始")
        XCTAssertEqual(c.state.flow.source.selection, .albums(ids: ["A", "gone", "B"]))
        await gate.release.open()
        await tap.value
        XCTAssertFalse(c.state.isWaitingForAlbums)
        XCTAssertTrue(c.state.albumsLoaded)
        XCTAssertEqual(c.state.flow.source.selection, .albums(ids: ["A", "B"]))
        XCTAssertFalse(c.state.isMaterialCountLoading)
        await c.settle()
        await waitFor(c, "结果") { if case .result = $0.flow.generation.phase { return true }; return false }
        XCTAssertFalse(seen.get().isEmpty)
        XCTAssertTrue(seen.get().allSatisfy { $0 == .albums(ids: ["A", "B"]) }, "\(seen.get())")
        XCTAssertTrue(waiting.get().contains(true))
        c.removeObserver(token)
        c.stop()
    }

    /// 补充 3：恢复的来源全失效：加载完回到全部照片，张数不再是加载中。
    @MainActor
    func testRestoredAllGoneLoadsAtLaunchWithoutAlbumPage() async throws {
        let prefs = InMemoryPreferenceData()
        SourceSelectionStore(backend: prefs).save(.album(id: "gone"))
        let h = harness(prefs: prefs)
        let c = h.coordinator
        XCTAssertTrue(c.state.isMaterialCountLoading)
        c.start(); await c.settle()
        // 没有打开来源页（没人调 refreshAlbums），启动加载也会核对
        await waitFor(c, "相簿已加载") { $0.albumsLoaded }
        XCTAssertEqual(c.state.flow.source.selection, .allPhotos)
        XCTAssertFalse(c.state.isMaterialCountLoading)
        c.stop()
    }

    /// 补充 4：网格的隐藏照片扫描在后台线程做。
    @MainActor
    func testVisibleIndexMapBuildsOffMainThread() async {
        let onMain = Locked<[Bool]>([])
        let m = await VisibleIndexMap.buildInBackground(rawCount: 6) { i in
            onMain.update { $0.append(Thread.isMainThread) }
            return i % 3 == 0
        }
        XCTAssertEqual(m.count, 4)
        XCTAssertEqual(onMain.get().count, 6)
        XCTAssertFalse(onMain.get().contains(true), "isHidden 一次都没在主线程上调")
    }

    // MARK: 2f 补充 3a（00:35）

    /// 「再调一调」期间所选相簿被静默去掉：不算用户改了参数，主按钮仍是「完成」；用户自己改组合才变「开始拼图」。
    @MainActor
    func testSilentPruneDuringAdjustKeepsDone() async throws {
        let h = harness()
        let c = h.coordinator
        await ready(h)
        c.setTarget(try CoordinatorHarness.target())
        c.openAlbumList(); c.toggleAlbum("A"); c.toggleAlbum("B")
        XCTAssertTrue(c.finishAlbumSelection())
        await c.generateTapped(); await c.settle()
        await waitFor(c, "结果") { if case .result = $0.flow.generation.phase { return true }; return false }
        c.send(.backToSettings)
        XCTAssertEqual(c.settingsPrimaryAction, .done)
        h.library.state.update { s in s.albums.removeAll { $0.id == "B" }; s.albumMembers["B"] = nil }
        await c.refreshAlbums()
        XCTAssertEqual(c.state.flow.source.selection, .album(id: "A"), "静默去掉 B")
        XCTAssertEqual(c.settingsPrimaryAction, .done, "静默去掉不算改参数：仍是「完成」")
        c.setOverlayAlpha(0.3)
        XCTAssertEqual(c.settingsPrimaryAction, .done, "只改叠加强度仍是「完成」")
        await c.adjustDoneTapped(); await c.settle()
        XCTAssertEqual(c.state.flow.step, .result, "「完成」回原结果（新来源下次重新生成才生效）")
        c.send(.backToSettings)
        // 生成前按 ID 核对那条路同样不算改参数
        h.library.state.update { s in s.albumMembers["A"] = nil }
        XCTAssertEqual(c.settingsPrimaryAction, .done)
        // 用户自己改组合 →「开始拼图」
        h.library.state.update { s in s.albumMembers["A"] = (0..<150).map { "a\($0)" } }
        await c.refreshAlbums()
        c.openAlbumList(); c.toggleAlbum("C")
        XCTAssertTrue(c.finishAlbumSelection())
        XCTAssertEqual(c.settingsPrimaryAction, .generate)
        c.stop()
    }

    /// 加载完之前：素材标签先显示上次选的相簿名，张数位置「正在统计…」（source.counting）；加载完换成真数。
    @MainActor
    func testCountingSummaryShowsRememberedNames() async throws {
        let prefs = InMemoryPreferenceData()
        let h = harness(prefs: prefs)
        await ready(h)
        h.coordinator.openAlbumList(); h.coordinator.toggleAlbum("A"); h.coordinator.toggleAlbum("B")
        XCTAssertTrue(h.coordinator.finishAlbumSelection())
        XCTAssertEqual(SourceSelectionStore(backend: prefs).loadNames(), ["A": "宝宝", "B": "旅行"], "名字随选择一起记下")
        h.coordinator.stop()

        let h2 = harness(prefs: prefs)   // 第二次打开
        let c = h2.coordinator
        XCTAssertTrue(c.state.isMaterialCountLoading)
        let line = c.state.materialSummary(allPhotosTitle: "全部照片")
        XCTAssertEqual(line, LocalizedLine(.quickSourceSummaryTwo, ["宝宝", "旅行", MultiAlbumText.countingArgument]))
        XCTAssertEqual(MultiAlbumText.resolveCounting(in: "素材：宝宝、旅行 · \(MultiAlbumText.countingArgument) 张", counting: "正在统计…"),
                       "素材：宝宝、旅行 · 正在统计…")
        XCTAssertEqual(MultiAlbumText.resolveCounting(in: "素材：旅行 · 250 张", counting: "正在统计…"), "素材：旅行 · 250 张")
        c.start(); await c.settle()
        await waitFor(c, "相簿已加载") { $0.albumsLoaded && $0.flow.source.selectionUnion != nil }
        XCTAssertEqual(c.state.materialSummary(allPhotosTitle: "全部照片"), LocalizedLine(.quickSourceSummaryTwo, ["宝宝", "旅行", "250"]))

        // 单个相簿同理
        let p3 = InMemoryPreferenceData()
        SourceSelectionStore(backend: p3).save(.album(id: "C"))
        SourceSelectionStore(backend: p3).saveNames(["C": "猫"])
        let h3 = harness(prefs: p3)
        XCTAssertEqual(h3.coordinator.state.materialSummary(allPhotosTitle: "全部照片"),
                       LocalizedLine(.quickSourceSummary, ["猫", MultiAlbumText.countingArgument]))
        XCTAssertTrue(L10nKey.allUsed.contains(.sourceCounting))
        h2.coordinator.stop(); h3.coordinator.stop()
    }

    /// 「加载完」= 相簿列表加载完，不等全量重扫：重扫卡住时，失效相簿也已经去掉、张数不再是「正在统计…」。
    @MainActor
    func testAlbumsLoadedPrunesWithoutWaitingForRescan() async throws {
        let prefs = InMemoryPreferenceData()
        SourceSelectionStore(backend: prefs).save(.albums(ids: ["A", "gone"]))
        let scanGate = GatePoint()
        let h = harness(prefs: prefs, thumbnails: GatedThumbnails(gates: [1: scanGate]))
        let c = h.coordinator
        c.start()
        await scanGate.reached.wait()                       // 全量扫描停在第一张缩略图
        await waitFor(c, "相簿列表加载完") { $0.albumsLoaded }
        XCTAssertFalse(SourceListLogic.isScanComplete(c.state.indexStatus), "扫描还没完")
        XCTAssertEqual(c.state.flow.source.selection, .album(id: "A"), "失效相簿在相簿列表加载完时就去掉")
        XCTAssertEqual(SourceSelectionStore(backend: prefs).load(), .album(id: "A"))
        XCTAssertFalse(c.state.isMaterialCountLoading)
        await scanGate.release.open()
        await c.settle()
        c.stop()
    }
}
