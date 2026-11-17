import CoreGraphics
import Foundation
import SwiftUI
import MosaicCore
import MosaicAppCore

/// 「我的作品」的 SwiftUI 适配层：只转发 `WorksController.state`、把手势转成方法调用、解码预览图。
/// 判断与编排都在 MosaicAppCore 的 `WorksController`（Linux 单测）。⚠️ 盲写。
@MainActor
final class WorksModel: ObservableObject {
    let controller: WorksController
    @Published private(set) var state: WorksState
    /// 查看页的缩放状态（复用结果页的 `ZoomState` / `ZoomableContainer`；换作品时复位）。
    @Published var detailZoom = ZoomState()
    /// 查看页的预览图（长边 2732）。
    @Published private(set) var openedPreview: CGImage?

    init(controller: WorksController) {
        self.controller = controller
        self.state = controller.state
        controller.observe { [weak self] s in self?.stateChanged(s) }
    }

    private func stateChanged(_ s: WorksState) {
        let previousOpened = state.opened?.id
        let previousSummary = state.opened?.summary   // 更新叠加后预览文件名不变，按 meta 判断要不要重解码
        state = s
        if s.opened?.id != previousOpened { detailZoom.reset() }
        // 换了作品、缺图处理后预览重画了（文件名会变），或只改叠加强度更新了原作品（meta 变）：重新解码
        if s.opened?.id != previousOpened || s.opened?.summary != previousSummary {
            // 旧版兜底还没迁移（预览可能带隐藏照片的像素）：不解码旧预览，查看页显示占位（转圈），迁移重画后再解码
            openedPreview = s.opened.flatMap {
                $0.summary.showsPlaceholder ? nil
                    : ImageIOWorkImages.loadImage($0.summary.previewURL, maxPixel: WorkImageLimits.previewLongEdge)
            }
        }
    }

    var summaries: [WorkSummary] { state.summaries }

    func start() async { await controller.start() }
    func open(_ id: WorkID) async { await controller.open(id) }
    func close() { controller.close() }
    func libraryDidChange() { controller.libraryDidChange() }
    func saveCurrentResult() { Task { await controller.saveCurrentResultTapped() } }
    func exportOpened(_ purpose: ExportPurpose) { Task { await controller.exportOpenedTapped(purpose: purpose) } }
    func deleteTapped(_ id: WorkID) { controller.deleteTapped(id) }
    func deleteCancelled() { controller.deleteCancelled() }
    func deleteConfirmed(_ id: WorkID) { Task { await controller.deleteConfirmed(id) } }
    func dismissNotice() { controller.dismissNotice() }

    /// 列表缩略图（降采样解码，约 2 列 × 3x 屏幕密度）。
    /// 旧版兜底还没迁移的作品显示占位（灰底），不显示旧预览（打开后迁移重画，列表随之刷新）。
    func thumbnail(for summary: WorkSummary) -> CGImage? {
        guard !summary.showsPlaceholder else { return nil }
        return ImageIOWorkImages.loadImage(summary.previewURL, maxPixel: 600)
    }

    /// 「11月16日」。
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
