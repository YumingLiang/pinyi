import SwiftUI
import UIKit
import MosaicAppCore

/// 设置页：内部构建（`PERF_PAGE`）显示「性能测试」；上架版只能从「关于」连点版本号 5 次进入（决定 18）。
struct SettingsPageView: View {
    @EnvironmentObject var model: AppModel
    @State private var showPerfFromAbout = false

    var body: some View {
        List {
            if model.buildFlags.showsPerformanceEntryInSettings {
                NavigationLink { PerfView() } label: { Text(L10nKey.settingsPerformance) }
            }
            NavigationLink { AboutView(onUnlock: { showPerfFromAbout = true }) } label: { Text(L10nKey.settingsAbout) }
        }
        .navigationTitle(Text(L10nKey.settingsTitle))
        .navigationDestination(isPresented: $showPerfFromAbout) { PerfView() }
    }
}

struct AboutView: View {
    let onUnlock: () -> Void
    @State private var taps = HiddenEntryTapCounter()

    var body: some View {
        VStack(spacing: 12) {
            Text(L10nKey.aboutTitle).font(.title3.bold())
            Text(L10nKey.aboutBody).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(verbatim: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                .font(.footnote).monospacedDigit()
                .onTapGesture { if taps.tap(at: MonotonicClock.system.now()) { onUnlock() } }
        }
        .padding(32)
    }
}

/// 内部性能页：各阶段计时（次数 / 中位数 / p90 / 最大 / 吞吐）。数据只在本机，复制到剪贴板由用户自行处理（零网络）。
/// 页面为内部工具，标签不进文案表（`PerfPhase.label`）。
struct PerfView: View {
    @EnvironmentObject var model: AppModel
    @State private var report = PerfReport(samples: [])

    var body: some View {
        List {
            Section {
                LabeledContent("样本数", value: "\(report.sampleCount)")
                LabeledContent("可用照片", value: "\(model.indexStatus.available)")
                LabeledContent("相册总数", value: model.indexStatus.assetTotal.map(String.init) ?? "-")
            }
            ForEach(report.rows) { r in
                Section(header: Text(verbatim: r.phase.label)) {
                    LabeledContent("次数", value: "\(r.count)")
                    LabeledContent("中位数", value: String(format: "%.1f ms", r.medianSeconds * 1000))
                    LabeledContent("p90", value: String(format: "%.1f ms", r.p90Seconds * 1000))
                    LabeledContent("最大", value: String(format: "%.1f ms", r.maxSeconds * 1000))
                    if let ips = r.itemsPerSecond { LabeledContent("吞吐", value: String(format: "%.1f /s", ips)) }
                }
            }
            Section {
                Button("复制为文本") { UIPasteboard.general.string = report.plainText(deviceNote: deviceNote) }
                Button("清空", role: .destructive) { model.perf.reset(); report = model.perf.report() }
            }
        }
        .navigationTitle(Text(L10nKey.settingsPerformance))
        .onAppear { report = model.perf.report() }
        .refreshable { report = model.perf.report() }
    }

    private var deviceNote: String {
        let d = UIDevice.current
        return "\(d.model) iOS \(d.systemVersion) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
    }
}
