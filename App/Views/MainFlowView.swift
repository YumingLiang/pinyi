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
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if model.flow.step != .target && model.flow.step != .result {
                        Button { model.flowSend(.back) } label: { Text(L10nKey.commonBack) }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { SettingsPageView() } label: { Image(systemName: "gearshape") }
                }
            }
        }
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
            Button { model.flowSend(.next) } label: { Text(L10nKey.targetNext).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.flow.canGoNextFromTarget)
        }
        .padding(24)
        .navigationTitle(Text(L10nKey.targetNavTitle))
        .onChange(of: item) { newItem in
            Task {
                // ⚠️ 盲写：loadTransferable(type: Data.self) 对 HEIC/RAW 的行为需真机核对；iCloud 原图会触发系统下载（系统进程内，不是本 App 联网）。
                let data = try? await newItem?.loadTransferable(type: Data.self)
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
                Button { model.generateTapped() } label: { Text(L10nKey.generateCTA).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .confirmationDialog(Text(L10nKey.shortagePregenerate),
                            isPresented: .constant(model.flow.generation.shortagePrompt), titleVisibility: .visible) {
            Button { model.send(.shortageContinue) } label: { Text(L10nKey.shortagePregenerateContinue) }
            Button(role: .cancel) { model.send(.shortageBack) } label: { Text(L10nKey.shortagePregenerateBack) }
        }
        .alert(Text(L10nKey.generateFailedTitle), isPresented: .constant(model.flow.generation.phase.isFailed)) {
            Button { model.send(.retryTapped(available: model.indexStatus.available)) } label: { Text(L10nKey.generateFailedRetry) }
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
            Text(L10nKey.generateProgressBody).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
    @State private var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 12) {
            if case .result(let o) = model.flow.generation.phase, o.shouldShowShortageNotice {
                Text(L10nKey.shortageResult).font(.footnote).foregroundStyle(.secondary)
            }
            if let img = model.resultImage {
                // ⚠️ MVP 预览：MagnificationGesture 放大位图；方案 §2.8 的 CATiledLayer 分层预览留给后续卡片。
                Image(decorative: img, scale: 1).resizable().interpolation(.none).scaledToFit()
                    .scaleEffect(scale)
                    .gesture(MagnificationGesture().onChanged { scale = max(1, min(8, $0)) })
            }
            Text(L10nKey.previewHint).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button { model.send(.backToSettings) } label: { Text(L10nKey.previewAdjust) }.buttonStyle(.bordered)
                Button { model.send(.reshuffleTapped) } label: { Text(L10nKey.previewReshuffle) }.buttonStyle(.borderedProminent)
            }
            // 保存 / 分享（导出 4000 / 6000）不在本卡范围（T10/T11）。
        }
        .padding()
        .navigationTitle(Text(L10nKey.previewNavTitle))
    }
}
