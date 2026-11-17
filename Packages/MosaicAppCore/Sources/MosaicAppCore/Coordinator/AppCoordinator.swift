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
        didSet { if state != oldValue { notify() } }
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
    /// 「存到我的作品」（`WorksController`）：未保存提示要问它当前结果存没存过、以及「保存」按钮去存。弱引用，不成环。
    public weak var resultSaver: (any CurrentResultSaving)?
    /// 平台层执行系统动作（打开设置、受限选择器）。
    public var systemActionHandler: (@MainActor (SystemAction) -> Void)?

    private var observers: [UUID: @MainActor (AppState) -> Void] = [:]
    private var started = false
    private var loadTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    /// 最近一次「开始拼图」时用于 200 张门槛判断的张数（筛选后的已知数）。
    private var gateAvailable: Int?
    private var exportTask: Task<Void, Never>?
    private var lastExportPurpose: ExportPurpose = .save
    private var exportSource: ExportSource?
    /// 本次导出的是不是结果页上的当前结果（作品页再导出不算）。
    private var exportSourceIsCurrentResult = false
    private var lifecycleTask: Task<Void, Never>?
    private var memorySamplingTask: Task<Void, Never>?
    /// 被取消、尚未结束的任务（`settle()` 等它们收尾）。
    private var retiring: [Task<Void, Never>] = []
    private var generateGatePending = false
    private var exportInterruptedByBackground = false
    private var memoryTokens: [MemoryPhase: PeakMemoryTracker.Token] = [:]
    private var changeDebouncer = ChangeDebouncer(interval: 2, maxDelay: 10)
    private var debounceTask: Task<Void, Never>?

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.index = PhotoIndex(store: dependencies.indexStore, library: dependencies.library,
                                thumbnails: dependencies.thumbnails, configuration: dependencies.indexConfiguration,
                                perf: dependencies.perf, clock: dependencies.clock.monotonic)
        self.memory = PeakMemoryTracker(reader: dependencies.memory)
        self.state = AppState(initialSeed: dependencies.initialSeed)
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
        for a in albums {
            if let ids = try? await library.assetIDs(inAlbum: a.id) { avail[a.id] = await index.availableCount(assetIDs: ids) }
        }
        state.albumRows = SourceListLogic.albumRows(albums, availableByAlbum: avail,
                                                    scanComplete: SourceListLogic.isScanComplete(state.indexStatus))
        state.flow.source.reconcile(with: [state.allPhotosRow] + state.albumRows)
        await pruneLowResExclusion()
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
        if state.flow.isQuickAgain {
            pendingTarget = pixels   // 上一张结果还在，它的目标图不能动
        } else {
            target = pixels
        }
        state.flow.send(pixels == nil ? .targetFailed : .targetLoaded)
    }

    public func flowSend(_ e: MainFlow.Event) {
        guard !state.export.isBusy else { return }
        state.flow.send(e)
    }
    public func selectSource(_ s: SourceSelection) { state.flow.source.select(s) }
    public func setDensity(_ d: DensityChoice) { state.flow.settings.density = d }
    public func setOverlayAlpha(_ a: Double) { state.flow.settings.overlayAlpha = OverlayBlendLimits.clamp(a) }
    public func setShowScanSheet(_ on: Bool) { state.showScanSheet = on }
    public func setPresentedEmptyState(_ e: LibraryEmptyState?) { state.presentedEmptyState = e }
    public func setExportTier(_ t: ExportTier) {
        guard !state.export.isBusy else { return }
        state.exportTier = t
    }

    // MARK: - 生成

    /// 「开始拼图」。并发点击只处理第一次（互斥）；导出进行中忽略。
    public func generateTapped() async {
        guard !generateGatePending, !state.export.isBusy, !state.isGenerating else { return }
        // 结果页上（phase 仍是 `.result`）只有「再拼一张」的确认页能开始新图。
        if case .result = state.flow.generation.phase, !state.flow.isQuickAgain { return }
        generateGatePending = true
        defer { generateGatePending = false }
        if let load = loadTask { await load.value }
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
        await refreshStatus()
        let (avail, _) = await sourceCounts()
        let after = postFilterAvailable(avail)
        gateAvailable = after
        send(.retryTapped(available: after))
    }

    private func sourceCounts() async -> (Int, Int) {
        switch state.flow.source.selection {
        case .allPhotos: return (state.indexStatus.available, state.indexStatus.assetTotal ?? 0)
        case .album(let id):
            guard let ids = try? await dependencies.library.assetIDs(inAlbum: id) else { return (0, 0) }
            return (await index.availableCount(assetIDs: ids), ids.count)
        }
    }

    /// 索引可用张数减去该来源已知不够清楚的张数（「开始拼图」与失败后「再试一次」共用）。
    private func postFilterAvailable(_ raw: Int) -> Int {
        max(0, raw - state.knownLowResCount(for: state.flow.source.selection))
    }

    /// 相册 / 索引更新后：丢掉已经不在该来源里的排除 ID，重算来源页张数。
    private func pruneLowResExclusion() async {
        guard let e = state.lowResExclusion else { return }
        let current: Set<String>
        switch e.selection {
        case .allPhotos:
            current = await index.indexedAssetIDs()
        case .album(let id):
            current = Set((try? await dependencies.library.assetIDs(inAlbum: id)) ?? [])
        }
        let next = e.pruned(to: current)
        if next != e { state.lowResExclusion = next.count == 0 ? nil : next }
    }

    /// 生成状态机事件（UI 的取消 / 确认 / 换拼法 / 返回等都走这里）。
    public func send(_ e: GenerationMachine.Event) {
        if state.export.isBusy {
            switch e {
            case .startTapped, .retryTapped, .reshuffleTapped, .backToSettings: return   // 导出期间不动结果
            default: break
            }
        }
        let effects = state.flow.generation.send(e)
        // 「再拼一张」：真正开始生成新图（有 `.run`）时才丢弃上一张没存的结果和预览位图，换上新目标图。
        if state.flow.isQuickAgain, effects.contains(where: { if case .run = $0 { return true }; return false }) {
            commitQuickAgain()
        }
        state.flow.syncWithGeneration()
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
        guard let target else { send(.finishedWithError(runID: id, failure: .other)); return }
        let settings = state.flow.settings
        let selection = state.flow.source.selection
        let previous = state.flow.generation.phase.isReshuffle ? product : nil
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
                if let previous {
                    p = try await generator.reshuffle(previous, target: target, settings: settings, seed: seed,
                                                      progress: progress, stage: stage)
                } else {
                    let snap = try await index.snapshot(for: selection)
                    p = try await generator.run(target: target, snapshot: snap, settings: settings, seed: seed,
                                                progress: progress, stage: stage)
                }
                continuation.finish()
                stageContinuation.finish()
                await consumer.value
                await stageConsumer.value
                guard let self else { return }
                if self.state.flow.generation.currentRunID == id {
                    self.product = p
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
                    self.state.flow.source.albumBecameUnreadable()
                }
                self.send(.finishedWithError(runID: id, failure: failure))
            }
            if let self, self.state.flow.generation.currentRunID == nil { self.generationTask = nil }
        }
    }

    // MARK: - 导出 / 保存 / 分享（T8）

    /// 能否开始导出：有结果、没有在生成、没有在导出。
    public var canExport: Bool {
        guard product != nil, target != nil, !state.isGenerating, !state.export.isBusy else { return false }
        if case .result = state.flow.generation.phase { return true }
        return false
    }

    /// 当前结果固化成的布局（导出、「存到我的作品」都用它）。
    public func currentLayout() -> MosaicLayout? {
        product.map { MosaicLayout(product: $0, overlayAlpha: state.flow.settings.overlayAlpha) }
    }

    /// 「保存到相册」（结果页）。判断顺序：权限 > 空间 > 其他（文案 §5.3）。
    public func saveTapped() async {
        guard canExport, let layout = currentLayout() else { return }
        exportSource = ExportSource(layout: layout, target: target)
        exportSourceIsCurrentResult = true
        await startSave()
    }

    /// 「分享」（结果页）：导出到临时文件后交给系统分享面板（不需要相册权限）。
    public func shareTapped() {
        guard canExport, let layout = currentLayout() else { return }
        exportSource = ExportSource(layout: layout, target: target)
        exportSourceIsCurrentResult = true
        startShare()
    }

    /// 从任意布局导出（「我的作品」查看页用：给保存的布局 + 目标图副本）。档位用 `state.exportTier`。
    public func export(layout: MosaicLayout, target: PixelBuffer?, purpose: ExportPurpose) async {
        guard !state.export.isBusy, !state.isGenerating, layout.isValid else { return }
        exportSource = ExportSource(layout: layout, target: target)
        exportSourceIsCurrentResult = false
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
        let exportedRevision = exportSourceIsCurrentResult ? state.resultRevision : nil
        let request = ExportRequest(layout: source.layout, target: source.target,
                                    overlayAlpha: source.target == nil ? 0 : source.layout.params.overlayAlpha,
                                    tier: state.exportTier)
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
            var exportedOK = false
            do {
                let url = try await exporter.export(request, progress: progress)
                await onSucceeded(source.layout, url)
                // 导出成功（存相册 / 分享任一）：当前结果算「已导出」，「再拼一张」不再弹未保存提示（需求 v0.4 §2e）。
                exportedOK = true
                switch purpose {
                case .share:
                    outcome = .sharing(url)
                case .save:
                    do {
                        try await library.saveImageToLibrary(fileURL: url)
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
            if exportedOK, let rev = exportedRevision { self.state.resultExportedRevision = rev }
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
            let tasks = [loadTask, scanTask, generationTask, exportTask].compactMap { $0 } + retiring
            retiring.removeAll()
            if tasks.isEmpty { return }
            for t in tasks { await t.value }
            // 运行中的生成任务在结果到达后不置 nil（currentRunID 仍在）——已完成就当作收尾
            if scanTask == nil, exportTask == nil, loadTask == nil, retiring.isEmpty { return }
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
}

extension GenerationMachine.Phase {
    public var isReshuffle: Bool {
        switch self {
        case .running(_, _, let r), .confirmingCancel(_, _, let r), .suspended(_, let r): return r
        default: return false
        }
    }
}
