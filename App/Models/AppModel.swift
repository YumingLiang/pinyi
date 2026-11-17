import Foundation
import MosaicCore
import MosaicAppCore
import SwiftUI

/// SwiftUI 适配层（架构师 G-3）：所有判断、状态机、并发编排都在 MosaicAppCore 的 `AppCoordinator`（Linux 上有单测 + TSan）。
/// 本类型只做三件事：① 把 `coordinator.state` 转发给视图；② 把手势转成 coordinator 方法；③ 平台专属的图像工作
/// （目标图解码、预览绘制、系统动作）。⚠️ 盲写。
@MainActor
final class AppModel: ObservableObject {
    let coordinator: AppCoordinator
    let buildFlags: BuildFlags
    let perf: PerfRecorder
    let lifecycle: AppLifecycle
    private let thumbnails: PhotoKitThumbnails
    /// 「我的作品」（逻辑在 MosaicAppCore 的 `WorksController`）。
    let works: WorksModel

    @Published private(set) var state: AppState
    @Published private(set) var targetPreview: CGImage?
    @Published private(set) var resultImage: CGImage?

    /// 结果页缩放状态：放在模型里，视图重建 / 旋转 / 切后台都不丢；换新作品时复位。
    @Published var resultZoom = ZoomState()

    /// 当前作品的网格列 / 行数（缩放上限用）；没有作品时为 0。
    var previewGrid: (columns: Int, rows: Int) {
        guard let layout = coordinator.product?.generation.layout else { return (0, 0) }
        return (layout.columns, layout.rows)
    }

    private var renderedRevision = 0
    private var previewTask: Task<Void, Never>?
    private var changeObserver: LibraryChangeObserver?

    init(buildFlags: BuildFlags) {
        self.buildFlags = buildFlags
        let perf = PerfRecorder()
        let lifecycle = AppLifecycle()
        let thumbnails = PhotoKitThumbnails()
        self.perf = perf
        self.lifecycle = lifecycle
        self.thumbnails = thumbnails
        // 导出成功 → 中继 → WorksController 自动存（AppDependencies 先于协调器创建，所以经中继转）
        let relay = ExportSuccessRelay()
        let coordinator = AppCoordinator(dependencies: .live(lifecycle: lifecycle, thumbnails: thumbnails, perf: perf,
                                                             onExportSucceeded: relay.handler))
        self.coordinator = coordinator
        let worksController = WorksController(store: FileWorksStore(directory: WorksLocation.directory,
                                                                    images: ImageIOWorkImages(thumbnails: thumbnails)),
                                              existence: PhotoKitExistenceChecker(),
                                              images: ImageIOWorkImages(thumbnails: thumbnails))
        worksController.attach(resultContext: { [weak coordinator] in
            guard let c = coordinator else {
                return WorkResultContext(layout: nil, target: nil, overlayAlpha: 0, tier: nil, resultRevision: 0)
            }
            return c.workResultContext
        }, relay: relay)
        worksController.exportHandler = CoordinatorWorkExporter(coordinator: coordinator)
        coordinator.resultSaver = worksController   // 「再拼一张」未保存提示：问存没存过 / 去存（弱引用）
        self.works = WorksModel(controller: worksController)
        self.state = coordinator.state
        coordinator.systemActionHandler = { action in
            switch action {
            case .openSettings: SystemActions.openSettings()
            case .presentLimitedPicker: SystemActions.presentLimitedLibraryPicker()
            }
        }
        coordinator.observe { [weak self] s in self?.stateChanged(s) }
    }

    private func stateChanged(_ s: AppState) {
        syncTargetPreview(old: state, new: s)
        state = s
        works.controller.resultDidChange(revision: s.resultRevision)
        if s.flow.step == .result {
            if s.resultRevision != renderedRevision {
                renderedRevision = s.resultRevision
                renderPreview()
            }
        } else {
            // 离开结果页就丢掉预览位图（长边约 4096 时 RGBA 约 64 MB），换新结果时也会先走这里再重画。
            releasePreviewImage()
        }
        if !s.hasResult, resultImage != nil || previewTask != nil {
            // 结果被丢弃（「再拼一张」开始生成新图 / 返回首页）：取消在途绘制，释放预览位图（可能约 48 MB）。
            previewTask?.cancel()
            previewTask = nil
            resultImage = nil
        }
        if case .main = s.route, changeObserver == nil {
            changeObserver = LibraryChangeObserver { [weak self] in
                Task { @MainActor in self?.coordinator.libraryDidChange() }
            }
        }
    }

    // MARK: 视图读取（转发）

    var route: AppRoute { state.route }
    var onboarding: OnboardingFlow { state.onboarding }
    var indexStatus: IndexStatus { state.indexStatus }
    var scan: ScanFlow { state.scan }
    var albumRows: [SourceRow] { state.displayedAlbumRows }   // 可用张数已减去清晰度筛选排除的
    var postFilterShortageNotice: Bool { state.postFilterShortageNotice }
    var flow: MainFlow { state.flow }
    var emptyState: LibraryEmptyState? { state.emptyState }
    var transientNotice: L10nKey? { state.transientNotice }
    var access: SourceAccess { state.access }
    var allPhotosRow: SourceRow { state.allPhotosRow }
    var authorization: PhotoAuthorization { state.authorization }
    var sourceLowResLine: LocalizedLine? { state.sourceLowResLine }
    var generationProgressBodyKey: L10nKey { state.generationProgressBodyKey }

    var showScanSheet: Bool {
        get { state.showScanSheet }
        set { coordinator.setShowScanSheet(newValue) }
    }
    var presentedEmptyState: LibraryEmptyState? {
        get { state.presentedEmptyState }
        set { coordinator.setPresentedEmptyState(newValue) }
    }
    var overlayAlpha: Double {
        get { state.flow.settings.overlayAlpha }
        set { coordinator.setOverlayAlpha(newValue) }
    }

    // MARK: 动作（转发）

    func start() async {
        coordinator.start()
        await works.start()
    }
    func scenePhaseChanged(_ phase: ScenePhase) { lifecycle.scenePhaseChanged(phase) }
    func onboardingButtonTapped() { Task { await coordinator.onboardingButtonTapped() } }
    func onboardingSwiped(to page: Int) { coordinator.onboardingSwiped(to: page) }
    func permissionAction(_ action: PermissionAction, on prompt: PermissionPrompt) {
        Task { await coordinator.permissionAction(action, on: prompt) }
    }
    func startScan() { coordinator.startScan() }
    func scanCancelTapped() { coordinator.scanCancelTapped() }
    func scanCancelDismissed() { coordinator.scanCancelDismissed() }
    func scanCancelConfirmed() { coordinator.scanCancelConfirmed() }
    func refreshAlbums() async { await coordinator.refreshAlbums() }
    func flowSend(_ e: MainFlow.Event) { coordinator.flowSend(e) }
    func selectSource(_ s: SourceSelection) { coordinator.selectSource(s) }
    func setDensity(_ d: DensityChoice) { coordinator.setDensity(d) }
    func generateTapped() { Task { await coordinator.generateTapped() } }
    /// 失败页「再试一次」：走协调器，用筛选后的可用张数（不要直接 `send(.retryTapped(available: indexStatus.available))`）。
    func retryTapped() { Task { await coordinator.retryTapped() } }

    // MARK: 再拼一张（需求 v0.4 §2e；判断全在 AppCoordinator+QuickAgain）

    var canStartNewMosaic: Bool { state.canStartNewMosaic }
    var unsavedPrompt: UnsavedResultPrompt? { state.unsavedPrompt }
    func startNewMosaicTapped() { coordinator.startNewMosaicTapped() }
    func leaveResultTapped() { coordinator.leaveResultTapped() }
    func unsavedPromptSave() { Task { await coordinator.unsavedPromptSave() } }
    func unsavedPromptDiscard() { coordinator.unsavedPromptDiscard() }
    func unsavedPromptCancel() { coordinator.unsavedPromptCancel() }
    /// 确认页「素材：{name} · {count} 张」。
    var materialSummary: LocalizedLine {
        state.materialSummary(allPhotosTitle: (allPhotosRow.titleKey ?? .sourceListAll).localized)
    }

    // MARK: 导出（紧急版：只保存到相册；失败/重试走协调器，作品页再导出才能保留 exportSource）

    var exportPhase: ExportPhase { state.export }
    var exportTier: ExportTier {
        get { state.exportTier }
        set { coordinator.setExportTier(newValue) }
    }
    var canExport: Bool { coordinator.canExport }
    func saveTapped() { Task { await coordinator.saveTapped() } }
    func exportFailurePrimaryTapped() { Task { await coordinator.exportFailurePrimaryTapped() } }
    func dismissExportResult() { coordinator.dismissExportResult() }
    func send(_ e: GenerationMachine.Event) { coordinator.send(e) }

    // MARK: 平台专属：目标图 / 预览

    func loadTarget(data: Data?) {
        let t0 = perf.clock.now()
        guard let data, let pb = ImagePixels.downsampledTarget(from: data) else {
            coordinator.setTarget(nil)
            return
        }
        perf.record(.targetDecode, seconds: perf.clock.now() - t0, items: pb.width * pb.height)
        targetPreview = ImagePixels.cgImage(pb)
        coordinator.setTarget(pb)
    }

    /// 「再拼一张」开始前的目标图缩略图：返回预览页时换回来；开始生成新图后丢掉。
    private var previousTargetPreview: CGImage?

    /// 「再拼一张」状态变化时同步目标图缩略图（选图页只显示新选的那张）。
    private func syncTargetPreview(old: AppState, new: AppState) {
        if !old.flow.isQuickAgain, new.flow.isQuickAgain {
            previousTargetPreview = targetPreview
            targetPreview = nil
        } else if old.flow.isQuickAgain, !new.flow.isQuickAgain {
            if new.flow.step == .result {
                targetPreview = previousTargetPreview   // 返回原预览页
            }
            previousTargetPreview = nil
        }
    }

    /// 取消未完成的缩略图绘制，并释放 `resultImage`。
    private func releasePreviewImage() {
        previewTask?.cancel()
        previewTask = nil
        if resultImage != nil { resultImage = nil }
        renderedRevision = 0
    }

    private func renderPreview() {
        previewTask?.cancel()
        previewTask = nil
        resultZoom.reset()
        guard let product = coordinator.product, let target = coordinator.target else {
            resultImage = nil
            return
        }
        // 先换成小色块占位，立刻丢掉上一张大预览图。
        resultImage = MosaicPreviewRenderer.colorBlocks(product)
        let alpha = state.flow.settings.overlayAlpha
        let thumbs = thumbnails
        let perf = self.perf
        let revision = renderedRevision
        previewTask = Task { [weak self] in
            let t0 = perf.clock.now()
            let img = await MosaicPreviewRenderer.thumbnails(product, target: target, overlayAlpha: alpha, thumbnails: thumbs)
            perf.record(.previewRender, seconds: perf.clock.now() - t0, items: product.generation.layout.cellCount)
            // 离开页面时 revision 已清零；过期任务即使取消信号晚到也不会把大图写回去。
            guard let self, self.renderedRevision == revision, !Task.isCancelled else { return }
            if let img { self.resultImage = img }
        }
    }
}
