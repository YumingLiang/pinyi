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
    private let thumbnails: any ThumbnailProviding
    /// 「我的作品」（逻辑在 MosaicAppCore 的 `WorksController`）。
    let works: WorksModel
    /// 结果页预览清晰层（放大后按可见格子取 256 / 512 / 1024 px 方图，盖在底图上）。
    let detailLayer: PreviewDetailLayer

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
    /// 上次通知 WorksController 时的结果页现状（是否在结果页、revision、叠加强度），变了才重算按钮状态。
    private var lastWorksContext: (onResult: Bool, revision: Int, overlayAlpha: Double)?
    private var previewTask: Task<Void, Never>?
    private var changeObserver: LibraryChangeObserver?

    convenience init(buildFlags: BuildFlags) {
        let perf = PerfRecorder()
        let lifecycle = AppLifecycle()
        let thumbnails = PhotoKitThumbnails()
        let relay = ExportSuccessRelay()
        let dependencies = AppDependencies.live(lifecycle: lifecycle, thumbnails: thumbnails, perf: perf,
                                                 onExportSucceeded: relay.handler)
        self.init(buildFlags: buildFlags, dependencies: dependencies, detailThumbnails: thumbnails,
                  worksDirectory: WorksLocation.directory, lifecycle: lifecycle, relay: relay)
    }

    /// 与上面的生产构造同一套接线。测试传入合成依赖和临时作品目录，不读私人照片。
    init(buildFlags: BuildFlags, dependencies: AppDependencies, detailThumbnails: PhotoKitThumbnails,
         worksDirectory: URL, lifecycle: AppLifecycle, relay: ExportSuccessRelay) {
        self.buildFlags = buildFlags
        self.perf = dependencies.perf
        self.lifecycle = lifecycle
        self.thumbnails = dependencies.thumbnails
        self.detailLayer = PreviewDetailLayer(thumbnails: detailThumbnails, perf: dependencies.perf)
        let coordinator = AppCoordinator(dependencies: dependencies)
        self.coordinator = coordinator
        // 4b 补格：索引快照 + 生成用的同一套匹配器（一次匹配，不做逐张清晰度探测；架构师 11-17），零网络
        let runner = coordinator.dependencies.generator as? GenerationRunner
        let existence = PhotoKitExistenceChecker()
        let rematcher = IndexWorkRematcher(
            snapshot: { [weak coordinator] in
                guard let coordinator else { throw WorkRematchError.indexUnavailable }
                return try await coordinator.worksRematchSnapshot()
            },
            existence: existence,
            pipeline: runner?.pipeline ?? MosaicPipeline(assigner: GreedyAssigner(kernel: KernelProvider.make())))
        let worksController = WorksController(store: FileWorksStore(directory: worksDirectory,
                                                                    images: ImageIOWorkImages(thumbnails: dependencies.thumbnails)),
                                              existence: existence,
                                              images: ImageIOWorkImages(thumbnails: dependencies.thumbnails),
                                              rematcher: rematcher)
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
        // 「存到我的作品」按钮按当前结果 vs 作品库算（B10-5）：叠加强度变了 / 进出结果页时重算
        let worksContext = (onResult: s.flow.step == .result, revision: s.resultRevision, overlayAlpha: s.flow.settings.overlayAlpha)
        if lastWorksContext.map({ $0 != worksContext }) ?? true {
            lastWorksContext = worksContext
            works.controller.resultContextDidChange()
        }
        if s.flow.step == .result {
            if s.resultRevision != renderedRevision {
                renderedRevision = s.resultRevision
                renderPreview()
            }
        } else {
            // 离开结果页就丢掉预览位图（长边约 4096 时 RGBA 约 64 MB），换新结果时也会先走这里再重画。
            releasePreviewImage()
        }
        if !s.hasResult, resultImage != nil || previewTask != nil || detailOverlay != nil {
            // 结果被丢弃（「再拼一张」开始生成新图 / 返回首页）：取消在途绘制，释放预览位图（可能约 48 MB）。
            // 走 releasePreviewImage，连清晰层缓存一起清掉。
            releasePreviewImage()
        }
        if case .main = s.route, changeObserver == nil {
            changeObserver = LibraryChangeObserver { [weak self] in
                Task { @MainActor in
                    self?.coordinator.libraryDidChange()
                    self?.works.libraryDidChange()   // P3：相册变了，之前「重找过没找到」的作品下次打开再找
                }
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
    /// 来源是相簿、张数还没算出来：显示加载中（§2f 补充 3）。
    var isMaterialCountLoading: Bool { state.isMaterialCountLoading }
    /// 「开始拼图」在等相簿列表加载完（§2f 补充 3）。
    var isWaitingForAlbums: Bool { state.isWaitingForAlbums }
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
    func scenePhaseChanged(_ phase: ScenePhase) {
        lifecycle.scenePhaseChanged(phase)
        // 回到前台重读相册权限（v1.7a）：受限 ↔ 完整变了就刷新作品列表 / 查看页
        if phase == .active { Task { await works.refreshLibraryAccess() } }
    }
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
    // 相簿多选（§2f，判断在 AppCoordinator+MultiAlbum）
    func openAlbumList() { coordinator.openAlbumList() }
    func toggleAlbum(_ id: String) { coordinator.toggleAlbum(id) }
    func finishAlbumSelection() { coordinator.finishAlbumSelection() }
    func closeAlbumList() { coordinator.closeAlbumList() }
    func setDensity(_ d: DensityChoice) { coordinator.setDensity(d) }
    func beginShape() { coordinator.beginShape() }

    /// 文字参数直接生成。没有文字界面。失败在开跑前抛出，不改字、不截断。
    func generateText(lines: [String], palette: ShapePalette = .auto,
                      background: ShapeBackground = .white) async throws {
        let prepared = try TextComposition.prepare(lines)
        guard let outline = CoreTextOutline().outline(lines: prepared) else { throw TextComposeFailure.noOutline }
        do {
            try TextComposition.requireReadableHanzi(outline)
        } catch let failure as TextComposeFailure {
            throw failure
        } catch {
            throw TextComposeFailure.doesNotFit
        }
        coordinator.prepareText(lines: prepared, outline: outline, palette: palette, background: background)
        await coordinator.generateTapped()
    }
    func setShapePreset(_ id: ShapePresetID) { coordinator.setShapePreset(id) }
    func setShapePalette(_ palette: ShapePalette) { coordinator.setShapePalette(palette) }
    func setShapeBackground(_ background: ShapeBackground) { coordinator.setShapeBackground(background) }
    var allowsWorkSave: Bool { coordinator.allowsWorkSave }
    func generateTapped() { Task { await coordinator.generateTapped() } }
    /// 设置页主按钮（B10.14）：只改了叠加强度 →「完成」回原结果；否则「开始拼图」。
    var settingsPrimaryAction: SettingsPrimaryAction { coordinator.settingsPrimaryAction }
    /// 设置页「完成」：回到原结果，不重新生成（进结果页时按新强度重画预览）。
    func adjustDoneTapped() { Task { await coordinator.adjustDoneTapped() } }
    /// 失败页「再试一次」：走协调器，用筛选后的可用张数（不要直接 `send(.retryTapped(available: indexStatus.available))`）。
    func retryTapped() { Task { await coordinator.retryTapped() } }

    // MARK: 再拼一张（需求 v1.0 §2e；判断全在 AppCoordinator+QuickAgain）

    var canStartNewMosaic: Bool { state.canStartNewMosaic }
    var unsavedPrompt: UnsavedResultPrompt? { state.unsavedPrompt }
    /// 未保存提示是不是「存过但强度改了」那种（标题 `quick.unsaved.update_title`）。
    var unsavedPromptIsUpdate: Bool { state.unsavedPromptIsUpdate }
    /// 每次从作品查看页「再拼一张」+1：主流程导航栈按它重建，退回主流程。
    @Published private(set) var navigationResetToken = 0
    /// 作品查看页「再拼一张」（quick-start v1.0 §2a）：退回主流程，再走和预览页一样的「再拼一张」。
    func startNewFromWork(id: WorkID) {
        guard !state.isGenerating, !state.export.isBusy else { return }
        coordinator.startNewFromWorkTapped(workID: id)
        navigationResetToken += 1
    }
    func startNewMosaicTapped() { coordinator.startNewMosaicTapped() }
    func leaveResultTapped() { coordinator.leaveResultTapped() }
    func unsavedPromptSave() { coordinator.unsavedPromptSaveTapped() }
    func unsavedPromptDismissed() { coordinator.unsavedPromptDismissed() }
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
    /// 结果页只有这次成品已经显示出来，才提示双指放大。空白、失败、或参数已改还没重生成时不提示。
    var showsFinishedPreviewHint: Bool { resultImage != nil && canExport }
    /// 形状的配色或密度已经改了，旧结果还在，新的生成还没完成。
    var shapeEditsNeedRegeneration: Bool { coordinator.shapeEditsNeedRegeneration }
    func saveTapped() { Task { await coordinator.saveTapped() } }
    func exportFailurePrimaryTapped() { Task { await coordinator.exportFailurePrimaryTapped() } }
    func dismissExportResult() { coordinator.dismissExportResult() }
    func send(_ e: GenerationMachine.Event) { coordinator.send(e) }

    // MARK: 平台专属：目标图 / 预览

    // MARK: 系统选择器选的照片用不了（copy v1.6，判断在 AppCoordinator+PickerUnavailable）

    var showsPickerUnavailable: Bool { state.showsPickerUnavailable }
    /// 选图提示「取消」后要回到的作品查看页（从作品查看页发起的「再拼一张」）。
    var reopenWorkRequest: WorkReopenRequest? { state.reopenWorkRequest }
    var pickerUnavailableShowsAddAccess: Bool { state.pickerUnavailableShowsAddAccess }
    var targetPickerReopenRequest: Int { state.targetPickerReopenRequest }
    func pickedTargetUnavailable() { coordinator.pickedTargetUnavailable() }
    func pickerUnavailableChange() { coordinator.pickerUnavailableChangeTapped() }
    func pickerUnavailableCancel() { coordinator.pickerUnavailableCancelTapped() }
    func pickerUnavailableAddAccess() { coordinator.pickerUnavailableAddAccessTapped() }
    func pickerUnavailableDismissed() { coordinator.pickerUnavailableDismissed() }

    /// 系统选择器选好、已过 PickedTargetGate：解码失败同样弹 picker.unavailable（不区分原因）。
    func loadPickedTarget(data: Data?) {
        let t0 = perf.clock.now()
        guard let data, let pb = ImagePixels.downsampledTarget(from: data) else {
            coordinator.pickedTargetUnavailable()
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

    /// 取消未完成的缩略图绘制，并释放 `resultImage`；清晰层取消请求、清空缓存。
    private func releasePreviewImage() {
        previewTask?.cancel()
        previewTask = nil
        if resultImage != nil { resultImage = nil }
        detailOverlay = nil
        renderedRevision = 0
        detailLayer.reset()
    }

    /// 清晰层上的目标图叠加（裁剪区，和底图 / 导出同一个 cropRect）；α = 0 或没有作品时为 nil。
    @Published private(set) var detailOverlay: CGImage?

    /// 结果页缩放 / 平移变化（视图 `onChange(of: resultZoom)` 调）。
    func resultZoomChanged(displayScale: Double) {
        guard state.flow.step == .result, coordinator.product != nil else { return }
        detailLayer.zoomChanged(resultZoom, displayScale: displayScale)
    }

    private func renderPreview() {
        previewTask?.cancel()
        previewTask = nil
        resultZoom.reset()
        guard let product = coordinator.product else {
            resultImage = nil
            return
        }
        // 照片拼图必须有用户选的目标图。形状从「用形状拼」进来，不经过 setTarget。
        if product.shapeFrame == nil, coordinator.target == nil {
            resultImage = nil
            return
        }
        // 先换成小色块占位，立刻丢掉上一张大预览图。
        resultImage = MosaicPreviewRenderer.colorBlocks(product)
        let alpha = product.shapeFrame == nil ? state.flow.settings.overlayAlpha : 0
        let target = coordinator.target
        // 清晰层：换作品（含换拼法）清空缓存；准备叠加用的目标图裁剪区（与底图同一 cropRect、同一 α）。
        detailLayer.configure(product: product)
        detailOverlay = nil
        if OverlayBlendLimits.clamp(alpha) > 0, let target, let t = ImagePixels.cgImage(target) {
            let crop = product.generation.layout.cropRect
            // 长边 > 2048 先缩到 2048 再持有：放大后这一层本来就是糊的，和导出一致，避免结果页一直攥着一份 4096 目标图。
            var overlay = t.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height))
            if let img = overlay, max(img.width, img.height) > 2048,
               let scaled = ImagePixels.opaqueSRGB(img, maxEdge: 2048),
               let cg = ImagePixels.cgImage(scaled) {
                overlay = cg
            }
            detailOverlay = overlay
        }
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
