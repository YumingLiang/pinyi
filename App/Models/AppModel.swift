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

    @Published private(set) var state: AppState
    @Published private(set) var targetPreview: CGImage?
    @Published private(set) var resultImage: CGImage?
    /// T7：叠加用的目标图（已裁到网格区域）。预览里由 SwiftUI 以 `opacity(overlayAlpha)` 叠在马赛克上，
    /// 拖滑杆实时生效、不重画马赛克（导出时在条带里按同一 α 混合）。
    @Published private(set) var overlayImage: CGImage?

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
        let coordinator = AppCoordinator(dependencies: .live(lifecycle: lifecycle, thumbnails: thumbnails, perf: perf))
        self.coordinator = coordinator
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
        state = s
        if s.resultRevision != renderedRevision {
            renderedRevision = s.resultRevision
            renderPreview()
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
    var albumRows: [SourceRow] { state.albumRows }
    var flow: MainFlow { state.flow }
    var emptyState: LibraryEmptyState? { state.emptyState }
    var transientNotice: L10nKey? { state.transientNotice }
    var access: SourceAccess { state.access }
    var allPhotosRow: SourceRow { state.allPhotosRow }
    var authorization: PhotoAuthorization { state.authorization }

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
    var exportPhase: ExportPhase { state.export }
    var canExport: Bool { coordinator.canExport }

    // MARK: 动作（转发）

    func start() async { coordinator.start() }
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
    func send(_ e: GenerationMachine.Event) { coordinator.send(e) }

    // MARK: 导出 / 保存 / 分享（T8，逻辑在 AppCoordinator）

    func saveTapped() { Task { await coordinator.saveTapped() } }
    func shareTapped() { coordinator.shareTapped() }
    func shareFinished() { coordinator.shareFinished() }
    func dismissExportResult() { coordinator.dismissExportResult() }
    func cancelExport() { coordinator.cancelExport() }
    func exportFailurePrimaryTapped() { Task { await coordinator.exportFailurePrimaryTapped() } }
    func exportFailureSecondaryTapped() { coordinator.exportFailureSecondaryTapped() }
    func exportRetryTapped() { Task { await coordinator.exportRetryTapped() } }
    func saveSuccessShareTapped() { coordinator.saveSuccessShareTapped() }

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

    private func renderPreview() {
        guard let product = coordinator.product, let target = coordinator.target else { return }
        resultImage = MosaicPreviewRenderer.colorBlocks(product)
        overlayImage = MosaicPreviewRenderer.overlay(product, target: target)
        let thumbs = thumbnails
        let perf = self.perf
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let t0 = perf.clock.now()
            let img = await MosaicPreviewRenderer.thumbnails(product, target: target, overlayAlpha: 0, thumbnails: thumbs)
            perf.record(.previewRender, seconds: perf.clock.now() - t0, items: product.generation.layout.cellCount)
            if let img { self?.resultImage = img }
        }
    }
}
