import SwiftUI
import UIKit
import MosaicAppCore

/// T7：普通缩放预览（不用 CATiledLayer）。双指缩放 1–6 倍、拖动平移、双击在 1× / 3× 间切换。
/// 预览位图长边 ≤ 2400 px（`MosaicPreviewRenderer.cellPixels`），放大时用最近邻插值，块边清楚。
struct ZoomableMosaicView: View {
    let image: CGImage
    let overlay: CGImage?
    let overlayAlpha: Double

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    static let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
                if let overlay, overlayAlpha > 0 {
                    // sRGB 编码值上的 α 混合 = 导出条带里 CGContext.setAlpha 的结果（同一公式）
                    Image(decorative: overlay, scale: 1).resizable().interpolation(.medium).scaledToFit()
                        .opacity(overlayAlpha)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { v in scale = min(Self.maxScale, max(1, lastScale * v)) }
                    .onEnded { _ in
                        lastScale = scale
                        if scale == 1 { offset = .zero; lastOffset = .zero }
                    }
                    .simultaneously(with: DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }
                            offset = clamp(CGSize(width: lastOffset.width + v.translation.width,
                                                  height: lastOffset.height + v.translation.height), in: geo.size)
                        }
                        .onEnded { _ in lastOffset = offset })
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scale = scale > 1 ? 1 : 3
                    lastScale = scale
                    offset = .zero
                    lastOffset = .zero
                }
            }
            .clipped()
        }
    }

    private func clamp(_ o: CGSize, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2, maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }
}

/// T8：导出尺寸 + 保存 / 分享按钮。
struct ExportControls: View {
    @EnvironmentObject var model: AppModel

    private var sizes: [ExportSize] {
        #if INTERNAL_TOOLS
        return ExportSize.userChoices + [.internal8000]   // 决定 12：8000 仅内部摸底
        #else
        return ExportSize.userChoices
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10nKey.exportSizeSection).font(.subheadline.bold())
            Picker(selection: $model.exportSize) {
                ForEach(sizes, id: \.self) { s in
                    if let key = s.titleKey { Text(key).tag(s) } else { Text(verbatim: "8000（内部）").tag(s) }
                }
            } label: { Text(L10nKey.exportSizeSection) }
            .pickerStyle(.segmented)
            Group {
                switch model.exportSize {
                case .standard: Text(L10nKey.exportSize4000Desc)
                case .large: Text(L10nKey.exportSize6000Desc)
                case .internal8000: Text(verbatim: "长边 8000 像素，仅用于内部摸底内存与耗时。")
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
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
