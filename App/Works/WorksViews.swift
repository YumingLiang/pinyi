import SwiftUI
import MosaicCore
import MosaicAppCore

/// 首页右上角入口（需求 B2）：「我的作品」，有作品时带数量。
struct WorksEntryButton: View {
    @EnvironmentObject var works: WorksModel

    var body: some View {
        NavigationLink { WorksListView() } label: {
            HStack(spacing: 4) {
                Text(L10nKey.worksEntry)
                if works.state.count > 0 {
                    Text(verbatim: "\(works.state.count)")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
        }
    }
}

/// 结果页次按钮「存到我的作品」（需求 B2 / B10）：导出不自动存，只有点这里才存。
/// 已存且没改动 → 「已存到我的作品」（`preview.saved_to_works`）不可点；只改了叠加强度 →「更新这张作品」（`works.update`），
/// 点了直接更新原作品、不弹确认，成功后约 2 秒的轻提示「已更新这张作品」（`works.updated`，控制器自动收起）。
struct SaveToWorksButton: View {
    @EnvironmentObject var works: WorksModel
    @EnvironmentObject var model: AppModel

    var body: some View {
        let status = works.state.saveStatus
        VStack(spacing: 4) {
            Button { works.saveCurrentResult() } label: {
                switch status {
                case .saved: Label { Text(L10nKey.previewSavedToWorks) } icon: { Image(systemName: "checkmark") }
                case .saving: ProgressView()
                case .needsUpdate: Text(L10nKey.worksUpdate)
                default: Text(L10nKey.previewSaveToWorks)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!status.isEnabled || !model.canExport)
            if status == .failed { Text(L10nKey.worksSaveFailed).font(.caption).foregroundStyle(.red) }
            if let toast = works.state.toast {
                Text(toast).font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }
        }
    }
}

/// 作品列表（需求 B3 / B5）：两列方格缩略图、按保存时间倒序、图下日期；空状态；底部常驻 `works.keep_hint`。
/// 长按格子 → 系统上下文菜单（预览就是格子本身的缩略图），只有一项「删除」（复用 `works.delete`，红色）→
/// 与查看页同一个确认框 `works.delete.confirm`。长按时把 id 存进视图状态 `deleteCandidate`，确认按钮带这个 id 调
/// `deleteConfirmed(id)`，不在按钮里现读 `pendingDelete`（弹窗收起时它会先被 `deleteCancelled()` 清掉）。
struct WorksListView: View {
    @EnvironmentObject var works: WorksModel
    /// 长按「删除」选中的作品（列表自己的确认框用）。
    @State private var deleteCandidate: WorkID?
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            if works.state.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(L10nKey.worksEmpty).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(works.summaries) { s in
                        NavigationLink { WorkDetailView(id: s.id) } label: { WorkCell(summary: s) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteCandidate = s.id
                                    works.deleteTapped(s.id)
                                } label: {
                                    Label { Text(L10nKey.worksDelete) } icon: { Image(systemName: "trash") }
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            Text(WorksState.keepHintKey)
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(24)
        }
        .navigationTitle(Text(L10nKey.worksNavTitle))
        .task { await works.controller.reload() }
        // 列表自己的确认框只看 deleteCandidate（查看页的确认框看 pendingDelete == 它的 id，两边不互相触发）
        .confirmationDialog(Text(L10nKey.worksDeleteConfirm),
                            isPresented: Binding(get: { deleteCandidate != nil },
                                                 set: { if !$0 { deleteCandidate = nil; works.deleteCancelled() } }),
                            titleVisibility: .visible,
                            presenting: deleteCandidate) { id in
            // id 是长按时存下的快照：收起弹窗时 set(false) 先清状态，按钮动作仍带着这个 id
            Button(role: .destructive) { works.deleteConfirmed(id) } label: { Text(L10nKey.worksDeleteConfirmOK) }
            Button(role: .cancel) { works.deleteCancelled() } label: { Text(L10nKey.commonCancel) }
        }
    }
}

struct WorkCell: View {
    @EnvironmentObject var works: WorksModel
    let summary: WorkSummary
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(verbatim: WorksModel.dateFormatter.string(from: summary.createdAt))
                .font(.caption).foregroundStyle(.secondary)
        }
        // 按 summary 整体（含 meta 的叠加强度 / updatedAt）重新解码：只改叠加强度更新原作品时 id 和预览文件名都不变
        .task(id: summary) { image = works.thumbnail(for: summary) }
    }
}

/// 作品查看页（需求 B4 / B5）：复用结果页的 `ZoomableContainer`（捏合累乘、双击逐级），看的是保存的 2732 预览图；
/// 底部「导出」「删除」；删除二次确认；原照片缺失时提示张数（`works.missing`）。
struct WorkDetailView: View {
    @EnvironmentObject var works: WorksModel
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: WorkID

    var body: some View {
        VStack(spacing: 12) {
            if let img = works.openedPreview, let opened = works.state.opened, opened.id == id {
                ZoomableContainer(aspectRatio: Double(img.width) / Double(max(1, img.height)),
                                  columns: opened.summary.meta.columns, rows: opened.summary.meta.rows,
                                  zoom: $works.detailZoom) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium).scaledToFit()
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
            if let line = works.state.missingLine {
                Text(line).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            HStack {
                Button { works.exportOpened(.save) } label: { Text(L10nKey.worksExport).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive) { works.deleteTapped(id) } label: { Text(L10nKey.worksDelete).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .disabled(works.state.opened?.id != id || model.exportPhase.isBusy)
        }
        .padding()
        .navigationTitle(Text(verbatim: works.state.opened.map { WorksModel.dateFormatter.string(from: $0.summary.createdAt) } ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await works.open(id) }
        .onDisappear { if works.state.opened?.id == id { works.close() } }
        .confirmationDialog(Text(L10nKey.worksDeleteConfirm),
                            isPresented: Binding(get: { works.state.pendingDelete == id },
                                                 set: { if !$0 { works.deleteCancelled() } }),
                            titleVisibility: .visible) {
            Button(role: .destructive) { works.deleteConfirmed(id) } label: { Text(L10nKey.worksDeleteConfirmOK) }
            Button(role: .cancel) { works.deleteCancelled() } label: { Text(L10nKey.commonCancel) }
        }
        .alert(Text(works.state.notice ?? .worksOpenFailed), isPresented: .constant(works.state.notice != nil)) {
            Button { works.dismissNotice(); dismiss() } label: { Text(L10nKey.commonOK) }
        }
        // 删掉后（作品已不在列表里）回到列表
        .onChange(of: works.state.summaries.map(\.id)) { ids in
            if works.state.isLoaded, !ids.contains(id), works.state.pendingDelete == nil, works.state.notice == nil { dismiss() }
        }
        // 导出进度 / 保存结果：结果页不在导航栈里时由本页呈现提示；在栈里时结果页已有 ExportResultAlerts，本页只盖进度。
        .modifier(WorkExportPresentation(presentsAlerts: model.flow.step != .result))
    }
}

struct WorkExportPresentation: ViewModifier {
    @EnvironmentObject var model: AppModel
    let presentsAlerts: Bool

    func body(content: Content) -> some View {
        let busy = content.overlay {
            if model.exportPhase.isBusy { ExportBusyOverlay() }
        }
        if presentsAlerts {
            busy.modifier(ExportResultAlerts())
        } else {
            busy
        }
    }
}
