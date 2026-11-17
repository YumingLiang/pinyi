import Foundation
import MosaicCore

/// 「存到我的作品」按钮状态（结果页，需求 B2 / B10-5、6）。
///
/// 由「当前结果 vs 作品库」算出来（`WorksController.refreshSaveStatus()`），不靠记住「点过保存」：
/// 当前结果的内容指纹（`WorkFingerprint`）在库里 → 叠加强度也一样 `.saved`（`preview.saved_to_works`，不可点），
/// 只差叠加强度 → `.needsUpdate`（`works.update`「更新这张作品」，点了直接覆盖原作品，不弹确认）。
/// 所以从作品打开的结果、上次存过又重新生成出同一张的结果，规则都一样。
public enum WorkSaveStatus: Sendable, Hashable {
    /// 没存过：`preview.save_to_works`「存到我的作品」，点了新存一份。
    case idle
    case saving
    /// 当前结果已存且没改动：`preview.saved_to_works`「已存到我的作品」，不可点。
    case saved(WorkID)
    /// 当前结果就是这份作品，只改了叠加强度：`works.update`「更新这张作品」，点了更新原作品（不另存、不弹确认）。
    case needsUpdate(WorkID)
    /// 上次保存 / 更新失败（结果没变就一直显示 `works.save_failed`，可重试）。
    case failed

    /// 点了会新存一份。
    public var canSave: Bool {
        switch self {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// 点了会更新原作品。
    public var canUpdate: Bool {
        if case .needsUpdate = self { return true }
        return false
    }

    /// 按钮能不能点。
    public var isEnabled: Bool { canSave || canUpdate }

    /// 按钮文案（QA A12）：没存 / 存失败 / 保存中 → `preview.save_to_works`；已存 → `preview.saved_to_works`（不可点）；
    /// 只改了叠加强度 → `works.update`。保存中界面显示转圈，key 仍按「存到我的作品」给。
    public var buttonKey: L10nKey {
        switch self {
        case .saved: return .previewSavedToWorks
        case .needsUpdate: return .worksUpdate
        case .idle, .saving, .failed: return .previewSaveToWorks
        }
    }
}

/// 未保存提示的种类（B10-4 / B10-11；QA works-rules A8）。弹窗由 feat/start-new「再拼一张」接线，本分支只提供判断。
public enum UnsavedPrompt: Sendable, Hashable {
    /// 不用弹：没有结果，或当前结果已存且没改动。
    case none
    /// 当前结果没存进作品（导出过不算存过）→ `quick.unsaved.title`；「保存」= 新存。
    case unsaved
    /// 存过的作品只改了叠加强度还没存 → `quick.unsaved.update_title`；「保存」= 更新这份。
    case alphaChanged(WorkID)

    public var titleKey: L10nKey? {
        switch self {
        case .none: return nil
        case .unsaved: return .quickUnsavedTitle
        case .alphaChanged: return .quickUnsavedUpdateTitle
        }
    }
}

/// 打开中的作品（查看页）。
public struct OpenedWork: Sendable, Hashable {
    public var summary: WorkSummary
    /// 原照片现在用不了的格数；nil = 还在检查。
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
    /// 打开 / 删除失败等一次性提示（需要点「好」关掉的 alert）。
    public var notice: L10nKey?
    /// 约 2 秒自动消失的轻提示（目前只有更新成功的 `works.updated`，B10-6）。
    public var toast: L10nKey?

    public init() {}

    public var count: Int { summaries.count }
    public var isEmpty: Bool { isLoaded && summaries.isEmpty }
    /// 结果页「存到我的作品」按钮当前文案（QA A12，= `saveStatus.buttonKey`）。
    public var saveButtonKey: L10nKey { saveStatus.buttonKey }
    /// 结果页「存到我的作品」按钮能不能点（QA A12，= `saveStatus.isEnabled`；平台层另外在导出中置灰）。
    public var isSaveButtonEnabled: Bool { saveStatus.isEnabled }
    /// 列表底部常驻提示（需求 B8）。
    public static let keepHintKey = L10nKey.worksKeepHint
    /// 查看页 / 导出前的缺失提示（`works.missing`，参数：格数）。
    public var missingLine: LocalizedLine? {
        guard let n = opened?.missingCount, n > 0 else { return nil }
        return LocalizedLine(.worksMissing, [CountFormat.grouped(n)])
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

/// 结果页的现状（「存到我的作品」和按钮状态都从这里取布局、目标图、叠加强度）。
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

/// 「我的作品」编排（需求 B / B10；design/works-storage-v0.1）：手动保存、列表、打开、缺失检测、删除确认、再导出。
///
/// - **导出不自动存**（AndyL 11-16 22:20，B10-1）：导出成功事件（`ExportSuccessRelay`）只用来刷新按钮状态，不写作品库。
/// - 只有「存到我的作品」才存。同一张（`WorkFingerprint`：格子分配 + cols/rows + targetCrop）只存一份；
///   只改了叠加强度 → 更新原作品（叠加强度、预览图），日期和列表位置不变；「换一种拼法」等 → 新的一张。
/// - 缺失原照片：打开 / 导出前批量查一次，只计数并提示（`works.missing`）。缺失格子**不**用预览图放大补（F 节作废），
///   本机相近照片重新匹配（4b）留到 11-18，接口是 `MissingCellRematching`。
@MainActor
public final class WorksController {
    public let store: any WorksStore
    public let existence: any PhotoExistenceChecking
    public let images: any WorkImageEncoding
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
    /// 当前结果的指纹缓存（按 revision + 网格 + 首尾格子校验；同一 revision 内格子分配不变，拖叠加滑杆不重算）。
    private var fingerprintCache: (key: FingerprintKey, value: String)?
    /// 保存失败时的结果（revision + 叠加强度）：结果没变就一直显示失败，变了才回到按库计算的状态。
    private var failedKey: StatusKey?
    /// 轻提示自动消失的时长（测试可调短）。
    public var toastDuration: Duration = .seconds(2)
    private var toastTask: Task<Void, Never>?
    /// 结果页记住的「当前结果对应的作品」（B10-13）：存 / 更新成功后记下，和结果版本号绑定。
    /// 「再调一调」只改叠加强度再回来不重新生成、版本号不变 → 一直记得；换拼法 / 重新生成（版本号变了）才清掉。
    private var remembered: (revision: Int, id: WorkID)?

    private struct FingerprintKey: Equatable {
        var revision: Int
        var cols: Int
        var rows: Int
        var count: Int
        var first: String?
        var last: String?
    }

    private struct StatusKey: Equatable {
        var revision: Int
        var overlayAlpha: Double
    }

    public init(store: any WorksStore, existence: any PhotoExistenceChecking, images: any WorkImageEncoding,
                resultContext: @escaping @MainActor () -> WorkResultContext = {
                    WorkResultContext(layout: nil, target: nil, overlayAlpha: 0, tier: nil, resultRevision: 0)
                }) {
        self.store = store
        self.existence = existence
        self.images = images
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
        refreshSaveStatus()
    }

    /// 结果变了（新生成 / 换一种拼法）：按新结果重算按钮状态（通常回到「存到我的作品」）。平台层在 `resultRevision` 变化时调。
    public func resultDidChange(revision: Int) {
        guard revision != lastRevision else { return }
        lastRevision = revision
        if let r = remembered, r.revision != revision { remembered = nil }
        refreshSaveStatus()
    }

    /// 结果页现状变了（叠加强度、进出结果页）：重算按钮状态。平台层在叠加强度 / 结果页 / revision 变化时调，可重复调。
    public func resultContextDidChange() { refreshSaveStatus() }

    /// 按「当前结果 vs 作品库」算按钮状态（B10-5）：
    /// 库里有同指纹作品（结果页记住的作品优先，否则取 updatedAt/createdAt 最新的一份，和存储层查重同一个 `WorkSummary.saveTarget`）→ 叠加强度相同 `.saved`，不同 `.needsUpdate`；没有 → `.idle`。
    /// 正在存时不动；存失败后结果没变就保持 `.failed`。
    public func refreshSaveStatus() {
        if case .saving = state.saveStatus { return }
        let ctx = resultContext()
        let key = StatusKey(revision: ctx.resultRevision, overlayAlpha: ctx.overlayAlpha)
        if case .failed = state.saveStatus, failedKey == key { return }
        failedKey = nil
        state.saveStatus = computeSaveStatus(ctx)
    }

    /// 当前结果记住的作品 id（只对同一结果版本号有效）。
    public var currentWorkID: WorkID? { rememberedID(for: resultContext().resultRevision) }

    private func rememberedID(for revision: Int) -> WorkID? {
        guard let r = remembered, r.revision == revision else { return nil }
        return r.id
    }

    private func computeSaveStatus(_ ctx: WorkResultContext) -> WorkSaveStatus {
        guard let layout = ctx.layout else { return .idle }
        let fp = currentFingerprint(layout, revision: ctx.resultRevision)
        guard let match = WorkSummary.saveTarget(in: state.summaries, fingerprint: fp,
                                                 preferred: rememberedID(for: ctx.resultRevision)) else { return .idle }
        return WorkFingerprint.sameOverlay(match.meta.overlayAlpha, ctx.overlayAlpha) ? .saved(match.id) : .needsUpdate(match.id)
    }

    private func currentFingerprint(_ layout: MosaicLayout, revision: Int) -> String {
        let key = FingerprintKey(revision: revision, cols: layout.cols, rows: layout.rows, count: layout.cellAssignments.count,
                                 first: layout.cellAssignments.first?.localIdentifier,
                                 last: layout.cellAssignments.last?.localIdentifier)
        if let c = fingerprintCache, c.key == key { return c.value }
        let fp = WorkFingerprint.of(layout)
        fingerprintCache = (key, fp)
        return fp
    }

    // MARK: 保存

    /// 现在离开结果页要不要弹未保存提示（按「当前结果 vs 作品库」算，和按钮状态同一口径；保存中按「没存」算）。
    public var unsavedPrompt: UnsavedPrompt {
        let ctx = resultContext()
        guard ctx.layout != nil else { return .none }
        switch computeSaveStatus(ctx) {
        case .saved: return .none
        case .needsUpdate(let id): return .alphaChanged(id)
        default: return .unsaved
        }
    }

    /// 叠加强度变了（QA works-rules 接口名 A6；等同 `resultContextDidChange()`，强度以 `resultContext` 为准）。
    public func overlayAlphaDidChange(_ alpha: Double) {
        _ = alpha
        refreshSaveStatus()
    }

    /// 结果页「存到我的作品」/「更新这张作品」（B10）：没存过 → 新存一份；只改了叠加强度 → 更新原作品（不弹确认），
    /// 成功后出约 2 秒的轻提示 `works.updated`；已存且没改 → 什么都不写。
    public func saveCurrentResultTapped() async {
        if case .saving = state.saveStatus { return }
        let ctx = resultContext()
        guard let layout = ctx.layout else { return }
        let key = StatusKey(revision: ctx.resultRevision, overlayAlpha: ctx.overlayAlpha)
        state.saveStatus = .saving
        do {
            let result = try await store.save(WorkDraft(layout: layout, target: ctx.target, overlayAlpha: ctx.overlayAlpha, tier: nil,
                                                        seed: layout.params.seed, origin: .savedManually,
                                                        preferredWorkID: rememberedID(for: ctx.resultRevision)))
            remembered = (ctx.resultRevision, result.summary.id)
            if result.outcome == .updatedOverlay { showToast(.worksUpdated) }
            // 刷新列表（新增 / 预览图换了），再按库重算按钮状态（期间结果可能又变了，按最新的算）
            let list = await store.list()
            state.summaries = list
            state.isLoaded = true
            failedKey = nil
            state.saveStatus = computeSaveStatus(resultContext())
        } catch {
            failedKey = key
            state.saveStatus = .failed
            await reload()
        }
    }

    /// 导出成功（结果页或作品页）。**不再自动存**（AndyL 11-16 22:20，需求 B10-1：导出只写系统相册，不动「我的作品」）；
    /// 只按作品库重算一次按钮状态。保留这个入口是因为导出线仍经 `ExportSuccessRelay` 通知。
    public func exportSucceeded(layout: MosaicLayout) async {
        _ = layout
        refreshSaveStatus()
    }

    // MARK: 查看

    /// 打开作品：读布局，再批量查一次原照片还在不在（只计数，`works.missing`）。
    public func open(_ id: WorkID) async {
        openToken += 1
        let token = openToken
        do {
            let work = try await store.load(id)
            guard token == openToken else { return }
            openedWork = work
            state.opened = OpenedWork(summary: work.summary, missingCount: nil)
            let missing = await missingCount(work.layout)
            guard token == openToken, state.opened?.id == id else { return }
            state.opened?.missingCount = missing
            if missing != work.meta.missingCount {
                try? await store.setMissingCount(missing, for: id)
                if let i = state.summaries.firstIndex(where: { $0.id == id }) { state.summaries[i].meta.missingCount = missing }
            }
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

    /// 轻提示：显示 `toastDuration` 后自动消失；新的会顶掉旧的。
    private func showToast(_ key: L10nKey) {
        toastTask?.cancel()
        state.toast = key
        let duration = toastDuration
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            if self.state.toast == key { self.state.toast = nil }
        }
    }

    public func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        state.toast = nil
    }

    /// 原照片现在用不了的**格数**（copy v1.3：`works.missing` 按格计，同一张照片用在几格就算几格；空格子不算）。
    public func missingCount(_ layout: MosaicLayout) async -> Int {
        let ids = layout.uniqueAssetIDs
        guard !ids.isEmpty else { return 0 }
        let present = await existence.existingIdentifiers(among: ids)
        return layout.cellAssignments.reduce(0) { n, cell in
            n + (cell.localIdentifier.isEmpty || present.contains(cell.localIdentifier) ? 0 : 1)
        }
    }

    // MARK: 再导出

    /// 查看页「导出」：先刷新缺失数（导出前提示用），再按保存的布局交给导出线；目标图副本读不出来就不叠加。
    public func exportOpenedTapped(purpose: ExportPurpose) async {
        guard let work = openedWork, let handler = exportHandler else { return }
        let missing = await missingCount(work.layout)
        guard openedWork?.id == work.id else { return }
        state.opened?.missingCount = missing
        var target: PixelBuffer?
        if let url = work.targetURL { target = try? await images.readTarget(at: url) }
        await handler.exportWork(layout: work.layout, target: target, purpose: purpose)
    }

    // MARK: 删除（二次确认）

    public func deleteTapped(_ id: WorkID) { state.pendingDelete = id }
    public func deleteCancelled() { state.pendingDelete = nil }

    @available(*, deprecated, message: "确认按钮请直接带 id 调 deleteConfirmed(_:)：弹窗收起时 pendingDelete 会先被 deleteCancelled() 清掉")
    public func deleteConfirmed() async { await confirmPendingDelete() }

    /// 按 `pendingDelete` 删除（无参旧入口的实现；没有待确认的就什么都不做）。只给测试和旧入口用，UI 不要用。
    func confirmPendingDelete() async {
        guard let id = state.pendingDelete else { return }
        await deleteConfirmed(id)
    }

    /// 弹窗「删除」按钮直接带上作品 id：SwiftUI 收起 confirmationDialog 时会先把 isPresented 置 false
    /// （→ `deleteCancelled()` 清掉 `pendingDelete`），而按钮里的 `Task` 更晚执行，不能再靠 `pendingDelete` 取 id。
    public func deleteConfirmed(_ id: WorkID) async {
        if state.pendingDelete == id { state.pendingDelete = nil }
        do {
            try await store.delete(id)
        } catch WorksStoreError.notFound {
            // 已经不在了：当作删除成功
        } catch {
            state.notice = .worksDeleteFailed
        }
        if state.opened?.id == id { close() }
        await reload()   // 按库重算按钮：删掉的是当前结果对应的作品 → 回到可存
    }

    /// 停掉中继订阅（测试结束时释放）。
    public func stop() {
        relayTask?.cancel()
        relayTask = nil
        toastTask?.cancel()
        toastTask = nil
    }
}

// MARK: - 未保存提示（「再拼一张」，quick-start v1.0 §2e + hd-export B10-4/11）

/// `unsavedPrompt` 就是上面按「当前结果 vs 作品库」算的那个（导出过不算存过）。
extension WorksController: CurrentResultSaving {
    /// 未保存提示里的「保存」：同「存到我的作品」/「更新这张作品」按钮（只改了强度时更新原作品，成功出 `works.updated`）。
    public func saveCurrentResult() async -> Bool {
        await saveCurrentResultTapped()
        if case .saved = state.saveStatus { return true }
        return false
    }
}
