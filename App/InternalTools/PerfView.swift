#if INTERNAL_TOOLS
import SwiftUI
import UIKit
import MosaicAppCore

/// 内部性能页：各阶段计时（次数 / 中位数 / p90 / 最大 / 吞吐）。数据只在本机，复制到剪贴板由用户自行处理（零网络）。
/// 页面为内部工具，标签不进文案表（`PerfPhase.label`）。
struct PerfView: View {
    @EnvironmentObject var model: AppModel
    @State private var report = PerfReport(samples: [])
    @State private var peaks: [MemoryPhase: PeakMemorySample] = [:]
    @State private var triggers: [SQLiteTriggerCheck] = []

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
            // 最近一次导出的方案与格子填充（糊 = 退回 128px 扫描缩略图，白 = 完全没有图）
            if let note = model.perf.latestNote(of: .exportTotal) {
                Section(header: Text(verbatim: "最近一次导出")) {
                    Text(verbatim: note).font(.footnote).textSelection(.enabled)
                }
            }
            // MF-7：各阶段峰值内存（phys_footprint，0.5 s 采样）
            Section(header: Text(verbatim: "峰值内存（phys_footprint）")) {
                ForEach(MemoryPhase.allCases, id: \.self) { p in
                    if let s = peaks[p] {
                        LabeledContent(p.label, value: String(format: "峰值 %.0f MB（+%.0f MB）",
                                                              Double(s.peakBytes) / 1_048_576, Double(s.deltaBytes) / 1_048_576))
                    }
                }
            }
            // 评审 d6fa750 §3：换 SQLite 的触发条件（10 万条；不足 10 万线性外推，仅参考）
            Section(header: Text(verbatim: "SQLite 触发条件")) {
                ForEach(triggers) { c in
                    LabeledContent(c.label, value: c.verdict.rawValue)
                }
            }
            Section {
                Button("复制为文本") { UIPasteboard.general.string = fullText }
                Button("清空", role: .destructive) {
                    model.perf.reset()
                    model.coordinator.memory.reset()
                    refresh()
                }
            }
        }
        .navigationTitle(Text(L10nKey.settingsPerformance))
        .onAppear { refresh() }
        .refreshable { refresh() }
    }

    private func refresh() {
        report = model.perf.report()
        peaks = model.coordinator.memory.peakByPhase()
        triggers = SQLiteTriggerCheck.evaluate(samples: model.perf.allSamples(), memory: model.coordinator.memory.samples())
    }

    private var fullText: String {
        let mem = MemoryPhase.allCases.compactMap { p in
            peaks[p].map { "memory\t\(p.rawValue)\tpeak_bytes=\($0.peakBytes)\tdelta_bytes=\($0.deltaBytes)" }
        }
        let export = model.perf.latestNote(of: .exportTotal).map { "export\t\($0)" }
        return ([report.plainText(deviceNote: deviceNote)] + mem + [export].compactMap { $0 } + [SQLiteTriggerCheck.plainText(triggers)]).joined(separator: "\n")
    }

    private var deviceNote: String {
        let d = UIDevice.current
        return "\(d.model) iOS \(d.systemVersion) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
    }
}
#endif
