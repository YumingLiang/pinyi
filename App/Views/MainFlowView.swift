import PhotosUI
import SwiftUI
import MosaicAppCore

/// 主流程（T9）：目标图 → 来源 → 密度 / 叠加 → 生成 → 结果。
struct MainFlowView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.flow.step {
                case .target: TargetStepView()
                case .source: SourceStepView()
                case .settings: SettingsStepView()
                case .result: ResultView()
                }
            }
            // 未保存提示挂在主流程上：预览页「再拼一张」和「再调一调」设置页（经作品查看页入口，验收 7a）都在这里弹。
            .modifier(UnsavedPromptDialog())
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // 「再拼一张」的选图页也有返回（回到原预览页，结果还在）
                    if (model.flow.step != .target || model.flow.isQuickAgain) && model.flow.step != .result {
                        Button { model.flowSend(.back) } label: { Text(L10nKey.commonBack) }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        WorksEntryButton()   // 需求 B2：首页右上角「我的作品」
                        NavigationLink { SettingsPageView() } label: { Image(systemName: "gearshape") }
                    }
                }
            }
        }
        // 作品查看页「再拼一张」：整个导航栈退回主流程（换 id = 重建栈，弹掉作品列表 / 查看页）。
        .id(model.navigationResetToken)
        .sheet(isPresented: $model.showScanSheet) { ScanView() }
        .fullScreenCover(isPresented: .constant(model.flow.generation.showsProgress)) { GenerationProgressView() }
        .sheet(item: Binding(get: { model.presentedEmptyState.map(EmptyBox.init) },
                             set: { model.presentedEmptyState = $0?.state })) { box in
            EmptyStateView(state: box.state)
        }
    }

    struct EmptyBox: Identifiable { let state: LibraryEmptyState; var id: String { "\(state)" } }
}

struct TargetStepView: View {
    @EnvironmentObject var model: AppModel
    @State private var item: PhotosPickerItem?
    /// 「再拼一张」进来时直接弹出选图（再拼一张 → 选一张 → 开始拼图，≤ 3 次点击）。
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 20) {
            Text(L10nKey.targetPrompt).font(.title3)
            if let cg = model.targetPreview {
                Image(decorative: cg, scale: 1).resizable().scaledToFit().frame(maxHeight: 360).cornerRadius(12)
            }
            if let n = model.flow.targetNotice { Text(n).foregroundStyle(.red).font(.footnote) }
            // 决定 15：SwiftUI PhotosPicker（iOS 16+）。PhotosPicker 走系统进程，不需要相册读取权限。
            // label 闭包是 @Sendable：先在 MainActor 上取值，闭包里只捕获值
            let buttonKey = model.flow.targetButtonKey
            PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
                Text(buttonKey)
            }
            .buttonStyle(.bordered)
            .photosPicker(isPresented: $showPicker, selection: $item, matching: .images, photoLibrary: .shared())
            Button { model.flowSend(.next) } label: { Text(L10nKey.targetNext).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.flow.canGoNextFromTarget)
        }
        .padding(24)
        .navigationTitle(Text(L10nKey.targetNavTitle))
        .onAppear {
            // TODO(需求 v1.0 §4)：自做选图页（记住浏览位置）接入主流程后改为打开它；目前主流程仍是系统 PhotosPicker。
            if model.flow.autoOpensTargetPicker { showPicker = true }
        }
        .onChange(of: item) { newItem in
            Task {
                // ⚠️ 盲写：loadTransferable(type: Data.self) 对 HEIC/RAW 的行为需真机核对；iCloud 原图会触发系统下载（系统进程内，不是本 App 联网）。
                // #18 P1-a：系统选择器可能显示隐藏照片（等 T7）。按 itemIdentifier 经 PhotoFetch 再取一次 PHAsset，
                // 取不到或 isHidden 就按「读不出来」处理，不解码。主流程和「再拼一张」共用这个选图页。
                guard let newItem else { return }
                guard PickedTargetGate.allows(itemIdentifier: newItem.itemIdentifier,
                                              lookup: PhotoFetch.pickedAssetLookup) else {
                    model.loadTarget(data: nil)
                    return
                }
                let data = try? await newItem.loadTransferable(type: Data.self)
                model.loadTarget(data: data)
            }
        }
    }
}

struct SourceStepView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAlbums = false

    var body: some View {
        List {
            Section {
                sourceRow(model.allPhotosRow)
                Button { showAlbums.toggle() } label: {
                    VStack(alignment: .leading) {
                        Text(L10nKey.sourceAlbumOption)
                        Text(L10nKey.sourceAlbumOptionDesc).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if showAlbums {
                Section(header: Text(L10nKey.sourceAlbumListTitle)) {
                    ForEach(model.albumRows) { sourceRow($0) }
                }
            }
            if SourceListLogic.showsAddPhotos(access: model.access) {
                Section { Button { SystemActions.presentLimitedLibraryPicker() } label: { Text(L10nKey.sourceAddPhotos) } }
            }
            if let n = model.flow.source.notice { Section { Text(n).foregroundStyle(.red) } }
            if let line = model.sourceLowResLine { Section { Text(line).font(.footnote).foregroundStyle(.secondary) } }
            if let n = model.transientNotice { Section { Text(n).font(.footnote).foregroundStyle(.secondary) } }
            if let e = model.emptyState {
                Section { VStack(alignment: .leading) { Text(e.titleKey).bold(); Text(e.bodyKey).font(.footnote) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { model.flowSend(.next) } label: { Text(L10nKey.sourceNext).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).padding()
        }
        .navigationTitle(Text(L10nKey.sourceNavTitle))
        .task { await model.refreshAlbums() }
    }

    @ViewBuilder func sourceRow(_ row: SourceRow) -> some View {
        Button { model.selectSource(row.selection) } label: {
            HStack {
                VStack(alignment: .leading) {
                    if let k = row.titleKey { Text(k) } else { Text(verbatim: row.albumTitle ?? "") }
                    Text(row.countLine).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if model.flow.source.selection == row.selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .foregroundStyle(.primary)
    }
}

struct SettingsStepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            if let n = model.flow.generation.settingsNotice {
                Section { Text(n).foregroundStyle(.orange) }
            }
            // 确认页（需求 v1.0 §2b）：「素材：{name} · {count} 张」+「换素材」。「裁剪」（§3）在 feat/app-layer 上还没有，接入后放这里。
            Section {
                HStack {
                    Text(model.materialSummary).font(.subheadline)
                    Spacer()
                    Button { model.flowSend(.changeSource) } label: { Text(L10nKey.quickSourceChange) }
                }
            }
            Section(header: Text(L10nKey.densitySection)) {
                ForEach(DensityChoice.allCases, id: \.self) { d in
                    Button { model.setDensity(d) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.titleKey)
                                Text(d.descriptionKey).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.flow.settings.density == d { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            Section(header: Text(L10nKey.overlaySection), footer: Text(L10nKey.overlayHint)) {
                Slider(value: $model.overlayAlpha, in: 0...OverlayBlendLimits.maxAlpha) {
                    Text(L10nKey.overlaySection)
                } minimumValueLabel: { Text(L10nKey.overlayLeft).font(.caption2) } maximumValueLabel: { Text(L10nKey.overlayRight).font(.caption2) }
            }
            Section(footer: Text(L10nKey.generatePrivacyHint)) {
                // B10.14：「再调一调」进来只动了叠加强度 →「完成」回原结果（不重新生成）；否则「开始拼图」
                let action = model.settingsPrimaryAction
                Button {
                    if action == .done { model.adjustDoneTapped() } else { model.generateTapped() }
                } label: { Text(action == .done ? L10nKey.commonDone : L10nKey.generateCTA).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .confirmationDialog(Text(L10nKey.shortagePregenerate),
                            isPresented: .constant(model.flow.generation.shortagePrompt), titleVisibility: .visible) {
            Button { model.send(.shortageContinue) } label: { Text(L10nKey.shortagePregenerateContinue) }
            Button(role: .cancel) { model.send(.shortageBack) } label: { Text(L10nKey.shortagePregenerateBack) }
        }
        .alert(Text(L10nKey.generateFailedTitle), isPresented: .constant(model.flow.generation.phase.isFailed)) {
            Button { model.retryTapped() } label: { Text(L10nKey.generateFailedRetry) }
            Button(role: .cancel) { model.send(.backToSettings) } label: { Text(L10nKey.generateFailedBack) }
        } message: { Text(L10nKey.generateFailedBody) }
    }
}

extension GenerationMachine.Phase {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

struct GenerationProgressView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Text(L10nKey.generateProgressTitle).font(.title2.bold())
            ProgressView(value: model.flow.generation.fraction).padding(.horizontal, 40)
            Text(model.generationProgressBodyKey).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(role: .cancel) { model.send(.cancelTapped) } label: { Text(L10nKey.generateProgressCancel) }
        }
        .padding(32)
        .interactiveDismissDisabled()
        .confirmationDialog(Text(L10nKey.generateCancelConfirmTitle),
                            isPresented: .constant(model.flow.generation.showsCancelConfirm), titleVisibility: .visible) {
            Button(role: .destructive) { model.send(.cancelConfirmed) } label: { Text(L10nKey.generateCancelConfirmConfirm) }
            Button(role: .cancel) { model.send(.cancelDismissed) } label: { Text(L10nKey.generateCancelConfirmContinue) }
        }
    }
}

struct ResultView: View {
    @EnvironmentObject var model: AppModel
    @State private var showTiers = false

    var body: some View {
        VStack(spacing: 12) {
            if model.postFilterShortageNotice {
                Text(L10nKey.shortagePregenerate).font(.footnote).foregroundStyle(.secondary)
            }
            if case .result(let o) = model.flow.generation.phase, o.shouldShowShortageNotice {
                Text(L10nKey.shortageResult).font(.footnote).foregroundStyle(.secondary)
            }
            if let img = model.resultImage {
                // 缩放规则见 ZoomState（捏合累乘、单格铺满屏幕上限、双击逐级放大 / 到顶复位）。
                let grid = model.previewGrid
                ZoomableContainer(aspectRatio: Double(img.width) / Double(max(1, img.height)),
                                  columns: grid.columns, rows: grid.rows, zoom: $model.resultZoom) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high).scaledToFit()
                }
            }
            Text(L10nKey.previewHint).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button { model.send(.backToSettings) } label: { Text(L10nKey.previewAdjust) }.buttonStyle(.bordered)
                Button { model.send(.reshuffleTapped) } label: { Text(L10nKey.previewReshuffle) }.buttonStyle(.borderedProminent)
            }
            // 导出（紧急版）：三档选择 → 保存到相册
            Button { showTiers = true } label: { Text(L10nKey.previewExport).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canExport)
            SaveToWorksButton()   // 需求 B2 / B10：次按钮「存到我的作品」（导出不自动存）
            // 需求 v1.0 §2e：第三级文字按钮，紧挨「存到我的作品」下面，不和「再调一调」「换一种拼法」同排。
            // 生成中 / 导出中 / 提示弹着时不可点（判断在 AppState.canStartNewMosaic）。
            Button { model.startNewMosaicTapped() } label: {
                Label { Text(L10nKey.quickAgain) } icon: { Image(systemName: "plus") }
            }
            .buttonStyle(.borderless)
            .disabled(!model.canStartNewMosaic)
        }
        .padding()
        .navigationTitle(Text(L10nKey.previewNavTitle))
        .sheet(isPresented: $showTiers) {
            ExportTierSheet { showTiers = false; model.saveTapped() }
                .environmentObject(model)
                .presentationDetents([.medium])
        }
        .overlay {
            if model.exportPhase.isBusy { ExportBusyOverlay() }
        }
        .modifier(ExportResultAlerts())
    }
}

/// 导出档位选择（不显示像素数）+ 固定提示「文件较大，导出需要一会儿」。
struct ExportTierSheet: View {
    @EnvironmentObject var model: AppModel
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10nKey.exportSizeSection).font(.headline)
            ForEach(ExportTier.allCases, id: \.self) { tier in
                Button { model.exportTier = tier } label: {
                    HStack(alignment: .top) {
                        Image(systemName: model.exportTier == tier ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tier.titleKey).font(.body.bold())
                            Text(tier.descriptionKey).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L10nKey.exportSizeLargeHint).font(.footnote).foregroundStyle(.secondary)
            Button(action: onExport) { Text(L10nKey.previewSave).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
    }
}

/// 导出中：转圈 +「正在导出」「导出时请停留在这个页面。」（不可取消，紧急版）。
struct ExportBusyOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(L10nKey.exportProgressTitle).font(.headline)
                Text(L10nKey.exportProgressHint).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// 保存成功 / 失败 / 被打断的提示。按钮自己调协调器；alert 的 isPresented 只读（避免关闭时先把状态清掉）。
struct ExportResultAlerts: ViewModifier {
    @EnvironmentObject var model: AppModel

    private var failure: SaveFailure? {
        if case .failed(let f) = model.exportPhase { return f }
        return nil
    }
    private var saved: Bool { model.exportPhase == .saved }
    private var interrupted: Bool { model.exportPhase == .interrupted }

    func body(content: Content) -> some View {
        content
            .alert(Text(L10nKey.saveSuccessTitle), isPresented: .constant(saved)) {
                Button { model.dismissExportResult() } label: { Text(L10nKey.saveSuccessDone) }
            } message: { Text(L10nKey.saveSuccessBody) }
            .alert(Text(failure?.titleKey ?? .saveFailed), isPresented: .constant(failure != nil)) {
                if let f = failure {
                    Button { model.exportFailurePrimaryTapped() } label: { Text(f.primaryKey) }
                    if f != .diskFull {
                        Button(role: .cancel) { model.dismissExportResult() } label: { Text(L10nKey.commonClose) }
                    }
                }
            } message: {
                if let b = failure?.bodyKey { Text(b) }
            }
            .alert(Text(L10nKey.exportInterrupted), isPresented: .constant(interrupted)) {
                Button { model.dismissExportResult() } label: { Text(L10nKey.commonOK) }
            }
    }
}

/// 未保存提示（quick.unsaved.*）：当前结果没存进作品（导出过不算存过）时由协调器弹出；存过但只改了叠加强度时
/// 标题换成 quick.unsaved.update_title，「保存」= 更新原作品（hd-export B10-4/11）。isPresented 只读，按钮各自调协调器。
struct UnsavedPromptDialog: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(Text(model.unsavedPromptIsUpdate ? L10nKey.quickUnsavedUpdateTitle : L10nKey.quickUnsavedTitle),
                                // 收起（点外面 / 系统收起）走 unsavedPromptDismissed：延后一轮、仍是同一个提示且没在保存时才按「取消」，
                                // 不会吞掉按钮动作，也不会让提示状态一直挂着（「再拼一张」不可点、弹窗反复弹）。
                                isPresented: Binding(get: { model.unsavedPrompt != nil },
                                                     set: { if !$0 { model.unsavedPromptDismissed() } }),
                                titleVisibility: .visible) {
                Button { model.unsavedPromptSave() } label: { Text(L10nKey.quickUnsavedSave) }
                Button(role: .destructive) { model.unsavedPromptDiscard() } label: { Text(L10nKey.quickUnsavedDiscard) }
                Button(role: .cancel) { model.unsavedPromptCancel() } label: { Text(L10nKey.quickUnsavedCancel) }
            }
    }
}
