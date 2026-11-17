import Foundation
import MosaicCore

/// 「存到我的作品」按钮状态（结果页，需求 B2）。
public enum WorkSaveStatus: Sendable, Hashable {
    case idle
    case saving
    /// 当前结果已在库里（手动存过或导出时自动存过；重复点只存一份）。
    case saved(WorkID)
    case failed
}

/// 打开中的作品（查看页）。
public struct OpenedWork: Sendable, Hashable {
    public var summary: WorkSummary
    /// 缺失的原照片数；nil = 还在检查。
    public var missingCount: Int?
    public var id: WorkID { summary.id }
    public init(summary: WorkSummary, missingCount: Int?) {
        self.summary = summary
        self.missingCount = missingCount
    }
}

/// 作品相关的全部可观察状态（值类型）。
public struct WorksState: Sendable, Hashable {
    /// 按保存时间倒序。
    public var summaries: [WorkSummary] = []
    public var isLoaded = false
    public var opened: OpenedWork?
    /// 删除二次确认弹窗（`works.delete.confirm`）对应的作品。
    public var pendingDelete: WorkID?
    public var saveStatus: WorkSaveStatus = .idle
    /// 打开 / 删除失败等一次性提示。
    public var notice: L10nKey?

    public init() {}

    public var count: Int { summaries.count }
    public var isEmpty: Bool { isLoaded && summaries.isEmpty }
    /// 列表底部常驻提示（需求 B8）。
    public static let keepHintKey = L10nKey.worksKeepHint
    /// 查看页 / 导出前的缺失提示（`works.missing`，参数：张数）。
    public var missingLine: LocalizedLine? {
        guard let n = opened?.missingCount, n > 0 else { return nil }
        return LocalizedLine(.worksMissing, [CountFormat.grouped(n)])
    }
    /// 查看页 / 导出前：原照片不在了、已换成相近照片的格数（`works.replaced`，参数：格数；累计，检查完才显示）。
    public var replacedLine: LocalizedLine? {
        guard let o = opened, o.missingCount != nil, o.summary.meta.replacedCellCount > 0 else { return nil }
        return LocalizedLine(.worksReplaced, [CountFormat.grouped(o.summary.meta.replacedCellCount)])
    }
}

/// 导出成功事件中继：`AppDependencies.onExportSucceeded` 在协调器之前就要给出，用它把事件转给 `WorksController`。
/// （`AsyncStream` 只有一个消费者：`WorksController.attach`。）
public final class ExportSuccessRelay: Sendable {
    public struct Event: Sendable {
        public var layout: MosaicLayout
        public var fileURL: URL
    }
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    public init() { (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded) }

    /// 交给 `AppDependencies(onExportSucceeded:)`。只入队、立即返回，不拖慢导出收尾。
    public var handler: @Sendable (MosaicLayout, URL) async -> Void {
        { [continuation] layout, url in continuation.yield(Event(layout: layout, fileURL: url)) }
    }

    public func finish() { continuation.finish() }
}

/// 结果页的现状（手动保存 / 自动保存都从这里取目标图、叠加强度、档位）。
public struct WorkResultContext: Sendable {
    public var layout: MosaicLayout?
    public var target: PixelBuffer?
    public var overlayAlpha: Double
    public var tier: String?
    public var resultRevision: Int
    public init(layout: MosaicLayout?, target: PixelBuffer?, overlayAlpha: Double, tier: String?, resultRevision: Int) {
        self.layout = layout
        self.target = target
        self.overlayAlpha = overlayAlpha
        self.tier = tier
        self.resultRevision = resultRevision
    }
}

/// 从作品再导出：由导出线（`AppCoordinator`）实现——按保存的显式布局导出，不重跑匹配。
@MainActor
public protocol WorkExportHandling: AnyObject {
    func exportWork(layout: MosaicLayout, target: PixelBuffer?, purpose: ExportPurpose) async
}

/// 「我的作品」编排（需求 B / F1-3；design/works-storage-v0.1）：自动保存、手动保存、列表、打开、缺失检测、删除确认、再导出。
///
/// - 自动保存只由「导出成功」触发（`ExportSuccessRelay`）；「换一种拼法」不触发保存（它只出新结果，`resultRevision` 变了，
///   按钮状态回到 `.idle`）。
/// - 同一布局只存一份：存储层按布局指纹查重；从作品再导出成功后再次触发自动保存也不会重复。
/// - 缺失原照片（删除或后来被隐藏）：打开 / 导出前批量查一次，用本机相近照片补格（4b，`MissingCellRematching`）并重画预览
///   （`reconcileMissing`），提示 `works.replaced`；找不到替代的留白，提示 `works.missing`。不用预览图放大补（F 节作废）。
@MainActor
public final class WorksController {
    public let store: any WorksStore
    public let existence: any PhotoExistenceChecking
    public let images: any WorkImageEncoding
    /// 4b 补格（App 里是 `IndexWorkRematcher`）；nil = 缺图格留白。
    public let rematcher: (any MissingCellRematching)?
    /// 最近一次补格的附注（内部性能页；不含照片 ID）。
    public private(set) var lastRematchNote: String?
    /// 从作品再导出的执行方（App 里是包着 AppCoordinator 的桥，桥内弱引用协调器，这里强持有不成环）。
    public var exportHandler: (any WorkExportHandling)?

    public private(set) var state = WorksState() {
        didSet { if state != oldValue { notify() } }
    }
    /// 打开中作品的显式布局（不放进 state：体积大）。
    public private(set) var openedWork: Work?

    private var resultContext: @MainActor () -> WorkResultContext
    private var observers: [UUID: @MainActor (WorksState) -> Void] = [:]
    private var relayTask: Task<Void, Never>?
    private var lastRevision: Int?
    private var openToken = 0

    public init(store: any WorksStore, existence: any PhotoExistenceChecking, images: any WorkImageEncoding,
                rematcher: (any MissingCellRematching)? = nil,
                resultContext: @escaping @MainActor () -> WorkResultContext = {
                    WorkResultContext(layout: nil, target: nil, overlayAlpha: 0, tier: nil, resultRevision: 0)
                }) {
        self.store = store
        self.existence = existence
        self.images = images
        self.rematcher = rematcher
        self.resultContext = resultContext
    }

    // MARK: 观察

    @discardableResult
    public func observe(_ handler: @escaping @MainActor (WorksState) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(state)
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        let s = state
        for h in observers.values { h(s) }
    }

    // MARK: 接线

    /// 接上结果页现状来源与导出成功事件。
    public func attach(resultContext: @escaping @MainActor () -> WorkResultContext, relay: ExportSuccessRelay) {
        self.resultContext = resultContext
        relayTask?.cancel()
        let events = relay.events
        relayTask = Task { [weak self] in
            for await e in events {
                guard let self else { return }
                await self.exportSucceeded(layout: e.layout)
            }
        }
    }

    /// 启动：清掉上次被杀留下的半截目录，再读列表。
    public func start() async {
        await store.removeIncomplete()
        await reload()
    }

    public func reload() async {
        let list = await store.list()
        state.summaries = list
        state.isLoaded = true
    }

    /// 结果变了（新生成 / 换一种拼法）：按钮回到「存到我的作品」。平台层在 `resultRevision` 变化时调。
    public func resultDidChange(revision: Int) {
        guard revision != lastRevision else { return }
        lastRevision = revision
        state.saveStatus = .idle
    }

    // MARK: 保存

    /// 结果页「存到我的作品」。重复点只存一份。
    public func saveCurrentResultTapped() async {
        if case .saving = state.saveStatus { return }
        let ctx = resultContext()
        guard let layout = ctx.layout else { return }
        await save(WorkDraft(layout: layout, target: ctx.target, overlayAlpha: ctx.overlayAlpha, tier: nil,
                             seed: layout.params.seed, origin: .savedManually), revision: ctx.resultRevision, showsStatus: true)
    }

    /// 导出成功（结果页或作品页）：自动存一份；已存在则不重复。
    public func exportSucceeded(layout: MosaicLayout) async {
        let ctx = resultContext()
        // 目标图：导出的是当前结果就用当前目标图；从作品再导出时，库里已有这份布局（查重直接命中，不会用到目标图）
        // 比较格子分配（不比参数：导出后又拖了叠加滑杆，也仍是这张结果）
        let isCurrent = ctx.layout.map { $0.cols == layout.cols && $0.rows == layout.rows && $0.cellAssignments == layout.cellAssignments } ?? false
        let target = isCurrent ? ctx.target : nil
        await save(WorkDraft(layout: layout, target: target, overlayAlpha: layout.params.overlayAlpha,
                             tier: isCurrent ? ctx.tier : nil, seed: layout.params.seed, origin: .autoSavedOnExport),
                   revision: isCurrent ? ctx.resultRevision : nil, showsStatus: isCurrent)
    }

    private func save(_ draft: WorkDraft, revision: Int?, showsStatus: Bool) async {
        if showsStatus { state.saveStatus = .saving }
        let store = self.store
        do {
            let (summary, inserted) = try await store.save(draft)
            if inserted { await reload() }
            if showsStatus, revision == nil || revision == resultContext().resultRevision { state.saveStatus = .saved(summary.id) }
        } catch {
            if showsStatus { state.saveStatus = .failed }
        }
    }

    // MARK: 查看

    /// 打开作品：读布局，再批量查一次原照片还在不在；取不到的（删除或后来被隐藏）按缺图处理，见 `reconcileMissing`。
    public func open(_ id: WorkID) async {
        openToken += 1
        let token = openToken
        do {
            let work = try await store.load(id)
            guard token == openToken else { return }
            openedWork = work
            state.opened = OpenedWork(summary: work.summary, missingCount: nil)
            guard let (updated, missing) = await reconcileMissing(work) else { return }
            guard token == openToken, state.opened?.id == id else { return }
            await apply(updated, missing: missing)
        } catch {
            guard token == openToken else { return }
            state.notice = .worksOpenFailed
            await reload()
        }
    }

    public func close() {
        openToken += 1
        openedWork = nil
        state.opened = nil
    }

    public func dismissNotice() { state.notice = nil }

    /// 缺失的原照片张数（去重后）。
    public func missingCount(_ layout: MosaicLayout) async -> Int {
        await missingAssetIDs(layout).count
    }

    /// 布局里取不到的原照片 ID。App 的 `PhotoExistenceChecking` 不含隐藏照片，所以后来被隐藏的和已删除的一样算缺失
    /// （需求 v0.4 §4.8 5a：App 分不清、也不开能看到隐藏照片的查询）。
    func missingAssetIDs(_ layout: MosaicLayout) async -> Set<String> {
        let ids = layout.uniqueAssetIDs
        guard !ids.isEmpty else { return [] }
        let present = await existence.existingIdentifiers(among: ids)
        return Set(ids.filter { !present.contains($0) })
    }

    /// 缺图处理（photo-picker-v0.1 §5.1「我的作品」；需求 v0.4 §4.8 5a / 5b；hd-export-req-v0.2 F2 / F5「4b」）：
    /// - 没有缺失：什么都不动（不重画预览）。
    /// - 有缺失且能确认（完整相册权限）：交给 `rematcher` 换成本机、可见、清晰的相近照片（`IndexWorkRematcher`），
    ///   实在找不到的留白；然后**重新生成预览**并原子写回（`applyRematch`）。之后再导出用写回的布局。
    ///   照片恢复 / 取消隐藏后不改回去（5b）。没有注入 `rematcher` 或补格出错时全部留白（不是失败）。
    /// - 受限访问 / 无权限（`canConfirmMissing == false`）或写回失败：只计数提示，不改作品。
    /// - Task 被取消（关掉查看页）：不写回任何东西，返回 nil；下次打开再做。
    /// 目标图副本只读（算格子的目标特征），不改、不删（5c 待定）。
    /// 返回处理后的作品和 `works.missing` 用的张数（留白的 + 这次查到还没处理的）。
    func reconcileMissing(_ work: Work) async -> (work: Work, missing: Int)? {
        let missing = await missingAssetIDs(work.layout)
        if Task.isCancelled { return nil }
        guard !missing.isEmpty else { return (work, work.meta.droppedPhotoCount) }
        let pendingCount = work.meta.droppedPhotoCount + missing.count
        guard await existence.canConfirmMissing() else { return (work, pendingCount) }
        var result = WorkRematchResult.allBlank(work.layout, missing: missing)
        if let rematcher {
            var target: PixelBuffer?
            if let url = work.targetURL { target = try? await images.readTarget(at: url) }
            do {
                result = try await rematcher.rematch(work.layout, missing: missing, target: target)
            } catch is CancellationError {
                return nil
            } catch WorkRematchError.indexUnavailable {
                return (work, pendingCount)   // 索引还没好：不改作品，下次打开再补
            } catch {
                // 补格本身出错：退回留白（隐藏照片照样不会再出现）
            }
            lastRematchNote = result.note
        }
        if Task.isCancelled { return nil }   // 取消：不写回半成品
        do {
            let updated = try await store.applyRematch(result, base: work.layout, for: work.id)
            return (updated, updated.meta.droppedPhotoCount + (updated.layout == work.layout ? missing.count : 0))
        } catch {
            return (work, pendingCount)
        }
    }

    /// 把缺图处理结果同步到查看页和列表（预览文件变了，列表缩略图随 `previewURL` 刷新）。
    private func apply(_ work: Work, missing: Int) async {
        var summary = work.summary
        if missing != summary.meta.missingCount {
            try? await store.setMissingCount(missing, for: work.id)
            summary.meta.missingCount = missing
        }
        if let i = state.summaries.firstIndex(where: { $0.id == work.id }) { state.summaries[i] = summary }
        guard openedWork?.id == work.id else { return }   // 期间关掉 / 换了作品：只更新列表
        var updated = work
        updated.summary = summary
        openedWork = updated
        state.opened = OpenedWork(summary: summary, missingCount: missing)
    }

    // MARK: 再导出

    /// 查看页「导出」：先做一遍缺图处理（期间可能又有照片被删 / 被隐藏），再按（处理后的）布局交给导出线；
    /// 目标图副本读不出来就不叠加。
    public func exportOpenedTapped(purpose: ExportPurpose) async {
        guard let work = openedWork, let handler = exportHandler else { return }
        guard let (updated, missing) = await reconcileMissing(work), openedWork?.id == work.id else { return }
        await apply(updated, missing: missing)
        var target: PixelBuffer?
        if let url = updated.targetURL { target = try? await images.readTarget(at: url) }
        await handler.exportWork(layout: updated.layout, target: target, purpose: purpose)
    }

    // MARK: 删除（二次确认）

    public func deleteTapped(_ id: WorkID) { state.pendingDelete = id }
    public func deleteCancelled() { state.pendingDelete = nil }

    public func deleteConfirmed() async {
        guard let id = state.pendingDelete else { return }
        state.pendingDelete = nil
        do {
            try await store.delete(id)
        } catch WorksStoreError.notFound {
            // 已经不在了：当作删除成功
        } catch {
            state.notice = .worksDeleteFailed
        }
        if state.opened?.id == id { close() }
        if case .saved(let saved) = state.saveStatus, saved == id { state.saveStatus = .idle }
        await reload()
    }

    /// 停掉中继订阅（测试结束时释放）。
    public func stop() {
        relayTask?.cancel()
        relayTask = nil
    }
}
