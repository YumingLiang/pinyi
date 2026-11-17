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
    @State private var hiddenNote: String?
    @EnvironmentObject var model: AppModel
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
                Button(role: .destructive) {
                    let w = writer
                    start { report in try await w.deleteAlbum(progress: report) }
                } label: {
                    Text(verbatim: "删除「\(TestAlbumPolicy.albumTitle)」相簿及其中照片")
                }
                .disabled(task != nil)
                if task != nil { Button { task?.cancel() } label: { Text(L10nKey.commonCancel) } }
            }
            // 隐藏照片验收（需求 v0.4 §4.8 验收 8 / 9）：隐藏一张已用在最新作品里的测试照片 → 回到「我的作品」打开该作品、高清重导出
            Section {
                Button { hideOneUsedInLatestWork() } label: { Text(verbatim: "隐藏一张测试照片（优先最新作品里用到的）") }
                    .disabled(task != nil)
                Button {
                    let w = writer
                    Task { hiddenNote = (try? await w.unhideAll()).map { "已取消隐藏 \($0) 张" } ?? "取消隐藏失败" }
                } label: { Text(verbatim: "取消隐藏全部测试照片") }
                    .disabled(task != nil)
                if let hiddenNote { Text(verbatim: hiddenNote).font(.caption) }
            }
            Section {
                ProgressView(value: progress.fraction)
                Text(verbatim: "\(progress.written) / \(progress.total)  \(String(describing: progress.phase))").font(.caption).monospacedDigit()
            }
        }
        .navigationTitle(Text(verbatim: TestAlbumPolicy.albumTitle))
        .confirmationDialog(Text(verbatim: "写入 \(count) 张合成图片到相册？"), isPresented: $confirmCreate, titleVisibility: .visible) {
            Button {
                let w = writer, plan = TestAlbumPlan(count: count)   // @Sendable 闭包只捕获值，不捕获 View 的 self
                start { report in try await w.create(plan: plan, progress: report) }
            } label: { Text(verbatim: "写入") }
            Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
        }
    }

    private func hideOneUsedInLatestWork() {
        let w = writer
        let controller = model.works.controller
        let latest = model.works.summaries.first?.id
        Task {
            var preferred = Set<String>()
            if let latest, let work = try? await controller.store.load(latest) { preferred = Set(work.layout.uniqueAssetIDs) }
            do {
                if let i = try await w.hideOne(preferring: preferred) {
                    hiddenNote = "已隐藏相簿里第 \(i + 1) 张" + (preferred.isEmpty ? "（没有作品）" : "（最新作品里用到的优先）")
                } else {
                    hiddenNote = "相簿里没有可隐藏的照片"
                }
            } catch {
                hiddenNote = "隐藏失败：\(error)"
            }
        }
    }

    /// 进度经 AsyncStream 回到 MainActor（continuation 是 Sendable；不在 @Sendable 闭包里捕获 View 的 self）。
    private func start(_ body: @escaping @Sendable (@escaping @Sendable (TestAlbumProgress) -> Void) async throws -> Void) {
        let (stream, continuation) = AsyncStream<TestAlbumProgress>.makeStream()
        task = Task {
            let consumer = Task { for await p in stream { progress = p } }
            var outcome: TestAlbumProgress.Phase?
            do { try await body { continuation.yield($0) } } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed("\(error)")
            }
            continuation.finish()
            await consumer.value
            if let outcome { progress.phase = outcome }
            task = nil
        }
    }
}
#endif
