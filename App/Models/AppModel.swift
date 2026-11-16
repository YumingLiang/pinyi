import Foundation
import MosaicCore
import MosaicAppCore
import SwiftUI

/// App 的顶层可观察模型：把 MosaicAppCore 的纯逻辑（reducer / 索引 actor）接到 SwiftUI 与 PhotoKit 适配器上。
/// 本类型只做"转发 + 执行副作用"，判断逻辑都在 MosaicAppCore（已在 Linux 上测试）。⚠️ 盲写。
@MainActor
final class AppModel: ObservableObject {
    // MARK: 依赖
    let library: PhotoKitLibrary
    let thumbnails: PhotoKitThumbnails
    let index: PhotoIndex
    let perf = PerfRecorder()
    let runner: GenerationRunner
    let buildFlags: BuildFlags

    // MARK: 状态（视图读取）
    @Published private(set) var route: AppRoute = .onboarding
    @Published var onboarding = OnboardingFlow()
    @Published private(set) var indexStatus = IndexStatus(assetTotal: nil, available: 0, pending: 0, unavailableLocal: 0, failed: 0,
                                                          isScanning: false, wasInterrupted: false, hasCompletedInitialScan: false)
    @Published private(set) var scan = ScanFlow()
    @Published private(set) var albumRows: [SourceRow] = []
    @Published var flow: MainFlow
    @Published private(set) var targetPreview: CGImage?
    @Published private(set) var resultImage: CGImage?
    @Published var showScanSheet = false
    /// 全库空状态（来源页内联显示）。
    @Published private(set) var emptyState: LibraryEmptyState?
    /// 点「开始拼图」被空状态拦下时弹出的页面。
    @Published var presentedEmptyState: LibraryEmptyState?
    @Published private(set) var transientNotice: L10nKey?

    private var target: PixelBuffer?
    private var product: GenerationProduct?
    private var scanTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let scanBackground = BackgroundTaskGuard()
    private let generationBackground = BackgroundTaskGuard()
    private var changeObserver: LibraryChangeObserver?
    private var changeTrigger: DebouncedTrigger?

    private enum Keys {
        static let onboardingDone = "onboarding.completed"
        static let limitedAck = "permission.limited.acknowledged"
    }

    init(buildFlags: BuildFlags) {
        self.buildFlags = buildFlags
        library = PhotoKitLibrary()
        thumbnails = PhotoKitThumbnails()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index", isDirectory: true)
        index = PhotoIndex(directory: support, library: library, thumbnails: thumbnails, perf: perf)
        runner = GenerationRunner(pipeline: MosaicPipeline(assigner: GreedyAssigner(kernel: KernelProvider.make())), perf: perf)
        flow = MainFlow(initialSeed: UInt64.random(in: 1...UInt64.max))
    }

    // MARK: 启动 / 路由

    func start() async {
        await index.load()
        await refreshStatus()
        resolveRoute()
    }

    func resolveRoute() {
        let d = UserDefaults.standard
        route = AppRoute.resolve(authorization: library.authorizationStatus(),
                                 hasCompletedOnboarding: d.bool(forKey: Keys.onboardingDone),
                                 limitedAcknowledged: d.bool(forKey: Keys.limitedAck))
        if case .main = route { beginLibraryWork() }
    }

    func onboardingButtonTapped() {
        let wasLast = onboarding.isLastPage
        let effect = onboarding.advance(authorization: library.authorizationStatus())
        guard wasLast else { return }
        UserDefaults.standard.set(true, forKey: Keys.onboardingDone)
        if let effect { perform(effect) } else { resolveRoute() }
    }

    func permissionAction(_ action: PermissionAction, on prompt: PermissionPrompt) {
        perform(PermissionLogic.effect(for: action, on: prompt))
    }

    private func perform(_ effect: PermissionEffect) {
        switch effect {
        case .requestAuthorization:
            Task {
                _ = await library.requestAuthorization()
                UserDefaults.standard.set(true, forKey: Keys.onboardingDone)
                resolveRoute()
            }
        case .openSettings: SystemActions.openSettings()
        case .presentLimitedPicker: SystemActions.presentLimitedLibraryPicker()
        case .showOnboarding:
            onboarding = OnboardingFlow()
            route = .onboarding
        case .proceed(let access):
            if access == .limited { UserDefaults.standard.set(true, forKey: Keys.limitedAck) }
            route = .main(access)
            beginLibraryWork()
        case .dismiss:
            break
        }
    }

    var access: SourceAccess {
        if case .main(let a) = route { return a }
        return .full
    }

    // MARK: 扫描

    private func beginLibraryWork() {
        if changeObserver == nil {
            let trigger = DebouncedTrigger { [weak self] in self?.startScan() }
            changeTrigger = trigger
            changeObserver = LibraryChangeObserver { Task { @MainActor in trigger.noteChange() } }
        }
        startScan()
    }

    func startScan() {
        guard scanTask == nil else { return }
        let first = !indexStatus.hasCompletedInitialScan && indexStatus.available == 0
        scan.send(.started(isFirstScan: first, isResuming: indexStatus.wasInterrupted))
        scanBackground.begin(name: "scan") { [weak self] in
            guard let self else { return }
            self.apply(self.scan.sendReturning(.backgroundExpired))
        }
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await index.synchronize { p in Task { @MainActor [weak self] in self?.scanProgressed(p) } }
                scan.send(.finished)
            } catch is CancellationError {
            } catch {
                scan.send(.failed)
            }
            scanTask = nil
            scanBackground.end()
            await refreshStatus()
            await refreshAlbums()
        }
    }

    private func scanProgressed(_ p: ScanProgress) {
        scan.send(.progressed(p))
        Task { await refreshStatus() }
    }

    func scanCancelTapped() { scan.send(.cancelTapped) }
    func scanCancelDismissed() { scan.send(.cancelDismissed) }
    func scanCancelConfirmed() { apply(scan.sendReturning(.cancelConfirmed)) }

    private func apply(_ effects: [ScanFlow.Effect]) {
        for e in effects {
            switch e {
            case .cancelScan: scanTask?.cancel()
            case .startScan: startScan()
            }
        }
    }

    func refreshStatus() async {
        indexStatus = await index.status()
        emptyState = LibraryEmptyState.evaluate(indexStatus)
        if let n = LibraryEmptyState.completionNotice(indexStatus) { transientNotice = n }
    }

    func refreshAlbums() async {
        let albums = await library.albums()
        var avail: [String: Int] = [:]
        for a in albums {
            if let ids = try? await library.assetIDs(inAlbum: a.id) { avail[a.id] = await index.availableCount(assetIDs: ids) }
        }
        albumRows = SourceListLogic.albumRows(albums, availableByAlbum: avail, scanComplete: SourceListLogic.isScanComplete(indexStatus))
        flow.source.reconcile(with: [allPhotosRow] + albumRows)
    }

    var allPhotosRow: SourceRow { SourceListLogic.allPhotosRow(access: access, status: indexStatus) }

    // MARK: 目标图

    func loadTarget(data: Data?) {
        let t0 = perf.clock.now()
        guard let data, let pb = ImagePixels.downsampledTarget(from: data) else {
            flow.send(.targetFailed)
            return
        }
        perf.record(.targetDecode, seconds: perf.clock.now() - t0, items: pb.width * pb.height)
        target = pb
        targetPreview = ImagePixels.cgImage(pb)
        flow.send(.targetLoaded)
    }

    // MARK: 生成

    func generateTapped() {
        Task {
            await refreshStatus()
            let (avail, total) = await sourceCounts()
            switch GenerateGate.decide(status: indexStatus, availableInSource: avail, sourceAssetTotal: total) {
            case .emptyState(let e): presentedEmptyState = e
            case .waitForScan: showScanSheet = true; startScan()
            case .proceed(let n): send(.startTapped(available: n))
            }
        }
    }

    private func sourceCounts() async -> (Int, Int) {
        switch flow.source.selection {
        case .allPhotos: return (indexStatus.available, indexStatus.assetTotal ?? 0)
        case .album(let id):
            guard let ids = try? await library.assetIDs(inAlbum: id) else { return (0, 0) }
            return (await index.availableCount(assetIDs: ids), ids.count)
        }
    }

    func send(_ e: GenerationMachine.Event) {
        let effects = flow.generation.send(e)
        flow.syncWithGeneration()
        for eff in effects {
            switch eff {
            case .run(let id, let seed): run(id: id, seed: seed)
            case .cancel: generationTask?.cancel(); generationTask = nil
            case .setGenerationActive(let on):
                Task { await index.setGenerationActive(on) }
                if on {
                    generationBackground.begin(name: "generate") { [weak self] in self?.send(.enteredBackground) }
                } else {
                    generationBackground.end()
                }
            }
        }
    }

    private func run(id: Int, seed: UInt64) {
        guard let target else { send(.finishedWithError(runID: id, failure: .other)); return }
        let settings = flow.settings
        let selection = flow.source.selection
        let previous = (flow.generation.phase.isReshuffle ? product : nil)
        let runner = self.runner
        let index = self.index
        generationTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let p: GenerationProduct
                let progress: @Sendable (Double) -> Void = { f in Task { @MainActor [weak self] in self?.send(.progressed(runID: id, fraction: f)) } }
                if let previous {
                    p = try await runner.reshuffle(previous, target: target, settings: settings, seed: seed, progress: progress)
                } else {
                    let snap = try await index.snapshot(for: selection)
                    p = try await runner.run(target: target, snapshot: snap, settings: settings, seed: seed, progress: progress)
                }
                await MainActor.run { [weak self] in
                    self?.product = p
                    self?.send(.succeeded(runID: id, p.outcome))
                    self?.renderPreview()
                }
            } catch {
                let failure = GenerationFailure.classify(error)
                await MainActor.run { [weak self] in
                    if failure == .albumUnreadable { self?.flow.source.albumBecameUnreadable() }
                    self?.send(.finishedWithError(runID: id, failure: failure))
                }
            }
        }
    }

    private func renderPreview() {
        guard let product, let target else { return }
        resultImage = MosaicPreviewRenderer.colorBlocks(product)
        let alpha = flow.settings.overlayAlpha
        let thumbs = thumbnails
        let perf = self.perf
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let t0 = perf.clock.now()
            let img = await MosaicPreviewRenderer.thumbnails(product, target: target, overlayAlpha: alpha, thumbnails: thumbs)
            perf.record(.previewRender, seconds: perf.clock.now() - t0, items: product.generation.layout.cellCount)
            if let img { self?.resultImage = img }
        }
    }

    // MARK: 前后台

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            thumbnails.stopAll()   // 决定 5：进后台释放预取
        case .active:
            send(.becameActive)
            apply(scan.sendReturning(.becameActive))
            Task { await refreshStatus() }
            if case .permission = route { resolveRoute() }   // 从系统设置回来
        default:
            break
        }
    }
}

extension GenerationMachine.Phase {
    var isReshuffle: Bool {
        switch self {
        case .running(_, _, let r), .confirmingCancel(_, _, let r), .suspended(_, let r): return r
        default: return false
        }
    }
}

extension ScanFlow {
    mutating func sendReturning(_ e: Event) -> [Effect] { send(e) }
}
