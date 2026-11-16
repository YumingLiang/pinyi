import Foundation

/// 性能页的汇总（每阶段：次数、总耗时、中位数、p90、最大、吞吐）。
public struct PerfReport: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: PerfPhase { phase }
        public var phase: PerfPhase
        public var count: Int
        public var totalSeconds: Double
        public var medianSeconds: Double
        public var p90Seconds: Double
        public var maxSeconds: Double
        public var totalItems: Int
        /// 单位 / 秒（张/秒 或 格/秒）；没有单位数时 nil。
        public var itemsPerSecond: Double? {
            totalItems > 0 && totalSeconds > 0 ? Double(totalItems) / totalSeconds : nil
        }
    }

    public var rows: [Row]
    public var sampleCount: Int

    public init(samples: [PerfSample]) {
        sampleCount = samples.count
        var byPhase: [PerfPhase: [PerfSample]] = [:]
        for s in samples { byPhase[s.phase, default: []].append(s) }
        rows = PerfPhase.allCases.compactMap { phase in
            guard let list = byPhase[phase], !list.isEmpty else { return nil }
            let secs = list.map(\.seconds).sorted()
            return Row(phase: phase, count: list.count, totalSeconds: secs.reduce(0, +),
                       medianSeconds: PerfReport.percentile(secs, 0.5), p90Seconds: PerfReport.percentile(secs, 0.9),
                       maxSeconds: secs.last ?? 0, totalItems: list.reduce(0) { $0 + $1.items })
        }
    }

    public func row(_ phase: PerfPhase) -> Row? { rows.first { $0.phase == phase } }

    /// 最近邻百分位（已排序输入）。
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded(.up))
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }

    /// 扫描吞吐（张/秒）：分母用扫描墙钟总时长，分子含跳过（iCloud）与失败的张数——
    /// 用户感受的是"多久扫完"，跳过的也占时间（技术方案 §5：10 万张 ≤ 25 min ⇔ ≥ 67 张/秒）。
    public static func scanThroughput(processed: Int, wallSeconds: Double) -> Double? {
        processed > 0 && wallSeconds > 0 ? Double(processed) / wallSeconds : nil
    }

    /// 纯文本导出（性能页「复制」用；不联网，用户自行粘贴）。
    public func plainText(deviceNote: String = "") -> String {
        var lines: [String] = []
        if !deviceNote.isEmpty { lines.append(deviceNote) }
        lines.append("phase\tcount\ttotal_ms\tmedian_ms\tp90_ms\tmax_ms\titems\titems_per_s")
        for r in rows {
            let ips = r.itemsPerSecond.map { String(format: "%.1f", $0) } ?? "-"
            let nums = String(format: "%d\t%.1f\t%.1f\t%.1f\t%.1f\t%d", r.count, r.totalSeconds * 1000, r.medianSeconds * 1000,
                              r.p90Seconds * 1000, r.maxSeconds * 1000, r.totalItems)
            lines.append("\(r.phase.rawValue)\t\(nums)\t\(ips)")
        }
        return lines.joined(separator: "\n")
    }
}
