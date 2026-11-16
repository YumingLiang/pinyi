import SwiftUI
import UIKit
import MosaicAppCore

/// T7：马赛克 + 可选叠加层（同尺寸 scaledToFit）。缩放 / 平移交给 `ZoomableContainer`。
struct MosaicWithOverlay: View {
    let image: CGImage
    let overlay: CGImage?
    let overlayAlpha: Double

    var body: some View {
        ZStack {
            Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
            if let overlay, overlayAlpha > 0 {
                // sRGB 编码值上的 α 混合 = 导出条带里 CGContext.setAlpha 的结果（同一公式）
                Image(decorative: overlay, scale: 1).resizable().interpolation(.medium).scaledToFit()
                    .opacity(overlayAlpha)
            }
        }
    }
}

/// T8：保存 / 分享按钮（与分辨率无关）。导出尺寸 / 档位选择（导出卡，T10/T11）暂停：
/// AndyL 提「高清导出」，档位待架构师和产品定案，目前沿用协调器的默认长边。
struct ExportControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Button { model.saveTapped() } label: { Text(L10nKey.previewSave).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            Button { model.shareTapped() } label: { Text(L10nKey.previewShare).frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(!model.canExport)
    }
}

/// 导出中（`export.progress.*`）：停留在本页，进度条 + 提示。
struct ExportProgressOverlay: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(L10nKey.exportProgressTitle).font(.headline)
                ProgressView(value: fraction).frame(width: 220)
                Text(L10nKey.exportProgressHint).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// 系统分享面板。关闭（完成或取消）时回调，用于删除临时文件。
struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    let onFinish: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let finish = onFinish
        vc.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in finish() }
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 分享面板的 item（`sheet(item:)` 需要 Identifiable）。
struct ShareItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

/// 把导出状态映射成提示 / 面板（文案 §4.9–4.10、§5.3 的 key）。
struct ExportResultModifier: ViewModifier {
    @EnvironmentObject var model: AppModel

    private var failure: SaveFailure? {
        if case .failed(let f) = model.exportPhase { return f }
        return nil
    }
    private var isSaved: Bool { model.exportPhase == .saved }
    private var isInterrupted: Bool { model.exportPhase == .interrupted }
    private var shareItem: ShareItem? {
        if case .sharing(let url) = model.exportPhase { return ShareItem(url: url) }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if case .exporting(_, let f) = model.exportPhase { ExportProgressOverlay(fraction: f) }
            }
            .alert(Text(failure?.titleKey ?? .saveFailed), isPresented: .constant(failure != nil), presenting: failure) { f in
                Button { model.exportFailurePrimaryTapped() } label: { Text(f.primaryKey) }
                if let second = f.secondaryKey {
                    Button { model.exportFailureSecondaryTapped() } label: { Text(second) }
                }
            } message: { f in
                if let body = f.bodyKey { Text(body) }
            }
            .alert(Text(L10nKey.saveSuccessTitle), isPresented: .constant(isSaved)) {
                Button { model.dismissExportResult() } label: { Text(L10nKey.saveSuccessDone) }
                Button { model.saveSuccessShareTapped() } label: { Text(L10nKey.saveSuccessShare) }
            } message: { Text(L10nKey.saveSuccessBody) }
            .alert(Text(L10nKey.exportInterrupted), isPresented: .constant(isInterrupted)) {
                Button { model.exportRetryTapped() } label: { Text(L10nKey.exportRetry) }
                Button(role: .cancel) { model.dismissExportResult() } label: { Text(L10nKey.commonCancel) }
            }
            .sheet(item: .constant(shareItem), onDismiss: { model.shareFinished() }) { item in
                ActivityView(url: item.url) { model.shareFinished() }
            }
    }
}
