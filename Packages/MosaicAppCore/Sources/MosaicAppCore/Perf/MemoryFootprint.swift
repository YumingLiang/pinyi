import MosaicCore

/// 读当前进程内存占用（评审 d6fa750 MF-7 / 技术方案 §11.5）。
/// App 实现读 `task_vm_info.phys_footprint`（与 Xcode 内存仪表、jetsam 口径一致）；Linux 测试用假实现。
public protocol MemoryFootprintReading: Sendable {
    /// 当前 phys_footprint（字节）；读不到返回 nil。
    func physFootprintBytes() -> UInt64?
}

/// 需要记录峰值内存的阶段。
public enum MemoryPhase: String, Sendable, Hashable, CaseIterable, Codable {
    case indexLoad, scan, generate, preview, export

    public var label: String {
        switch self {
        case .indexLoad: return "索引加载"
        case .scan: return "扫描"
        case .generate: return "生成"
        case .preview: return "预览"
        case .export: return "导出"
        }
    }
}

/// 一个阶段的峰值内存。
public struct PeakMemorySample: Sendable, Hashable, Codable {
    public var phase: MemoryPhase
    /// 阶段开始时的 phys_footprint。
    public var baselineBytes: UInt64
    /// 阶段内采样到的最大值。
    public var peakBytes: UInt64
    public var sampleCount: Int
    /// 峰值增量（峰值 − 起点）。
    public var deltaBytes: UInt64 { peakBytes > baselineBytes ? peakBytes - baselineBytes : 0 }
}

/// 峰值内存采样器：阶段 begin/end 之间按 0.5 s 采样（由调用方的定时循环调 `sample()`，见 `AppCoordinator`），
/// 只在有阶段进行时采样；结果保留最近 `capacity` 条。线程安全。
public final class PeakMemoryTracker: Sendable {
    public static let samplingInterval: Double = 0.5

    public struct Token: Sendable, Hashable { fileprivate let id: Int; public let phase: MemoryPhase }

    private struct Active: Sendable { var phase: MemoryPhase; var baseline: UInt64; var peak: UInt64; var count: Int }
    private struct State: Sendable {
        var nextID = 0
        var active: [Int: Active] = [:]
        var finished: [PeakMemorySample] = []
    }
    private let reader: any MemoryFootprintReading
    private let capacity: Int
    private let state = LockedState(State())

    public init(reader: any MemoryFootprintReading, capacity: Int = 200) {
        self.reader = reader
        self.capacity = max(1, capacity)
    }

    public var isSampling: Bool { state.withLock { !$0.active.isEmpty } }

    public func begin(_ phase: MemoryPhase) -> Token {
        let now = reader.physFootprintBytes() ?? 0
        return state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            s.active[id] = Active(phase: phase, baseline: now, peak: now, count: 1)
            return Token(id: id, phase: phase)
        }
    }

    /// 采一次样，更新所有进行中阶段的峰值。
    public func sample() {
        guard let now = reader.physFootprintBytes() else { return }
        state.withLock { s in
            for k in Array(s.active.keys) {
                guard var a = s.active[k] else { continue }
                a.peak = max(a.peak, now)
                a.count += 1
                s.active[k] = a
            }
        }
    }

    @discardableResult
    public func end(_ token: Token) -> PeakMemorySample? {
        sample()
        let cap = capacity
        return state.withLock { s -> PeakMemorySample? in
            guard let a = s.active.removeValue(forKey: token.id) else { return nil }
            let out = PeakMemorySample(phase: a.phase, baselineBytes: a.baseline, peakBytes: a.peak, sampleCount: a.count)
            s.finished.append(out)
            if s.finished.count > cap { s.finished.removeFirst(s.finished.count - cap) }
            return out
        }
    }

    public func samples() -> [PeakMemorySample] { state.withLock { $0.finished } }
    public func reset() { state.withLock { $0.finished = [] } }

    /// 每阶段的最大峰值（性能页）。
    public func peakByPhase() -> [MemoryPhase: PeakMemorySample] {
        var out: [MemoryPhase: PeakMemorySample] = [:]
        for s in samples() where (out[s.phase]?.peakBytes ?? 0) <= s.peakBytes { out[s.phase] = s }
        return out
    }
}

/// 换 SQLite 的触发条件（评审 d6fa750 §3，iPhone 11、Release/Internal、10 万条；任一条满足就在 1.0 前换）。
///
/// 真机未必正好 10 万张：行数不足 10 万时按行数线性外推到 10 万，标为 `projected`（只作参考，以 10 万条实测为准）。
public struct SQLiteTriggerCheck: Sendable, Hashable, Identifiable {
    public enum Metric: String, Sendable, Hashable, CaseIterable {
        /// 冷启动加载索引中位数 > 500 ms。
        case indexLoad
        /// 单次提交中位数 > 1 s。
        case indexCommit
        /// 首扫期间提交累计 > 首扫总耗时 5%。
        case firstScanCommitShare
        /// 索引读写造成的峰值内存增量 > 150 MB（索引加载 / 扫描阶段）。
        case indexMemoryDelta
        /// 一次全量 diff（libraryDiff，含随后的提交）> 2 s。
        case fullDiff
    }
    public enum Verdict: String, Sendable, Hashable {
        case ok, triggered, projectedTrigger, noData
    }

    public var id: Metric { metric }
    public var metric: Metric
    /// 实测值（秒 / 比例 / 字节，见 `metric`）。
    public var measured: Double?
    /// 外推到 10 万条后的值（行数 ≥ 10 万时等于实测）。
    public var at100k: Double?
    public var threshold: Double
    public var rows: Int
    public var verdict: Verdict

    public static let referenceRows = 100_000

    public var label: String {
        switch metric {
        case .indexLoad: return "索引加载中位数 > 500 ms"
        case .indexCommit: return "单次提交中位数 > 1 s"
        case .firstScanCommitShare: return "首扫提交累计 > 首扫 5%"
        case .indexMemoryDelta: return "索引峰值内存增量 > 150 MB"
        case .fullDiff: return "全量 diff > 2 s"
        }
    }

    public static func evaluate(samples: [PerfSample], memory: [PeakMemorySample]) -> [SQLiteTriggerCheck] {
        func median(_ phase: PerfPhase) -> (Double, Int)? {
            let list = samples.filter { $0.phase == phase }
            guard !list.isEmpty else { return nil }
            let secs = list.map(\.seconds).sorted()
            let items = list.map(\.items).sorted()
            return (PerfReport.percentile(secs, 0.5), items[items.count / 2])
        }
        func scaled(_ metric: Metric, _ v: (Double, Int)?, threshold: Double) -> SQLiteTriggerCheck {
            guard let (value, rows) = v else {
                return SQLiteTriggerCheck(metric: metric, measured: nil, at100k: nil, threshold: threshold, rows: 0, verdict: .noData)
            }
            let full = rows >= referenceRows
            let projected = rows > 0 && !full ? value * Double(referenceRows) / Double(rows) : value
            let verdict: Verdict = value > threshold ? .triggered : (projected > threshold ? .projectedTrigger : .ok)
            return SQLiteTriggerCheck(metric: metric, measured: value, at100k: projected, threshold: threshold, rows: rows, verdict: verdict)
        }
        var out: [SQLiteTriggerCheck] = []
        out.append(scaled(.indexLoad, median(.indexLoad), threshold: 0.5))
        out.append(scaled(.indexCommit, median(.indexCommit), threshold: 1.0))

        // 首扫占比：同一 note=initial 的 scanCommitTotal / scanTotal（比例不外推）
        let wall = samples.last { $0.phase == .scanTotal && $0.note == PerfNote.initialScan }
        let commit = samples.last { $0.phase == .scanCommitTotal && $0.note == PerfNote.initialScan }
        if let wall, let commit, wall.seconds > 0 {
            let share = commit.seconds / wall.seconds
            out.append(SQLiteTriggerCheck(metric: .firstScanCommitShare, measured: share, at100k: nil, threshold: 0.05,
                                          rows: wall.items, verdict: share > 0.05 ? .triggered : .ok))
        } else {
            out.append(SQLiteTriggerCheck(metric: .firstScanCommitShare, measured: nil, at100k: nil, threshold: 0.05, rows: 0, verdict: .noData))
        }

        // 内存：索引加载与扫描阶段的最大增量（不外推：与缩略图并发等无关项混在一起，外推无意义）
        let mem = memory.filter { $0.phase == .indexLoad || $0.phase == .scan }.map(\.deltaBytes).max()
        let memThreshold = 150.0 * 1024 * 1024
        if let mem {
            out.append(SQLiteTriggerCheck(metric: .indexMemoryDelta, measured: Double(mem), at100k: nil, threshold: memThreshold,
                                          rows: 0, verdict: Double(mem) > memThreshold ? .triggered : .ok))
        } else {
            out.append(SQLiteTriggerCheck(metric: .indexMemoryDelta, measured: nil, at100k: nil, threshold: memThreshold, rows: 0, verdict: .noData))
        }

        // 全量 diff：取最大一次（libraryDiff 的计时已包含 tombstone 提交）
        let diffs = samples.filter { $0.phase == .libraryDiff }
        if let worst = diffs.max(by: { $0.seconds < $1.seconds }) {
            out.append(scaled(.fullDiff, (worst.seconds, worst.items), threshold: 2.0))
        } else {
            out.append(scaled(.fullDiff, nil, threshold: 2.0))
        }
        return out
    }

    /// 纯文本（性能页「复制」）。
    public static func plainText(_ checks: [SQLiteTriggerCheck]) -> String {
        var lines = ["sqlite_trigger\tverdict\tmeasured\tat_100k\tthreshold\trows"]
        for c in checks {
            let m = c.measured.map { String($0) } ?? "-"
            let p = c.at100k.map { String($0) } ?? "-"
            lines.append("\(c.metric.rawValue)\t\(c.verdict.rawValue)\t\(m)\t\(p)\t\(c.threshold)\t\(c.rows)")
        }
        return lines.joined(separator: "\n")
    }
}
