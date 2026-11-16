#if INTERNAL_TOOLS
import SwiftUI
import MosaicAppCore

/// 内部工具根视图（只在 `INTERNAL_TOOLS` 构建中存在）。
/// `.accessibilityIdentifier(InternalToolsMarker.id)` 实际引用标记字符串，防止被剥离；fastlane / CI 在产物里 `strings` 查它。
struct InternalToolsView: View {
    var body: some View {
        List {
            NavigationLink { PerfView() } label: { Text(verbatim: "性能计时") }
            NavigationLink { TestAlbumView() } label: { Text(verbatim: "「\(TestAlbumPolicy.albumTitle)」相簿") }
            // 导出 8000 档（决定 12：仅摸底）在导出页里同样用 #if INTERNAL_TOOLS 守卫（feat/render-export）。
        }
        .navigationTitle(Text(L10nKey.settingsPerformance))
        .accessibilityIdentifier(InternalToolsMarker.id)
    }
}

/// 「马赛克测试」相簿开关（技术方案 §11.5 第 9 点、决定 13）。内部页面，文字不进文案表。
struct TestAlbumView: View {
    @State private var count = TestAlbumPolicy.countOptions[1]
    @State private var progress = TestAlbumProgress()
    @State private var task: Task<Void, Never>?
    @State private var confirmCreate = false
    private let writer = TestAlbumWriter()

    var body: some View {
        List {
            Section {
                Text(verbatim: "在相册里建「\(TestAlbumPolicy.albumTitle)」相簿并写入合成图片，用于 1 万 / 5 万张扫描实测；测完可一键删除（系统会再确认一次）。全部在本机完成。")
                    .font(.footnote)
            }
            if TestAlbumPolicy.ownerApproved {
                Section {
                    Picker(selection: $count) {
                        ForEach(TestAlbumPolicy.countOptions, id: \.self) { Text(verbatim: "\($0) 张").tag($0) }
                    } label: { Text(verbatim: "张数") }
                    Button { confirmCreate = true } label: { Text(verbatim: "生成") }
                        .disabled(task != nil)
                }
            } else {
                Section { Text(verbatim: "决定 13 待 AndyL 拍板：拍板前不提供「生成」。").foregroundStyle(.secondary) }
            }
            Section {
                Button(role: .destructive) { start { try await writer.deleteAlbum(progress: update) } } label: {
                    Text(verbatim: "删除「\(TestAlbumPolicy.albumTitle)」相簿及其中照片")
                }
                .disabled(task != nil)
                if task != nil { Button { task?.cancel() } label: { Text(L10nKey.commonCancel) } }
            }
            Section {
                ProgressView(value: progress.fraction)
                Text(verbatim: "\(progress.written) / \(progress.total)  \(String(describing: progress.phase))").font(.caption).monospacedDigit()
            }
        }
        .navigationTitle(Text(verbatim: TestAlbumPolicy.albumTitle))
        .confirmationDialog(Text(verbatim: "写入 \(count) 张合成图片到相册？"), isPresented: $confirmCreate, titleVisibility: .visible) {
            Button { start { try await writer.create(plan: TestAlbumPlan(count: count), progress: update) } } label: { Text(verbatim: "写入") }
            Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
        }
    }

    private var update: @Sendable (TestAlbumProgress) -> Void {
        { p in Task { @MainActor in progress = p } }
    }

    private func start(_ body: @escaping @Sendable () async throws -> Void) {
        task = Task {
            do { try await body() } catch is CancellationError {
                progress.phase = .cancelled
            } catch {
                progress.phase = .failed("\(error)")
            }
            task = nil
        }
    }
}
#endif
