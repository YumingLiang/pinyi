import Foundation
import MosaicCore

/// App 的编排层（架构师 G-3）：权限路由、索引加载、扫描（渐进可用 / 取消 / 后台）、生成（取消 / 重跑 / 换拼法）、
/// 导出保存与分享、前后台，全部在这里；App target 的 `AppModel` 只把 `state` 转发给 SwiftUI、把手势转成方法调用。
///
/// - 依赖全部经 `AppDependencies` 注入（协议），没有单例、没有 `#if TESTING`。
/// - `@MainActor`：状态只在主线程改；重活（扫描在 `PhotoIndex` actor、生成 / 导出在各自的非隔离 async 实现）不在主线程。
/// - 状态通过 `state`（值类型）+ `observe(_:)` / `states()` 暴露；测试用假时钟和可控的假实现推进，不写 sleep。
/// - 互斥：同一时刻最多一个扫描、一个生成、一个导出；生成进行中不能导出，导出进行中不能开始 / 换拼法 / 返回设置。
@MainActor
public final class AppCoordinator {
    public let dependencies: AppDependencies
    public let index: PhotoIndex
    public let memory: PeakMemoryTracker

    public internal(set) var state: AppState {
        didSet {
            guard state != oldValue else { return }
            if state.flow.source.selection != oldValue.flow.source.selection { sourceSelectionDidChange() }
            notify()
        }
    }
    /// 最近一次生成结果（不放进 `state`：体积大且不是 Hashable）。
    public internal(set) var product: GenerationProduct? {
        didSet { if (product != nil) != state.hasResult { state.hasResult = product != nil } }
    }
    /// 当前目标图（平台层解码后交进来）。「再拼一张」期间这是**上一张结果**的目标图（预览叠加 / 存作品要用），
    /// 新选的目标图先放在 `pendingTarget`，开始生成新图时才换进来。
    public internal(set) var target: PixelBuffer?
    /// 「再拼一张」新选的目标图（开始生成时才替换 `target`）。
    public internal(set) var pendingTarget: PixelBuffer?
    /// 未保存提示每弹一次 +1：收起弹窗时用来确认收的还是同一个提示（`unsavedPromptDismissed`）。不放进 AppState（不是界面状态）。
    var unsavedPromptID = 0
    /// 「再拼一张」开始时的设置和素材来源：确认页上的改动只作用于新图（#18 QA P2-b），返回预览页时恢复，旧结果和
    /// 「已存」按钮状态不受影响。开始生成新图时丢掉（新图就用确认页上的值）。
    var settingsBeforeQuickAgain: (settings: GenerationSettings, selection: SourceSelection)?
    /// 当前这次「再拼一张」从哪页发起（选图提示「取消」回这里，copy v1.6）；不在「再拼一张」途中为 nil。
    var quickStartOrigin: QuickStartOrigin?
    /// 下一次进入「再拼一张」时的发起页（中间可能先弹未保存提示）。
    var nextQuickStartOrigin: QuickStartOrigin?
    /// 作品页 /「再调一调」进来的「再拼一张」开始前的目标图和代次（选图提示「取消」时恢复；开始生成新图或放弃时清掉）。
    var targetBeforeFreshQuickStart: (target: PixelBuffer?, generation: Int)?
    /// 「存到我的作品」（`WorksController`）：未保存提示要问它当前结果存没存过、以及「保存」按钮去存。弱引用，不成环。
    public weak var resultSaver: (any CurrentResultSaving)?
    /// 每换一次目标图 +1（PixelBuffer 不做内容比较，用代次判断「目标图换没换」）。
    var targetGeneration = 0
    /// 当前形状结果是用哪个选择生成的。选新目标图或退回目标页会清掉 `flow.shape`，结果还在时用它恢复，并继续禁止保存。
    var shapeIdentity: ShapeChoice?
    /// 已排好的文字。没有文字界面时由测试或后续入口放进来。生成时固定细档，不用密度参数。
    var preparedText: PreparedTextMosaic?
    /// `product` 是用哪组输入生成的（不含叠加强度）。设置页点「开始拼图」时若和当前输入一样，
    /// 说明「再调一调」只改了叠加强度：直接回到上一次结果，不重新生成（B10 第 3/13 条）。
    private var productInputs: ProductInputs?
    private struct ProductInputs: Equatable {
        var targetGeneration: Int
        var selection: SourceSelection
        var density: DensityChoice
        /// nil = 照片拼图。背景不在这里：只改背景不重新匹配。
        var shapePreset: ShapePresetID?
        var shapePalette: ShapePalette?
    }
    /// 来源被静默去掉相簿（不是用户改的）：当前结果记下的来源同样换掉，`settingsPrimaryAction` 不因此变「开始拼图」。
    func notePrunedSelectionForProduct(old: SourceSelection, new: SourceSelection) {
        if productInputs?.selection == old { productInputs?.selection = new }
    }
    private var currentInputs: ProductInputs {
        ProductInputs(targetGeneration: targetGeneration, selection: state.flow.source.selection,
                      density: state.flow.settings.density,
                      shapePreset: state.flow.shape?.preset, shapePalette: state.flow.shape?.palette)
    }
    /// 平台层执行系统动作（打开设置、受限选择器）。
    public var systemActionHandler: (@MainActor (SystemAction) -> Void)?

    private var observers: [UUID: @MainActor (AppState) -> Void] = [:]
    private var started = false
    private var loadTask: Task<Void, Never>?
    /// 记住的来源是相簿时，启动后取一次相簿列表（§2f 补充 3）。单独一个任务，不拖住索引加载 / 扫描。
    var albumsLoadTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    /// 最近一次「开始拼图」时用于 200 张门槛判断的张数（筛选后的已知数）。
    private var gateAvailable: Int?
    private var exportTask: Task<Void, Never>?
    private var lastExportPurpose: ExportPurpose = .save
    private var exportSource: ExportSource?
    private var lifecycleTask: Task<Void, Never>?
    private var memorySamplingTask: Task<Void, Never>?
    /// 被取消、尚未结束的任务（`settle()` 等它们收尾）。
    private var retiring: [Task<Void, Never>] = []
    private var generateGatePending = false
    private var exportInterruptedByBackground = false
    private var memoryTokens: [MemoryPhase: PeakMemoryTracker.Token] = [:]
    /// 相簿多选（§2f）：各相簿的照片 ID（`refreshAlbums` 时取，走 PhotoFetch + isHidden 后置过滤），算去重合计用。
    var albumMembers: [String: [String]] = [:]
    /// 打不开的相簿（`assetIDs(inAlbum:)` 抛错）：列表里置灰、不能勾。
    var unreadableAlbums: Set<String> = []
    /// 去重合计的计算任务（勾选变化时取消旧的）。
    var unionTasks: [String: Task<Void, Never>] = [:]
    private var changeDebouncer = ChangeDebouncer(interval: 2, maxDelay: 10)
    private var debounceTask: Task<Void, Never>?

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.index = PhotoIndex(store: dependencies.indexStore, library: dependencies.library,
                                thumbnails: dependencies.thumbnails, configuration: dependencies.indexConfiguration,
                                perf: dependencies.perf, clock: dependencies.clock.monotonic)
        self.memory = PeakMemoryTracker(reader: dependencies.memory)
        self.state = AppState(initialSeed: dependencies.initialSeed)
        restoreSourceSelection()
    }

    // MARK: - 观察

    public struct ObservationToken: Hashable, Sendable { fileprivate let id: UUID }

    /// 注册状态回调（立即回调一次当前值）。
    @discardableResult
    public func observe(_ handler: @escaping @MainActor (AppState) -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = handler
        handler(state)
        return ObservationToken(id: id)
    }

    public func removeObserver(_ token: ObservationToken) { observers[token.id] = nil }

    /// 状态序列（先给当前值，之后每次变化一个）。
    public func states() -> AsyncStream<AppState> {
        let (stream, continuation) = AsyncStream<AppState>.makeStream(bufferingPolicy: .unbounded)
        let token = observe { continuation.yield($0) }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.removeObserver(token) }
        }
        return stream
    }

    private func notify() {
        let s = state
        for h in observers.values { h(s) }
    }

    // MARK: - 启动 / 路由

    /// 启动：先清导出临时目录（B-27）、出路由（不等索引），再在后台加载索引（评审 §3：`load()` 移出启动关键路径）。
    public func start() {
        guard !started else { return }
        started = true
        dependencies.exporter.removeStaleExports()
        let events = dependencies.lifecycle.events()
        lifecycleTask = Task { [weak self] in
            for await e in events {
                guard let self else { return }
                await self.handle(e)
            }
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let token = self.beginMemory(.indexLoad)
            _ = await self.index.load()
            self.endMemory(token)
            self.state.indexLoaded = true
            self.loadTask = nil
            await self.refreshStatus()
            // 记住的来源是相簿（§1a）：启动就把相簿列表取一次，失效的静默去掉、张数从「加载中」换成真数（§2f 补充 3）。
            if !self.state.albumsLoaded, !self.state.flow.source.selection.isAllPhotos {
                self.albumsLoadTask = Task { [weak self] in
                    await self?.refreshAlbums()
                    self?.albumsLoadTask = nil
                }
            }
        }
        resolveRoute()
    }

    public func resolveRoute() {
        let auth = dependencies.library.authorizationStatus()
        state.authorization = auth
        state.route = AppRoute.resolve(authorization: auth,
                                       hasCompletedOnboarding: dependencies.preferences.bool(.onboardingCompleted),
                                       limitedAcknowledged: dependencies.preferences.bool(.limitedAcknowledged))
        if case .main = state.route { startScan() }
    }

    public func onboardingButtonTapped() async {
        let wasLast = state.onboarding.isLastPage
        let effect = state.onboarding.advance(authorization: dependencies.library.authorizationStatus())
        guard wasLast else { return }
        dependencies.preferences.set(true, for: .onboardingCompleted)
        if let effect { await perform(effect) } else { resolveRoute() }
    }

    public func onboardingSwiped(to page: Int) { state.onboarding.swipe(to: page) }

    public func permissionAction(_ action: PermissionAction, on prompt: PermissionPrompt) async {
        await perform(PermissionLogic.effect(for: action, on: prompt))
    }

    private func perform(_ effect: PermissionEffect) async {
        switch effect {
        case .requestAuthorization:
            _ = await dependencies.library.requestAuthorization()
            dependencies.preferences.set(true, for: .onboardingCompleted)
            resolveRoute()
        case .openSettings: systemActionHandler?(.openSettings)
        case .presentLimitedPicker: systemActionHandler?(.presentLimitedPicker)
        case .showOnboarding:
            state.onboarding = OnboardingFlow()
            state.route = .onboarding
        case .proceed(let access):
            if access == .limited { dependencies.preferences.set(true, for: .limitedAcknowledged) }
            state.route = .main(access)
            startScan()
        case .dismiss:
            break
        }
    }

    /// 回前台时重读授权：被拒 / 受限变化时停扫描、停生成，路由交给权限页（G-3 用例「授权变为受限或拒绝」）。
    private func refreshAuthorization() {
        let auth = dependencies.library.authorizationStatus()
        guard auth != state.authorization else { return }
        let previousAccess = state.authorization.access
        state.authorization = auth
        let route = AppRoute.resolve(authorization: auth,
                                     hasCompletedOnboarding: dependencies.preferences.bool(.onboardingCompleted),
                                     limitedAcknowledged: dependencies.preferences.bool(.limitedAcknowledged))
        if auth.access == nil || route != state.route {
            // 读取范围变了：正在跑的扫描 / 生成基于旧范围，停掉。
            apply(state.scan.send(.accessLost))
            if state.isGenerating {
                send(.cancelTapped)
                send(.cancelConfirmed)
            }
        }
        state.route = route
        if case .main = route, auth.access != previousAccess || auth.access == .limited {
            startScan()   // 范围变了（或受限集合可能变了）：全量 diff 会删掉不再可读的资产
        }
    }

    // MARK: - 扫描

    /// 开始（或续）一轮 全量 diff + 扫描。已有扫描在跑时忽略（互斥）。
    public func startScan() {
        guard scanTask == nil else { return }
        guard case .main = state.route else { return }
        let st = state.indexStatus
        let first = !st.hasCompletedInitialScan && st.available == 0
        state.scan.send(.started(isFirstScan: first, isResuming: st.wasInterrupted))
        dependencies.lifecycle.beginBackgroundWork(.scan)
        let (progress, continuation) = AsyncStream<ScanProgress>.makeStream(bufferingPolicy: .unbounded)
        scanTask = Task { [weak self] in
            guard let self else { return }
            if let load = self.loadTask { await load.value }
            let token = self.beginMemory(.scan)
            // 进度按顺序在主线程消费（不再每条进度起一个无序的 Task，R16）
            let consumer = Task { @MainActor [weak self] in
                for await p in progress { await self?.scanProgressed(p) }
            }
            let result: Result<Void, any Error>
            do {
                _ = try await self.index.synchronize { p in continuation.yield(p) }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            continuation.finish()
            await consumer.value
            switch result {
            case .success: self.state.scan.send(.finished)
            case .failure(let e) where e is CancellationError: break   // 取消是正常路径，不提示
            case .failure: self.state.scan.send(.failed)
            }
            self.endMemory(token)
            self.scanTask = nil
            self.dependencies.lifecycle.endBackgroundWork(.scan)
            await self.refreshStatus()
            await self.refreshAlbums()
        }
    }

    private func scanProgressed(_ p: ScanProgress) async {
        state.scan.send(.progressed(p))
        await refreshStatus()
    }

    public func scanCancelTapped() { state.scan.send(.cancelTapped) }
    public func scanCancelDismissed() { state.scan.send(.cancelDismissed) }
    public func scanCancelConfirmed() { apply(state.scan.send(.cancelConfirmed)) }

    private func apply(_ effects: [ScanFlow.Effect]) {
        for e in effects {
            switch e {
            case .cancelScan:
                if let t = scanTask { t.cancel() }
            case .startScan:
                startScan()
            }
        }
    }

    public func refreshStatus() async {
        let st = await index.status()
        state.indexStatus = st
        state.emptyState = LibraryEmptyState.evaluate(st)
        if let n = LibraryEmptyState.completionNotice(st) { state.transientNotice = n }
        await pruneLowResExclusion()
    }

    public func refreshAlbums() async {
        let library = dependencies.library
        let albums = await library.albums()
        var avail: [String: Int] = [:]
        var members: [String: [String]] = [:]
        var unreadable: Set<String> = []
        for a in albums {
            if let ids = try? await library.assetIDs(inAlbum: a.id) {
                members[a.id] = ids
                avail[a.id] = await index.availableCount(assetIDs: ids)
            } else {
                unreadable.insert(a.id)
            }
        }
        albumMembers = members
        unreadableAlbums = unreadable
        state.albumRows = SourceListLogic.albumRows(albums, availableByAlbum: avail,
                                                    scanComplete: SourceListLogic.isScanComplete(state.indexStatus),
                                                    unreadable: unreadable)
        reconcileSourceSelection()
        state.albumsLoaded = true
        rememberSelectedAlbumNames()
        await pruneLowResExclusion()
        await refreshUnionCounts()
    }

    /// 相册变化（`PHPhotoLibraryChangeObserver`，任意线程 → 平台层转到主线程调用）：2 s 去抖、最长 10 s，
    /// 到点做一次全量 diff + 扫描（决定 11）。时间走注入的时钟。
    public func libraryDidChange() {
        dependencies.generator.invalidateLocalResolution()   // 不合格的照片可能刚下载回本机
        changeDebouncer.noteChange(at: dependencies.clock.now())
        scheduleDebounce()
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        guard let fireAt = changeDebouncer.nextFireTime else { return }
        let clock = dependencies.clock
        let delay = max(0, fireAt - clock.now())
        debounceTask = Task { [weak self] in
            do { try await clock.sleep(seconds: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if self.changeDebouncer.fire(now: clock.now()) {
                self.debounceTask = nil
                self.startScan()
            } else {
                self.scheduleDebounce()
            }
        }
    }

    // MARK: - 主流程（UI 可改的部分）

    /// 目标图解码结果（平台层解码 + 降采样后交进来；nil = 读不出来）。
    public func setTarget(_ pixels: PixelBuffer?) {
        preparedText = nil
        if state.flow.isQuickAgain {
            pendingTarget = pixels   // 上一张结果还在，它的目标图不能动；开始生成新图时才换进来（commitQuickAgain，代次 +1）
        } else {
            target = pixels
            targetGeneration += 1
        }
        state.flow.send(pixels == nil ? .targetFailed : .targetLoaded)
    }

    public func flowSend(_ e: MainFlow.Event) {
        guard !state.export.isBusy else { return }
        let wasQuickAgain = state.flow.isQuickAgain
        let wasFreshShape = state.flow.isFreshShapeConfig
        state.flow.send(e)
        if wasQuickAgain, !state.flow.isQuickAgain, state.flow.step == .result { quickAgainCancelled() }
        if wasFreshShape, !state.flow.isFreshShapeConfig {
            restoreUncommittedShapeEdits()
            quickStartOrigin = nil
        }
    }
    public func selectSource(_ s: SourceSelection) { state.flow.source.select(s) }
    public func setDensity(_ d: DensityChoice) { state.flow.settings.density = d }
    public func setOverlayAlpha(_ a: Double) { state.flow.settings.overlayAlpha = OverlayBlendLimits.clamp(a) }

    /// 首页「用形状拼」。
    public func beginShape() {
        preparedText = nil
        flowSend(.beginShape)
    }

    /// 用已经取到的文字轮廓生成。不提供密度参数，固定细档，叠加强度为 0。
    /// 调用前须先通过 `TextComposition`；这里不再改字、不截断。
    public func prepareText(outline: TextOutline, palette: ShapePalette, background: ShapeBackground) {
        preparedText = PreparedTextMosaic(outline: outline, palette: palette, background: background)
        state.flow.shape = nil
        state.flow.settings.density = .fine
        state.flow.settings.overlayAlpha = 0
    }

    public func setShapePreset(_ id: ShapePresetID) {
        guard id.isKnown, var shape = state.flow.shape else { return }
        shape.preset = id
        state.flow.shape = shape
    }

    public func setShapePalette(_ palette: ShapePalette) {
        guard var shape = state.flow.shape else { return }
        shape.palette = palette
        state.flow.shape = shape
    }

    /// 只改背景。形状、配色、密度、来源都没变时，直接改当前结果，不重新匹配。
    public func setShapeBackground(_ background: ShapeBackground) {
        guard var shape = state.flow.shape else { return }
        shape.background = background
        state.flow.shape = shape
        // 再拼还没开始新生成时，背景只记在配置上。返回原预览要看到原来的结果。
        if state.flow.isQuickAgain || state.flow.isFreshShapeConfig { return }
        if product != nil, productInputs == currentInputs {
            product?.setShapeBackground(background)
            if shapeIdentity != nil { shapeIdentity?.background = background }
            state.resultRevision += 1
        }
    }

    /// 当前结果是不是形状。以结果上的 `shapeFrame` 为准，不看导航里可能已被清掉的 `flow.shape`。
    public var currentResultIsShape: Bool { product?.shapeFrame != nil }

    /// 形状结果这一阶段不能存作品。正在选形状、或当前结果本身是形状，都不能存。
    public var allowsWorkSave: Bool { state.flow.shape == nil && !currentResultIsShape }
    public func setShowScanSheet(_ on: Bool) { state.showScanSheet = on }
    public func setPresentedEmptyState(_ e: LibraryEmptyState?) { state.presentedEmptyState = e }
    public func setExportTier(_ t: ExportTier) {
        guard !state.export.isBusy else { return }
        state.exportTier = t
    }

    // MARK: - 生成

    /// 设置页主按钮（B10.14）：「再调一调」进来后，和当前结果相比只动了叠加强度（或什么都没动）→ `.done`「完成」
    /// （`common.done`）：回到原结果，格子 / 种子不变，只按新强度重画；动了密度、来源、目标图（含裁剪，换图即换代次）→
    /// `.generate`「开始拼图」，重新生成，算新的一张。没有可回去的结果（首次进设置页、失败后结果已丢）也是 `.generate`。
    public var settingsPrimaryAction: SettingsPrimaryAction {
        guard product != nil, let inputs = productInputs, inputs == currentInputs,
              state.flow.generation.lastOutcome != nil, case .idle = state.flow.generation.phase else { return .generate }
        if state.flow.shape == nil, target == nil { return .generate }
        return .done
    }

    /// 设置页「完成」：回到上一次结果，不跑生成；`resultRevision` 不变（作品 id 保留，存过且强度变了 → `works.update`）。
    /// 平台层回到结果页时按新强度重画预览（AppModel 进结果页时重画）。不是 `.done` 时忽略。
    public func adjustDoneTapped() async {
        guard settingsPrimaryAction == .done, !state.export.isBusy else { return }
        send(.restoreLastResult)
    }


    /// 「开始拼图」。并发点击只处理第一次（互斥）；导出进行中忽略。总是重新生成：
    /// 「再调一调」回来只改了叠加强度时，设置页主按钮是「完成」（`settingsPrimaryAction == .done`），走 `adjustDoneTapped()`。
    public func generateTapped() async {
        guard !generateGatePending, !state.export.isBusy, !state.isGenerating else { return }
        // 结果页上（phase 仍是 `.result`）只有「再拼一张」的确认页能开始新图。
        if case .result = state.flow.generation.phase, !state.flow.isQuickAgain { return }
        generateGatePending = true
        defer { generateGatePending = false }
        if let load = loadTask { await load.value }
        await awaitAlbumsBeforeGenerate()
        await refreshStatus()
        let (avail, total) = await sourceCounts()
        switch GenerateGate.decide(status: state.indexStatus, availableInSource: avail, sourceAssetTotal: total) {
        case .emptyState(let e): state.presentedEmptyState = e
        case .waitForScan:
            state.showScanSheet = true
            startScan()
        case .proceed(let n):
            // 「可用照片」按清晰度筛选后的数：减去该来源已知不够清楚的张数，200 张门槛据此判断。
            let after = postFilterAvailable(n)
            gateAvailable = after
            send(.startTapped(available: after))
        }
    }

    /// 失败页「再试一次」。张数与「开始拼图」同一套：索引可用减去该来源已知不够清楚的，200 张门槛据此判断。
    public func retryTapped() async {
        guard !generateGatePending, !state.export.isBusy, !state.isGenerating else { return }
        generateGatePending = true
        defer { generateGatePending = false }
        if let load = loadTask { await load.value }
        await awaitAlbumsBeforeGenerate()
        await refreshStatus()
        let (avail, _) = await sourceCounts()
        let after = postFilterAvailable(avail)
        gateAvailable = after
        send(.retryTapped(available: after))
    }

    private func sourceCounts() async -> (Int, Int) {
        let selection = state.flow.source.selection
        guard !selection.isAllPhotos else { return (state.indexStatus.available, state.indexStatus.assetTotal ?? 0) }
        // 单个 / 多个相簿：按 localIdentifier 去重后的并集（§2f，200 张门槛按去重合计算）。
        let ids = await currentMemberIDs(of: selection.albumIDs)
        return (await index.availableCount(assetIDs: ids), ids.count)
    }

    /// 索引可用张数减去该来源已知不够清楚的张数（「开始拼图」与失败后「再试一次」共用）。
    private func postFilterAvailable(_ raw: Int) -> Int {
        max(0, raw - state.knownLowResCount(for: state.flow.source.selection))
    }

    /// 相册 / 索引更新后：丢掉已经不在该来源里的排除 ID，重算来源页张数。
    private func pruneLowResExclusion() async {
        guard let e = state.lowResExclusion else { return }
        let current: Set<String>
        if e.selection.isAllPhotos {
            current = await index.indexedAssetIDs()
        } else {
            current = Set(await currentMemberIDs(of: e.selection.albumIDs))
        }
        let next = e.pruned(to: current)
        if next != e { state.lowResExclusion = next.count == 0 ? nil : next }
    }

    /// 生成状态机事件（UI 的取消 / 确认 / 换拼法 / 返回等都走这里）。
    public func send(_ e: GenerationMachine.Event) {
        if state.export.isBusy {
            switch e {
            case .startTapped, .retryTapped, .reshuffleTapped, .backToSettings, .restoreLastResult: return   // 导出期间不动结果
            default: break
            }
        }
        let effects = state.flow.generation.send(e)
        // 「再拼一张」：真正开始生成新图（有 `.run`）时才丢弃上一张没存的结果和预览位图，换上新目标图。
        let starts = effects.contains(where: { if case .run = $0 { return true }; return false })
        if state.flow.isQuickAgain, starts {
            commitQuickAgain()
        }
        if state.flow.isFreshQuickStart, starts {
            state.flow.endFreshQuickStart(); quickStartOrigin = nil; targetBeforeFreshQuickStart = nil
            settingsBeforeQuickAgain = nil
        }
        state.flow.syncWithGeneration()
        if state.flow.step == .result, case .result = state.flow.generation.phase {
            // 完成回调只补回被清掉的形状标记。生成途中用户已经改过的形状、配色或背景留在界面上，
            // 不把开跑时的选择盖回去，否则旧结果会重新变成可导出。
            realignShapeChoiceWithResultIfUnchanged()
        }
        for eff in effects {
            switch eff {
            case .run(let id, let seed): run(id: id, seed: seed)
            case .cancel:
                if let t = generationTask { t.cancel(); retiring.append(t) }
                generationTask = nil
            case .setGenerationActive(let on):
                let index = self.index
                Task { await index.setGenerationActive(on) }
                if on {
                    dependencies.lifecycle.beginBackgroundWork(.generate)
                    memoryTokens[.generate] = beginMemory(.generate)
                } else {
                    dependencies.lifecycle.endBackgroundWork(.generate)
                    if let t = memoryTokens.removeValue(forKey: .generate) { endMemory(t) }
                }
            }
        }
    }

    private func run(id: Int, seed: UInt64) {
        if preparedText != nil {
            state.flow.settings.density = .fine
            state.flow.settings.overlayAlpha = 0
            state.flow.shape = nil
        }
        let shapeChoice = state.flow.shape
        let textMosaic = preparedText
        if textMosaic == nil, shapeChoice == nil, target == nil { send(.finishedWithError(runID: id, failure: .other)); return }
        let settings = state.flow.settings
        let selection = state.flow.source.selection
        let inputs = currentInputs
        let previous = state.flow.generation.phase.isReshuffle ? product : nil
        let photoTarget = target
        let generator = dependencies.generator
        let index = self.index
        if let t = generationTask { t.cancel(); retiring.append(t) }
        let (fractions, continuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let progress: @Sendable (Double) -> Void = { continuation.yield($0) }
        let consumer = Task { @MainActor [weak self] in
            for await f in fractions { self?.send(.progressed(runID: id, fraction: f)) }
        }
        state.generationStage = .matching
        let (stages, stageContinuation) = AsyncStream<GenerationStage>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let stage: @Sendable (GenerationStage) -> Void = { stageContinuation.yield($0) }
        let stageConsumer = Task { @MainActor [weak self] in
            for await s in stages {
                guard let self, self.state.flow.generation.currentRunID == id else { continue }
                if self.state.generationStage != s { self.state.generationStage = s }
            }
        }
        generationTask = Task { [weak self] in
            defer { continuation.finish(); stageContinuation.finish() }
            do {
                let p: GenerationProduct
                if let textMosaic {
                    let snap = try await index.snapshot(for: selection)
                    let grid = try ShapeLayoutRules.text(textMosaic.outline)
                    let colors = ShapePaletteBuilder.photoColors(snapshot: snap.library)
                    let pixels = try ShapeTarget.render(mask: grid.mask,
                                                        gradient: ShapePaletteBuilder.gradient(for: textMosaic.palette,
                                                                                               photoColors: colors),
                                                        background: textMosaic.background)
                    p = try await generator.run(target: pixels, snapshot: snap, settings: settings, seed: seed,
                                                activeCells: grid.mask, shapeBackground: textMosaic.background,
                                                progress: progress, stage: stage)
                } else if let previous, previous.generation.activeCells != nil, let shapeChoice {
                    let snap = try await index.snapshot(for: selection)
                    let grid = try ShapeGenerationPlan.grid(shapeChoice, density: settings.density.density)
                    let colors = ShapePaletteBuilder.photoColors(snapshot: snap.library)
                    let pixels = try ShapeGenerationPlan.target(shapeChoice, grid: grid, photoColors: colors)
                    p = try await generator.reshuffle(previous, target: pixels, settings: settings, seed: seed,
                                                      progress: progress, stage: stage)
                } else if let previous {
                    guard let photoTarget else { throw MosaicError.invalidConfiguration("missing target") }
                    p = try await generator.reshuffle(previous, target: photoTarget, settings: settings, seed: seed,
                                                      progress: progress, stage: stage)
                } else if let shapeChoice {
                    let snap = try await index.snapshot(for: selection)
                    let grid = try ShapeGenerationPlan.grid(shapeChoice, density: settings.density.density)
                    let colors = ShapePaletteBuilder.photoColors(snapshot: snap.library)
                    let pixels = try ShapeGenerationPlan.target(shapeChoice, grid: grid, photoColors: colors)
                    p = try await generator.run(target: pixels, snapshot: snap, settings: settings, seed: seed,
                                                activeCells: grid.mask, shapeBackground: shapeChoice.background,
                                                progress: progress, stage: stage)
                } else {
                    guard let photoTarget else { throw MosaicError.invalidConfiguration("missing target") }
                    let snap = try await index.snapshot(for: selection)
                    p = try await generator.run(target: photoTarget, snapshot: snap, settings: settings, seed: seed,
                                                progress: progress, stage: stage)
                }
                continuation.finish()
                stageContinuation.finish()
                await consumer.value
                await stageConsumer.value
                guard let self else { return }
                if self.state.flow.generation.currentRunID == id {
                    self.product = p
                    self.shapeIdentity = p.shapeFrame == nil ? nil : shapeChoice
                    self.productInputs = inputs
                    self.state.resultRevision += 1
                    if p.lowRes.enabled {
                        self.state.lowResExclusion = LowResExclusion(selection: selection, assetIDs: p.lowRes.excludedAssetIDs)
                    }
                    // 生成前按已知数没提示过「照片比较少」、筛选后才不足 200 张 → 结果页补提示。
                    let promptedBefore = self.gateAvailable.map { MaterialSupply.evaluate(availableCount: $0).needsWarning } ?? false
                    self.state.postFilterShortageNotice = p.outcome.isBelowThresholdAfterFilter && !promptedBefore
                }
                self.send(.succeeded(runID: id, p.outcome))
            } catch {
                continuation.finish()
                stageContinuation.finish()
                guard let self else { return }
                if let e = error as? NoSharpPhotosError, self.state.flow.generation.currentRunID == id {
                    self.state.lowResExclusion = LowResExclusion(selection: selection, assetIDs: e.excludedAssetIDs)
                }
                let failure = GenerationFailure.classify(error)
                if failure == .albumUnreadable, self.state.flow.generation.currentRunID == id {
                    let old = self.state.flow.source.selection
                    self.state.flow.source.albumsBecameUnreadable()
                    self.silentSelectionPruned(from: old)
                }
                self.send(.finishedWithError(runID: id, failure: failure))
            }
            if let self, self.state.flow.generation.currentRunID == nil { self.generationTask = nil }
        }
    }

    // MARK: - 导出 / 保存 / 分享（T8）

    /// 能否开始导出：有结果、没有在生成、没有在导出。
    /// 照片拼图还要有用户选的目标图。形状拼图的目标图是生成时合成的，不经过 `setTarget`，没有用户目标图也要能导出。
    public var canExport: Bool {
        guard let product, !state.isGenerating, !state.export.isBusy else { return false }
        if product.shapeFrame == nil, target == nil { return false }
        guard case .result = state.flow.generation.phase else { return false }
        return resultMatchesCurrentParameters
    }

    /// 当前界面上的形状、配色、密度、素材是不是这张结果生成时用的。
    /// 只改了背景会直接写进结果，仍然算同一张。改了配色或密度还没重新生成时，旧图不能再导出。
    public var resultMatchesCurrentParameters: Bool {
        guard product != nil, let inputs = productInputs else { return false }
        if inputs != currentInputs { return false }
        if let choice = state.flow.shape, let background = product?.shapeFrame?.background, choice.background != background {
            return false
        }
        return true
    }

    /// 形状结果还在，但形状、配色或密度已经改了，新的生成还没完成。
    public var shapeEditsNeedRegeneration: Bool {
        guard state.flow.shape != nil, product?.shapeFrame != nil else { return false }
        return !resultMatchesCurrentParameters
    }

    /// 当前结果固化成的布局（导出、「存到我的作品」都用它）。
    public func currentLayout() -> MosaicLayout? {
        product.map { MosaicLayout(product: $0, overlayAlpha: state.flow.settings.overlayAlpha) }
    }

    /// 「保存到相册」（结果页）。判断顺序：权限 > 空间 > 其他（文案 §5.3）。
    public func saveTapped() async {
        guard canExport, let layout = currentLayout() else { return }
        exportSource = ExportSource(layout: layout, target: target)
        await startSave()
    }

    /// 「分享」（结果页）：导出到临时文件后交给系统分享面板（不需要相册权限）。
    public func shareTapped() {
        guard canExport, let layout = currentLayout() else { return }
        exportSource = ExportSource(layout: layout, target: target)
        startShare()
    }

    /// 从任意布局导出（「我的作品」查看页用：给保存的布局 + 目标图副本）。档位用 `state.exportTier`。
    /// `fallbacks`：作品兜底格（`ExportRequest.cellFallbacks`）。
    public func export(layout: MosaicLayout, target: PixelBuffer?, fallbacks: [Int: PixelBuffer] = [:], purpose: ExportPurpose) async {
        guard !state.export.isBusy, !state.isGenerating, layout.isValid else { return }
        exportSource = ExportSource(layout: layout, target: target, fallbacks: fallbacks)
        switch purpose {
        case .save: await startSave()
        case .share: startShare()
        }
    }

    private func startSave() async {
        guard !state.export.isBusy, exportSource != nil else { return }
        state.export = .exporting(.save, fraction: 0)
        var add = dependencies.library.addOnlyAuthorizationStatus()
        if add == .notDetermined { add = await dependencies.library.requestAddOnlyAuthorization() }
        guard add == .authorized || add == .limited else {
            lastExportPurpose = .save
            state.export = .failed(.addDenied)
            return
        }
        beginExport(.save)
    }

    private func startShare() {
        guard !state.export.isBusy, exportSource != nil else { return }
        state.export = .exporting(.share, fraction: 0)
        beginExport(.share)
    }

    private func restart(_ purpose: ExportPurpose) async {
        if purpose == .share { startShare() } else { await startSave() }
    }

    /// 分享面板关闭：删临时文件。
    public func shareFinished() {
        if case .sharing(let url) = state.export { dependencies.exporter.discard(url) }
        state.export = .idle
    }

    /// 关闭保存结果 / 失败提示。
    public func dismissExportResult() {
        guard !state.export.isBusy else { return }
        if case .sharing = state.export { shareFinished(); return }
        state.export = .idle
    }

    /// 失败提示的主按钮（文案 §5.3）：权限被拒 →「去设置」；空间不足 →「我知道了」；其他 →「再试一次」（同一用途重来）。
    public func exportFailurePrimaryTapped() async {
        guard case .failed(let f) = state.export else { return }
        state.export = .idle
        switch f {
        case .addDenied: systemActionHandler?(.openSettings)
        case .diskFull: break
        case .other: await restart(lastExportPurpose)
        }
    }

    /// 用户在导出中取消（若平台层提供入口）。
    public func cancelExport() {
        exportInterruptedByBackground = false
        exportTask?.cancel()
    }

    private func beginExport(_ purpose: ExportPurpose) {
        lastExportPurpose = purpose
        guard let source = exportSource else { state.export = .failed(.other); return }
        let exporter = dependencies.exporter
        let library = dependencies.library
        let onSucceeded = dependencies.onExportSucceeded
        let request = ExportRequest(layout: source.layout, target: source.target,
                                    overlayAlpha: source.target == nil ? 0 : source.layout.params.overlayAlpha,
                                    tier: state.exportTier, cellFallbacks: source.fallbacks)
        if let free = exporter.availableBytes(), free < exporter.estimatedBytes(for: request) {
            state.export = .failed(.diskFull)
            return
        }
        exportInterruptedByBackground = false
        dependencies.lifecycle.beginBackgroundWork(.export)
        let token = beginMemory(.export)
        let (fractions, continuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let progress: @Sendable (Double) -> Void = { continuation.yield($0) }
        let consumer = Task { @MainActor [weak self] in
            for await f in fractions { self?.exportProgressed(purpose, f) }
        }
        exportTask = Task { [weak self] in
            let outcome: ExportPhase
            do {
                let url = try await exporter.export(request, progress: progress)
                // 「导出成功」通知只在真正成功后发（原来在写相册之前就发，写相册失败也会触发，QA works-rules 规则 3）。
                // 「我的作品」那边只用它刷新按钮，不再自动存（AndyL 11-16 22:20，B10-1）。
                switch purpose {
                case .share:
                    await onSucceeded(source.layout, url)
                    outcome = .sharing(url)
                case .save:
                    do {
                        try await library.saveImageToLibrary(fileURL: url)
                        await onSucceeded(source.layout, url)
                        outcome = .saved
                    } catch {
                        outcome = .failed(SaveFailure.classify(error, addOnlyAuthorization: library.addOnlyAuthorizationStatus()))
                    }
                    exporter.discard(url)
                }
            } catch is CancellationError {
                outcome = (self?.exportInterruptedByBackground ?? false) ? .interrupted : .idle
            } catch let e as ExportError where e == .insufficientStorage {
                outcome = .failed(.diskFull)
            } catch {
                outcome = .failed(.other)
            }
            continuation.finish()
            await consumer.value
            guard let self else { return }
            self.state.export = outcome
            self.endMemory(token)
            self.dependencies.lifecycle.endBackgroundWork(.export)
            self.exportTask = nil
        }
    }

    private func exportProgressed(_ purpose: ExportPurpose, _ f: Double) {
        if case .exporting(let p, let old) = state.export, p == purpose, f > old { state.export = .exporting(p, fraction: f) }
    }

    // MARK: - 前后台

    public func handle(_ event: LifecycleEvent) async {
        switch event {
        case .enteredBackground:
            // 决定 5：进后台释放预取；G-3：扫描中的新行立即落盘（被系统杀掉也不丢）
            await dependencies.thumbnails.stopAllCaching()
            await index.requestCheckpoint()
        case .becameActive:
            refreshAuthorization()
            send(.becameActive)
            apply(state.scan.send(.becameActive))
            await refreshStatus()
        case .backgroundTimeExpired(.scan):
            apply(state.scan.send(.backgroundExpired))
        case .backgroundTimeExpired(.generate):
            send(.enteredBackground)
        case .backgroundTimeExpired(.export):
            if exportTask != nil {
                exportInterruptedByBackground = true
                exportTask?.cancel()
            }
        }
    }

    // MARK: - 内存采样（MF-7）

    private func beginMemory(_ phase: MemoryPhase) -> PeakMemoryTracker.Token {
        let token = memory.begin(phase)
        if memorySamplingTask == nil {
            let clock = dependencies.clock
            let tracker = memory
            memorySamplingTask = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    do { try await clock.sleep(seconds: PeakMemoryTracker.samplingInterval) } catch { return }
                    tracker.sample()
                }
            }
        }
        return token
    }

    private func endMemory(_ token: PeakMemoryTracker.Token) {
        memory.end(token)
        if !memory.isSampling {
            memorySamplingTask?.cancel()
            memorySamplingTask = nil
        }
    }

    // MARK: - 收尾

    /// 等所有在途工作（加载 / 扫描 / 生成 / 导出，含已取消未结束的）收尾。测试与「退出前落盘」都用它。
    public func settle() async {
        for _ in 0..<64 {
            let tasks = [loadTask, albumsLoadTask, scanTask, generationTask, exportTask].compactMap { $0 } + retiring
            retiring.removeAll()
            if tasks.isEmpty { return }
            for t in tasks { await t.value }
            // 运行中的生成任务在结果到达后不置 nil（currentRunID 仍在）——已完成就当作收尾
            if scanTask == nil, exportTask == nil, loadTask == nil, albumsLoadTask == nil, retiring.isEmpty { return }
        }
    }

    /// 停掉生命周期订阅与采样（App 不会调用；测试结束时释放）。
    public func stop() {
        lifecycleTask?.cancel()
        memorySamplingTask?.cancel()
        debounceTask?.cancel()
        scanTask?.cancel()
        generationTask?.cancel()
        exportTask?.cancel()
    }
}

/// 一次导出的输入（布局 + 叠加用目标图）。
struct ExportSource: Sendable {
    var layout: MosaicLayout
    var target: PixelBuffer?
    var fallbacks: [Int: PixelBuffer] = [:]
}

extension GenerationMachine.Phase {
    public var isReshuffle: Bool {
        switch self {
        case .running(_, _, let r), .confirmingCancel(_, _, let r), .suspended(_, let r): return r
        default: return false
        }
    }
}
