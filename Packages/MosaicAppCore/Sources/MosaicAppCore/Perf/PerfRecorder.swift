import Foundation
import MosaicCore

/// 性能计时的阶段（内部性能页，决定 13 / 技术方案 §5 退出线）。
public enum PerfPhase: String, Sendable, Hashable, CaseIterable, Codable {
    /// 全量元数据 diff（枚举 PHAsset 元数据 + 比较）。
    case libraryDiff
    /// 取缩略图（PhotoKit 请求 → 白底 sRGB RGBA8）。
    case thumbnailFetch
    /// 特征提取。
    case featureExtract
    /// 批次提交（features.bin + index.json 原子写）。
    case indexCommit
    /// features.bin 压缩重写。
    case compaction
    /// 索引加载（读 features.bin + index.json）。
    case indexLoad
    /// 目标图解码 + 降采样。
    case targetDecode
    /// 生成：目标图每格取样。
    case generateSampling
    /// 生成：top-k 匹配。
    case generateMatching
    /// 生成：约束贪心分配。
    case generateAssigning
    /// 生成：端到端（点「开始拼图」→ 结果可显示）。
    case generateTotal
    /// 预览图绘制。
    case previewRender
    /// 一轮扫描的墙钟总时长（note = `PerfNote.initialScan` / `.incrementalScan`）。
    case scanTotal
    /// 一轮扫描期间提交累计耗时（与 `scanTotal` 同 note；首扫占比 > 5% 是 SQLite 触发条件之一，MF-4 / MF-7）。
    case scanCommitTotal
    /// 清晰度探测（「不能略糊」）：一次生成内各轮探测累计耗时；items = 实际探测张数，note = `LowResReport.perfNote`。
    case sharpnessProbe
    /// 导出端到端（取图 + 画整张 + JPEG）；note = `ExportPlan.logDescription` + 文件大小。峰值 phys_footprint 见 `MemoryPhase.export`。
    case exportTotal

    /// 性能页上的显示名（内部页面，不进文案表）。
    public var label: String {
        switch self {
        case .libraryDiff: return "相册 diff"
        case .thumbnailFetch: return "取缩略图"
        case .featureExtract: return "特征提取"
        case .indexCommit: return "索引提交"
        case .compaction: return "索引压缩"
        case .indexLoad: return "索引加载"
        case .targetDecode: return "目标图解码"
        case .generateSampling: return "生成·取样"
        case .generateMatching: return "生成·匹配"
        case .generateAssigning: return "生成·分配"
        case .generateTotal: return "生成·总计"
        case .previewRender: return "预览绘制"
        case .scanTotal: return "扫描·总计"
        case .scanCommitTotal: return "扫描·提交累计"
        case .sharpnessProbe: return "清晰度探测"
        case .exportTotal: return "导出·总计"
        }
    }
}

/// 样本附注里约定的取值。
public enum PerfNote {
    public static let initialScan = "initial"
    public static let incrementalScan = "incremental"
}

/// 一条计时样本。
public struct PerfSample: Sendable, Hashable, Codable {
    public var phase: PerfPhase
    /// 耗时（秒）。
    public var seconds: Double
    /// 本次处理的单位数（张 / 格）；0 = 不适用。
    public var items: Int
    /// 附注（例如 "medium 80×60"）。
    public var note: String?

    public init(phase: PerfPhase, seconds: Double, items: Int = 0, note: String? = nil) {
        self.phase = phase
        self.seconds = seconds
        self.items = items
        self.note = note
    }
}

/// 单调时钟（注入以便测试）。
public struct MonotonicClock: Sendable {
    public let now: @Sendable () -> Double
    public init(now: @escaping @Sendable () -> Double) { self.now = now }

    /// 系统单调时钟（`ContinuousClock`，iOS 16+ / Linux）。
    public static let system: MonotonicClock = {
        let clock = ContinuousClock()
        let origin = clock.now
        return MonotonicClock {
            let d = origin.duration(to: clock.now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        }
    }()
}

/// 线程安全的计时记录器。只保留最近 `capacity` 条，内存有界。
/// G-1：状态放在 `LockedState` 里，本类型的 `Sendable` 由编译器检查（不再 `@unchecked`）。
public final class PerfRecorder: Sendable {
    public let clock: MonotonicClock
    public let capacity: Int
    private let samples = LockedState<[PerfSample]>([])

    public init(clock: MonotonicClock = .system, capacity: Int = 2000) {
        self.clock = clock
        self.capacity = max(1, capacity)
    }

    public func record(_ sample: PerfSample) {
        let cap = capacity
        samples.withLock { s in
            s.append(sample)
            if s.count > cap { s.removeFirst(s.count - cap) }
        }
    }

    public func record(_ phase: PerfPhase, seconds: Double, items: Int = 0, note: String? = nil) {
        record(PerfSample(phase: phase, seconds: seconds, items: items, note: note))
    }

    /// 计时一段同步代码。
    @discardableResult
    public func measure<T>(_ phase: PerfPhase, items: Int = 0, note: String? = nil, _ body: () throws -> T) rethrows -> T {
        let t0 = clock.now()
        defer { record(phase, seconds: clock.now() - t0, items: items, note: note) }
        return try body()
    }

    /// 计时一段异步代码。
    @discardableResult
    public func measure<T>(_ phase: PerfPhase, items: Int = 0, note: String? = nil,
                           _ body: () async throws -> T) async rethrows -> T {
        let t0 = clock.now()
        defer { record(phase, seconds: clock.now() - t0, items: items, note: note) }
        return try await body()
    }

    public func allSamples() -> [PerfSample] { samples.get() }

    public func reset() { samples.set([]) }

    public func report() -> PerfReport { PerfReport(samples: allSamples()) }
}

/// 生成阶段计时：把内核的进度回调（取样 → 匹配 → 分配）切成三段耗时。
/// 回调可能来自任意线程，内部加锁。
public final class GenerationPhaseTimer: Sendable {
    private struct State: Sendable {
        var phaseStart: [MosaicProgressPhase: Double] = [:]
        var lastPhase: MosaicProgressPhase?
    }
    private let clock: MonotonicClock
    private let start: Double
    private let state = LockedState(State())

    public init(clock: MonotonicClock) {
        self.clock = clock
        self.start = clock.now()
    }

    public func observe(_ phase: MosaicProgressPhase) {
        let now = clock.now()
        state.withLock { s in
            if s.phaseStart[phase] == nil { s.phaseStart[phase] = now }
            s.lastPhase = phase
        }
    }

    /// 结束：返回各阶段耗时（阶段 i 的结束 = 下一个出现的阶段开始，最后一段到 `finish` 时刻）。
    public func finish(cells: Int, note: String?) -> [PerfSample] {
        let end = clock.now()
        let starts = state.withLock { $0.phaseStart }
        let ordered = MosaicProgressPhase.allCases.compactMap { p in starts[p].map { (p, $0) } }
        var out: [PerfSample] = []
        for (i, (p, t)) in ordered.enumerated() {
            let tEnd = i + 1 < ordered.count ? ordered[i + 1].1 : end
            out.append(PerfSample(phase: p.perfPhase, seconds: max(0, tEnd - t), items: cells, note: note))
        }
        out.append(PerfSample(phase: .generateTotal, seconds: max(0, end - start), items: cells, note: note))
        return out
    }
}

/// 与 `MosaicCore.MosaicProgress.Phase` 对应（避免本文件 import MosaicCore 的类型细节泄漏到性能页）。
public enum MosaicProgressPhase: Int, Sendable, Hashable, CaseIterable {
    case sampling, matching, assigning

    var perfPhase: PerfPhase {
        switch self {
        case .sampling: return .generateSampling
        case .matching: return .generateMatching
        case .assigning: return .generateAssigning
        }
    }
}
