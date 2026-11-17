import Foundation

/// 相簿多选 + 记住来源（quick-start v1.0 §1a、§2f、验收 12）。判断在这里和 `MultiAlbumSource.swift`（Linux 单测），视图只调方法。
extension AppCoordinator {
    // MARK: 记住来源（§1a）

    private var selectionStore: SourceSelectionStore? { dependencies.preferenceData.map(SourceSelectionStore.init) }

    /// init 时：读上次的来源。相簿还没列出来，先放进去（张数显示「加载中」），第一次 `refreshAlbums` 时静默核对。
    func restoreSourceSelection() {
        guard let store = selectionStore, let saved = store.load(), !saved.isAllPhotos else { return }
        state.rememberedAlbumNames = store.loadNames()
        state.flow.source.select(saved)
    }

    /// 记下当前所选相簿的名字（列表里有的才记），下次启动列表加载完之前显示（§2f 补充 3a）。
    func rememberSelectedAlbumNames() {
        let ids = state.flow.source.selection.albumIDs
        var names: [String: String] = [:]
        for id in ids {
            if let t = state.albumRows.first(where: { $0.albumID == id })?.albumTitle { names[id] = t }
            else if let t = state.rememberedAlbumNames[id] { names[id] = t }
        }
        if names != state.rememberedAlbumNames { state.rememberedAlbumNames = names }
        selectionStore?.saveNames(names)
    }

    /// 来源变了（`state` 的 didSet 调）：存起来。
    func sourceSelectionDidChange() {
        selectionStore?.save(state.flow.source.selection)
        rememberSelectedAlbumNames()
        state.flow.source.selectionUnion = nil
        scheduleUnion(for: state.flow.source.selection.albumIDs, draft: false)
    }

    func reconcileSourceSelection() {
        let old = state.flow.source.selection
        state.flow.source.reconcile(with: [state.allPhotosRow] + state.albumRows)
        silentSelectionPruned(from: old)
    }

    /// 相簿被静默去掉（§2f 补充 3a）：不算用户改了参数。「再调一调」时当前结果的输入按同样的去法更新，
    /// 主按钮保持原状（只改了叠加强度时仍是「完成」）；新的来源等下次重新生成才生效。
    func silentSelectionPruned(from old: SourceSelection) {
        let new = state.flow.source.selection
        guard new != old else { return }
        notePrunedSelectionForProduct(old: old, new: new)
    }

    /// 「开始拼图」/「再试一次」前（§2f 补充 3）：来源是相簿时，绝不拿失效的选择去生成。
    /// - 相簿列表还没加载完：按钮显示加载状态（`isWaitingForAlbums`），等列表加载完、失效相簿静默去掉再继续。
    /// - 已加载：再按 ID 核对一次所选相簿还打得开（加载后才被删 / 隐藏的），打不开的静默去掉。
    func awaitAlbumsBeforeGenerate() async {
        guard !state.flow.source.selection.isAllPhotos else { return }
        if !state.albumsLoaded {
            state.isWaitingForAlbums = true
            defer { state.isWaitingForAlbums = false }
            if let load = albumsLoadTask { await load.value }
            if !state.albumsLoaded { await refreshAlbums() }
        }
        let ids = state.flow.source.selection.albumIDs
        guard !ids.isEmpty else { return }
        var readable: Set<String> = []
        for id in ids where (try? await dependencies.library.assetIDs(inAlbum: id)) != nil { readable.insert(id) }
        if readable.count != ids.count {
            let old = state.flow.source.selection
            state.flow.source.select(old.keepingSelectable(readable))
            silentSelectionPruned(from: old)
            await refreshUnionCounts()
        }
    }

    // MARK: 相簿列表（§2f）

    /// 点「选择相簿」：从全部照片进来一个都不勾；从相簿来源进来保留上次的勾选。
    public func openAlbumList() {
        state.flow.source.draft = AlbumSelectionDraft(from: state.flow.source.selection)
        state.flow.source.draftUnion = nil
        scheduleUnion(for: state.flow.source.draft?.ids ?? [], draft: true)
    }

    /// 点整行切换勾选。打不开的相簿不能勾。
    public func toggleAlbum(_ id: String) {
        guard state.flow.source.draft != nil else { return }
        let selectable = state.albumRows.contains { $0.albumID == id && !$0.isUnreadable }
        state.flow.source.draft?.toggle(id, selectable: selectable)
        scheduleUnion(for: state.flow.source.draft?.ids ?? [], draft: true)
    }

    /// 「完成」：没勾选时不可点（返回 false）；勾了就把来源换成这些相簿，「全部照片」自动取消。
    @discardableResult
    public func finishAlbumSelection() -> Bool {
        guard let draft = state.flow.source.draft, let s = draft.selection else { return false }
        let union = state.flow.source.draftUnion
        state.flow.source.draft = nil
        state.flow.source.draftUnion = nil
        state.flow.source.select(s)
        if let union { state.flow.source.selectionUnion = union }
        return true
    }

    /// 相簿列表被关掉（没点「完成」）：来源不变。
    public func closeAlbumList() {
        state.flow.source.draft = nil
        state.flow.source.draftUnion = nil
        unionTasks["draft"]?.cancel()
    }

    // MARK: 去重合计

    /// 相簿 ID → 当前照片 ID（每次重新取，走 PhotoFetch + isHidden 后置过滤）的并集，打不开的跳过。
    func currentMemberIDs(of albumIDs: [String]) async -> [String] {
        var per: [[String]] = []
        for id in albumIDs {
            if let ids = try? await dependencies.library.assetIDs(inAlbum: id) { per.append(ids) }
        }
        return MaterialUnion.union(per)
    }

    /// 去重合计：扫描完成后 = 并集里可用的张数（减去该来源已知不够清楚的）；之前 = 并集大小（「约」）。
    func unionCount(for albumIDs: [String]) async -> AlbumUnionCount {
        let ids = MaterialUnion.union(albumIDs.compactMap { albumMembers[$0] })
        guard SourceListLogic.isScanComplete(state.indexStatus) else { return AlbumUnionCount(count: ids.count, pending: true) }
        var n = await index.availableCount(assetIDs: ids)
        if let s = SourceSelection.albums(normalizing: albumIDs) { n = max(0, n - state.knownLowResCount(for: s)) }
        return AlbumUnionCount(count: n, pending: false)
    }

    private func scheduleUnion(for albumIDs: [String], draft: Bool) {
        let key = draft ? "draft" : "selection"
        unionTasks[key]?.cancel()
        guard !albumIDs.isEmpty else { return }
        unionTasks[key] = Task { [weak self] in
            guard let self else { return }
            let c = await self.unionCount(for: albumIDs)
            guard !Task.isCancelled else { return }
            if draft {
                guard self.state.flow.source.draft?.ids == albumIDs else { return }
                self.state.flow.source.draftUnion = c
            } else {
                guard self.state.flow.source.selection.albumIDs == albumIDs else { return }
                self.state.flow.source.selectionUnion = c
            }
        }
    }

    /// 相簿列表 / 扫描状态变了：重算两处合计（等算完，测试用 `settle` 也能等到）。
    func refreshUnionCounts() async {
        let sel = state.flow.source.selection.albumIDs
        if !sel.isEmpty {
            let c = await unionCount(for: sel)
            if state.flow.source.selection.albumIDs == sel { state.flow.source.selectionUnion = c }
        }
        if let d = state.flow.source.draft?.ids, !d.isEmpty {
            let c = await unionCount(for: d)
            if state.flow.source.draft?.ids == d { state.flow.source.draftUnion = c }
        }
    }
}
