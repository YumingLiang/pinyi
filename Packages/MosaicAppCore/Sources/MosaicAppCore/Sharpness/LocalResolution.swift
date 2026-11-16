import MosaicCore

// 「不能略糊」（hd-export-req-v0.2 F5 / hd-default-and-sharpness-v0.1 方案 1）：
// 生成时只用本机有 ≥ 256 px 版本的照片。不重扫全库——匹配完只探测**实际分到格子上**的资产（去重），
// 不合格的从候选里剔掉，再用原有匹配器（含放宽链）重配，最多 3 轮。全程不联网（isNetworkAccessAllowed = false）。

/// 一张照片本机版本够不够清楚。
public enum LocalResolutionVerdict: Sendable, Hashable {
    case usable
    case unusable(LowResReason)

    public var isUsable: Bool { self == .usable }
}

/// 不够清楚的原因（只进性能页 / 日志，不进界面文案）。
public enum LowResReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// 要的尺寸只在 iCloud（`PHImageResultIsInCloudKey`）。
    case inCloud
    /// 只拿到降质图（`PHImageResultIsDegradedKey`）。
    case degraded
    /// 本机最好的版本短边 < 256 px。
    case tooSmall
    /// 没拿到图（资产不存在 / 无图）。
    case missing
    /// PhotoKit 报错。
    case failed
}

/// 判定规则（纯函数，Linux 可测；PhotoKit 适配器只负责把回调里的字段填进来）。
public enum LocalResolutionPolicy {
    /// 超清每格 256 px（AndyL 11-16 拍板）。
    public static let minPixelSize = 256
    /// 同时在飞的探测请求数。
    public static let maxConcurrentProbes = 8
    /// 剔除后重配的最多轮数。
    public static let maxRematchRounds = 3

    public static func classify(hasImage: Bool, pixelWidth: Int, pixelHeight: Int, isDegraded: Bool,
                                isInCloud: Bool, hasError: Bool, minPixelSize: Int = minPixelSize) -> LocalResolutionVerdict {
        if hasError { return .unusable(.failed) }
        if isInCloud { return .unusable(.inCloud) }
        guard hasImage else { return .unusable(.missing) }
        if isDegraded { return .unusable(.degraded) }
        if min(pixelWidth, pixelHeight) < minPixelSize { return .unusable(.tooSmall) }
        return .usable
    }
}

/// 探测一张照片本机版本的清晰度。App 里是 PhotoKit（`requestImage` 256×256、aspectFill、highQualityFormat、
/// `isNetworkAccessAllowed = false`），测试里是假实现。
///
/// 约定：不得联网；所在 Task 被取消时应尽快返回（此时返回值会被丢弃、不进缓存）。
public protocol LocalResolutionProbing: Sendable {
    func probe(assetID: String, minPixelSize: Int) async -> LocalResolutionVerdict
}

/// 本次会话的探测结果缓存（按 localIdentifier）。相册变化时只清掉「不合格」的条目（可能刚从 iCloud 下载回来），
/// 合格的保留——照片不会自己变糊，避免每次相册变化都重探几千张。
public final class LocalResolutionCache: Sendable {
    private let state = LockedState<[String: LocalResolutionVerdict]>([:])

    public init() {}

    public func verdict(for assetID: String) -> LocalResolutionVerdict? { state.withLock { $0[assetID] } }
    public func store(_ v: LocalResolutionVerdict, for assetID: String) { state.withLock { $0[assetID] = v } }
    public var count: Int { state.withLock { $0.count } }
    /// 已知不合格的 ID（生成前先从候选里剔掉，减少重配轮数）。
    public func knownUnusable() -> Set<String> {
        state.withLock { s in Set(s.compactMap { $0.value.isUsable ? nil : $0.key }) }
    }
    /// 相册变化时调用：清掉不合格条目。
    public func removeUnusable() { state.withLock { s in s = s.filter { $0.value.isUsable } } }
    public func removeAll() { state.withLock { $0.removeAll() } }
}

/// 一轮探测的结果。
public struct LocalResolutionPass: Sendable, Hashable {
    /// 本轮涉及的每个（去重后）ID 的判定。
    public var verdicts: [String: LocalResolutionVerdict]
    /// 实际发出的探测请求数（缓存未命中）。
    public var probed: Int
    /// 缓存命中数。
    public var cacheHits: Int

    public var unusable: Set<String> { Set(verdicts.compactMap { $0.value.isUsable ? nil : $0.key }) }
}

/// 有界并发 + 可取消 + 带缓存的探测器。
public struct LocalResolutionChecker: Sendable {
    public var probe: any LocalResolutionProbing
    public var cache: LocalResolutionCache
    public var maxConcurrent: Int
    public var minPixelSize: Int
    public var maxRematchRounds: Int

    public init(probe: any LocalResolutionProbing, cache: LocalResolutionCache = LocalResolutionCache(),
                maxConcurrent: Int = LocalResolutionPolicy.maxConcurrentProbes,
                minPixelSize: Int = LocalResolutionPolicy.minPixelSize,
                maxRematchRounds: Int = LocalResolutionPolicy.maxRematchRounds) {
        self.probe = probe
        self.cache = cache
        self.maxConcurrent = max(1, maxConcurrent)
        self.minPixelSize = minPixelSize
        self.maxRematchRounds = max(0, maxRematchRounds)
    }

    /// 探测一组 ID（自动去重、先查缓存）。
    /// - Parameter progress: (已完成, 需探测总数)，只统计缓存未命中的部分。
    /// - Throws: Task 被取消时抛 `CancellationError`；取消后到达的结果不入缓存。
    public func check(_ assetIDs: [String], progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> LocalResolutionPass {
        var seen = Set<String>()
        var verdicts: [String: LocalResolutionVerdict] = [:]
        var toProbe: [String] = []
        for id in assetIDs where seen.insert(id).inserted {
            if let v = cache.verdict(for: id) { verdicts[id] = v } else { toProbe.append(id) }
        }
        let hits = verdicts.count
        try Task.checkCancellation()
        let total = toProbe.count
        if total > 0 {
            let probe = self.probe
            let minPx = minPixelSize
            let cache = self.cache
            let width = min(maxConcurrent, total)
            let probed: [String: LocalResolutionVerdict] = try await withThrowingTaskGroup(
                of: (String, LocalResolutionVerdict).self
            ) { group in
                var next = 0
                for _ in 0..<width {
                    let id = toProbe[next]
                    next += 1
                    group.addTask { (id, await probe.probe(assetID: id, minPixelSize: minPx)) }
                }
                var out: [String: LocalResolutionVerdict] = [:]
                out.reserveCapacity(total)
                while let (id, v) = try await group.next() {
                    try Task.checkCancellation()   // 取消后到达的结果可能是「被取消」造成的失败，不可信
                    cache.store(v, for: id)
                    out[id] = v
                    progress?(out.count, total)
                    if next < total {
                        let nid = toProbe[next]
                        next += 1
                        group.addTask { (nid, await probe.probe(assetID: nid, minPixelSize: minPx)) }
                    }
                }
                return out
            }
            try Task.checkCancellation()
            verdicts.merge(probed) { a, _ in a }
        }
        return LocalResolutionPass(verdicts: verdicts, probed: total, cacheHits: hits)
    }
}

/// 一次生成里「不够清楚而没用上」的统计（来源页文案 + 性能页）。
public struct LowResReport: Sendable, Hashable {
    /// 当前来源里已知不够清楚、因此被排除的照片（去重）。来源页显示其数量。
    public var excludedAssetIDs: Set<String>
    /// 本次生成实际发出的探测请求数。
    public var probedCount: Int
    /// 缓存命中数（各轮累计）。
    public var cacheHits: Int
    /// 剔除后重配的轮数（0 = 第一次就全部合格）。
    public var rematchRounds: Int
    /// 到达最多轮数后仍分到不合格照片的格子数（正常应为 0；非 0 时进日志）。
    public var unresolvedCellCount: Int
    /// 探测总耗时（秒）。
    public var probeSeconds: Double
    /// 是否启用了探测（未注入探测器时为 false）。
    public var enabled: Bool

    public var excludedCount: Int { excludedAssetIDs.count }

    public init(excludedAssetIDs: Set<String> = [], probedCount: Int = 0, cacheHits: Int = 0, rematchRounds: Int = 0,
                unresolvedCellCount: Int = 0, probeSeconds: Double = 0, enabled: Bool = false) {
        self.excludedAssetIDs = excludedAssetIDs
        self.probedCount = probedCount
        self.cacheHits = cacheHits
        self.rematchRounds = rematchRounds
        self.unresolvedCellCount = unresolvedCellCount
        self.probeSeconds = probeSeconds
        self.enabled = enabled
    }

    public static let disabled = LowResReport()

    /// 性能页 / 日志附注。
    public var perfNote: String {
        "去重探测 \(probedCount) · 缓存命中 \(cacheHits) · 排除 \(excludedCount) · 重配 \(rematchRounds) 轮 · 未解决 \(unresolvedCellCount) 格"
    }
}

/// 剔除不够清楚的照片后一张可用的都不剩（走「没有可用照片」路径，`GenerationFailure.noMaterial`）。
public struct NoSharpPhotosError: Error, Sendable, Hashable {
    /// 被排除的张数（来源页仍要显示）。
    public var excludedCount: Int
    public init(excludedCount: Int) { self.excludedCount = excludedCount }
}

/// 生成过程中的阶段（进度页文案用）。
public enum GenerationStage: Sendable, Hashable {
    /// 匹配 / 分配。
    case matching
    /// 检查照片在手机上的版本够不够清楚（`generate.progress.checking`）。
    case checkingSharpness

    public var bodyKey: L10nKey {
        switch self {
        case .matching: return .generateProgressBody
        case .checkingSharpness: return .generateProgressChecking
        }
    }
}

public extension IndexSnapshot {
    /// 去掉给定 ID 对应的行（只动掩码，特征表不变）。返回新快照与实际在快照内、被去掉的 ID。
    func excluding(assetIDs ids: Set<String>) throws -> (snapshot: IndexSnapshot, removed: Set<String>) {
        guard !ids.isEmpty else { return (self, []) }
        var mask = library.mask
        var removed = Set<String>()
        let n = min(assetIDsByRow.count, mask.count)
        for row in 0..<n where mask[row] {
            if let id = assetIDsByRow[row], ids.contains(id) {
                mask[row] = false
                removed.insert(id)
            }
        }
        guard !removed.isEmpty else { return (self, []) }
        let lib = try LibrarySnapshot(table: library.table, rowLimit: library.rowLimit, sourceMask: mask)
        return (IndexSnapshot(library: lib, assetIDsByRow: assetIDsByRow), removed)
    }
}
