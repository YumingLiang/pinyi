import Foundation
import MosaicCore

/// 「存到我的作品」按钮状态（结果页，需求 B2 / B10-5）。
///
/// 由「当前结果 vs 作品库」算出来（`WorksController.refreshSaveStatus()`），不靠记住「点过保存」：
/// 当前结果的指纹（`WorkFingerprint`）在库里 → 已存；叠加强度也一样 → `.saved`（显示 `works.saved`，不可点），
/// 只差叠加强度 → `.overlayChanged`（恢复可点，点了更新原作品）。所以从作品打开的结果、上次存过又重新生成出同一张的结果，规则都一样。
public enum WorkSaveStatus: Sendable, Hashable {
    /// 没存过：按钮「存到我的作品」可点。
    case idle
    case saving
    /// 当前结果已存且没改动：显示「已存到我的作品」，不可点。
    case saved(WorkID)
    /// 当前结果是这份作品，但叠加强度改了还没存：按钮可点，点了更新原作品（不另存）。
    case overlayChanged(WorkID)
    case failed

    /// 按钮能不能点。
    public var canSave: Bool {
        switch self {
        case .idle, .overlayChanged, .failed: return true
        case .saving, .saved: return false
        }
    }
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
        refreshSaveStatus()
    }

    /// 结果页现状变了（叠加强度、进出结果页）：重算按钮状态。平台层在叠加强度 / 结果页 / revision 变化时调，可重复调。
    public func resultContextDidChange() { refreshSaveStatus() }

    /// 按「当前结果 vs 作品库」算按钮状态（B10-5）：
    /// 库里有同指纹作品（多份时取最新的，和存储层查重一致）→ 叠加强度相同 `.saved`，不同 `.overlayChanged`；没有 → `.idle`。
    /// 正在存时不动；存失败后结果没变就保持 `.failed`。
    public func refreshSaveStatus() {
        if case .saving = state.saveStatus { return }
        let ctx = resultContext()
        let key = StatusKey(revision: ctx.resultRevision, overlayAlpha: ctx.overlayAlpha)
        if case .failed = state.saveStatus, failedKey == key { return }
        failedKey = nil
        state.saveStatus = computeSaveStatus(ctx)
    }

    private func computeSaveStatus(_ ctx: WorkResultContext) -> WorkSaveStatus {
        guard let layout = ctx.layout else { return .idle }
        let fp = currentFingerprint(layout, revision: ctx.resultRevision)
        guard let match = state.summaries.first(where: { $0.meta.fingerprint == fp }) else { return .idle }
        return WorkFingerprint.sameOverlay(match.meta.overlayAlpha, ctx.overlayAlpha) ? .saved(match.id) : .overlayChanged(match.id)
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

    /// 结果页「存到我的作品」（B10）：没存过 → 新存一份；只改了叠加强度 → 更新原作品；已存且没改 → 什么都不写。
    public func saveCurrentResultTapped() async {
        if case .saving = state.saveStatus { return }
        let ctx = resultContext()
        guard let layout = ctx.layout else { return }
        let key = StatusKey(revision: ctx.resultRevision, overlayAlpha: ctx.overlayAlpha)
        state.saveStatus = .saving
        do {
            _ = try await store.save(WorkDraft(layout: layout, target: ctx.target, overlayAlpha: ctx.overlayAlpha, tier: nil,
                                               seed: layout.params.seed, origin: .savedManually))
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

    /// 缺失的原照片张数（去重后）。
    public func missingCount(_ layout: MosaicLayout) async -> Int {
        let ids = layout.uniqueAssetIDs
        guard !ids.isEmpty else { return 0 }
        let present = await existence.existingIdentifiers(among: ids)
        return ids.reduce(0) { $0 + (present.contains($1) ? 0 : 1) }
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

    public func deleteConfirmed() async {
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
    }
}
