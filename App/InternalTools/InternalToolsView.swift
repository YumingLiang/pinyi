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
            NavigationLink { FakePhotoGridView() } label: { Text(verbatim: "照片网格（假数据 5 万张）") }
            NavigationLink { PreviewReadProbeView() } label: { Text(verbatim: "预览文件读取计数") }
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

/// 预览文件读取计数。屏幕上的数字只在按下按钮时抄一次，进入页面不抄。
/// 正对照直接调用 `loadImage`，不经过作品列表。测的时候不要清零。
struct PreviewReadProbeView: View {
    @State private var session: PreviewReadSession?
    @State private var controlNote: String?

    var body: some View {
        List {
            Section {
                Text(verbatim: "作品列表和查看页读预览文件时，次数加 1。日志类别 preview-read，只有次数。")
                    .font(.footnote)
                Text(verbatim: "进入本页不抄次数。没有按「刷新次数」之前，屏幕上没有测量值。当时看到的 0 不能当成没读过。")
                    .font(.footnote)
                Text(verbatim: "顺序：记下起点，去做操作，操作结束后再刷新。测的时候不要清零。起点之后马上刷新得到的 0，不能当成操作期间没读。")
                    .font(.footnote)
                Text(verbatim: "正对照只直接调用 loadImage，不经过作品列表。它的增量不能代替列表或查看页。")
                    .font(.footnote)
                Text(verbatim: "App进程重启或更换进程会使计数归零，之前那段测量证据失效，须重新记起点与正对照。")
                    .font(.footnote)
            }
            Section {
                Button {
                    session = PreviewReadSession(baselineCount: PreviewReadProbe.fileReadCount, at: Date())
                    controlNote = nil
                } label: { Text(verbatim: "记下当前次数作为本段起点") }
                if let session {
                    Text(verbatim: "本段起点 \(session.baseline.count) 次，\(Self.stamp(session.baseline.at))")
                        .font(.body.monospacedDigit())
                    if let refreshed = session.refreshed, let delta = session.deltaSinceBaseline {
                        Text(verbatim: "上次刷新 \(refreshed.count) 次，相对起点 +\(delta)。时间范围 \(Self.stamp(session.baseline.at))–\(Self.stamp(refreshed.at))")
                            .font(.body.monospacedDigit())
                        Text(verbatim: "这个差只覆盖起点到这次刷新。刷新前的数字不是结论。")
                            .font(.footnote)
                    } else {
                        Text(verbatim: "本段还没有刷新。现在不能下结论。")
                            .font(.footnote)
                    }
                } else {
                    Text(verbatim: "还没有本段起点。")
                        .font(.footnote)
                }
                Button {
                    guard var session else { return }
                    session.noteRefresh(count: PreviewReadProbe.fileReadCount, at: Date())
                    self.session = session
                } label: { Text(verbatim: "刷新次数") }
                .disabled(session == nil)
            }
            Section {
                Button {
                    let before = PreviewReadProbe.fileReadCount
                    let ok = PreviewReadProbe.positiveControl()
                    let delta = PreviewReadProbe.fileReadCount - before
                    if var session {
                        session.noteControl(delta: delta)
                        self.session = session
                    }
                    controlNote = ok && delta == 1
                        ? "正对照增量 \(delta)。这只说明 loadImage 被调用了一次，不是作品列表。"
                        : "正对照增量 \(delta)，调用\(ok ? "成功" : "失败")。不能当成列表已验证。"
                } label: { Text(verbatim: "正对照：读一张合成图") }
                if let controlNote {
                    Text(verbatim: controlNote).font(.footnote)
                }
            }
            Section {
                Text(verbatim: "清零会丢掉本段起点。清零后的 0 不是保护结果。")
                    .font(.footnote)
                Button {
                    PreviewReadProbe.reset()
                    session = nil
                    controlNote = "已清零并放弃本段。清零后的 0 不是测量结果。"
                } label: { Text(verbatim: "放弃本段并清零") }
            }
        }
        .navigationTitle(Text(verbatim: "预览读取"))
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second())
    }
}
#endif
