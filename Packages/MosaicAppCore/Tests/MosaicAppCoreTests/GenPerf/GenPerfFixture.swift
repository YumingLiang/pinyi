// QA 生成性能回归（qa/perf/gen-perf-regression-plan.md）—— 固定素材集 + fake PhotoKit + 计数。
// 只用 MosaicAppCore / MosaicCore 的 public API（不 @testable），以便 `swift test -c release` 也能编译。
// 依赖 GenPerfWiring.swift（按 commit 选适配层：adapters/GenPerfWiring_66dc745.swift 或 GenPerfWiring_current.swift）。
import Foundation
import MosaicCore
import MosaicAppCore

// MARK: - 确定性随机数

struct GPRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

final class GPLocked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    @discardableResult func update<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - 固定素材集

/// 一张合成照片的"本机状态"。
enum GPAssetKind: String, Sendable, Codable, CaseIterable {
    /// 本机有原图（≥ 256 px）。
    case local
    /// 本机最好的版本短边 < 256（老照片 / 截图缩略 / 低清晰度）。
    case lowRes
    /// 只在 iCloud：本机只有扫描时拿到的小缩略图，大图需要联网（不允许）。
    case iCloudOnly
    /// PhotoKit 请求报错。
    case failing
}

struct GPAsset: Sendable {
    var id: String
    var kind: GPAssetKind
    var pixelWidth: Int
    var pixelHeight: Int
    /// 本机最好版本的长边像素。
    var localLongEdge: Int
    var color: (UInt8, UInt8, UInt8)
    var gradient: (Int, Int)
}

/// 固定素材集 v1：seed 固定，改动任何参数都要同步重跑基线（plan §2）。
struct GPMaterialSet: Sendable {
    static let version = 1
    static let seed: UInt64 = 0x50_49_4E_59_49_31   // "PINYI1"
    static let defaultCount = 2000

    let assets: [GPAsset]
    let byID: [String: GPAsset]

    /// - Parameter mix: 各类占比（剩余是 local）。
    init(count: Int = GPMaterialSet.defaultCount, lowRes: Double = 0.12, iCloudOnly: Double = 0.08, failing: Double = 0.02,
         seed: UInt64 = GPMaterialSet.seed) {
        var rng = GPRandom(seed: seed)
        // 不同尺寸：4:3 横 / 3:4 竖 / 16:9 / 1:1 / 全景
        let sizes: [(Int, Int)] = [(4032, 3024), (3024, 4032), (1920, 1080), (1080, 1920), (2048, 2048), (4000, 1000)]
        var out: [GPAsset] = []
        for i in 0..<count {
            let r = rng.unit()
            let kind: GPAssetKind = r < lowRes ? .lowRes : r < lowRes + iCloudOnly ? .iCloudOnly
                : r < lowRes + iCloudOnly + failing ? .failing : .local
            var (w, h) = sizes[rng.int(sizes.count)]
            var localLong = max(w, h)
            switch kind {
            case .lowRes:
                // 老照片：原图本身就小（短边 120–240）
                let s = 120 + rng.int(121)
                let ratio = Double(max(w, h)) / Double(min(w, h))
                if w >= h { h = s; w = Int(Double(s) * ratio) } else { w = s; h = Int(Double(s) * ratio) }
                localLong = max(w, h)
            case .iCloudOnly:
                localLong = 256   // 本机只有小缩略图（短边 < 256）
            case .failing, .local:
                break
            }
            let c = (UInt8(rng.int(256)), UInt8(rng.int(256)), UInt8(rng.int(256)))
            let g = (rng.int(81) - 40, rng.int(81) - 40)
            out.append(GPAsset(id: String(format: "gp%04d", i), kind: kind, pixelWidth: w, pixelHeight: h,
                               localLongEdge: localLong, color: c, gradient: g))
        }
        assets = out
        byID = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
    }

    func ids(_ kind: GPAssetKind) -> Set<String> { Set(assets.filter { $0.kind == kind }.map(\.id)) }

    /// 本机能拿到的、按 `maxEdge` 等比缩小的缩略图（扫描路径：长边缩到 maxEdge，不裁方；显示路径可裁方）。
    func image(_ id: String, maxEdge: Int, square: Bool) -> PixelBuffer? {
        guard let a = byID[id] else { return nil }
        let long = min(maxEdge, a.localLongEdge)
        var w: Int, h: Int
        if square {
            // aspectFill + 居中裁方：边长 = min(请求边长, 本机版本短边)
            let localShort = a.localLongEdge * min(a.pixelWidth, a.pixelHeight) / max(a.pixelWidth, a.pixelHeight, 1)
            w = max(1, min(maxEdge, localShort)); h = w
        }
        else if a.pixelWidth >= a.pixelHeight { w = long; h = max(1, long * a.pixelHeight / a.pixelWidth) }
        else { h = long; w = max(1, long * a.pixelWidth / a.pixelHeight) }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let (r0, g0, b0) = (Int(a.color.0), Int(a.color.1), Int(a.color.2))
        let (gx, gy) = a.gradient
        for y in 0..<h {
            let dy = (y * gy) / max(h, 1)
            var o = y * w * 4
            for x in 0..<w {
                let dx = (x * gx) / max(w, 1)
                bytes[o] = UInt8(clamping: r0 + dx)
                bytes[o + 1] = UInt8(clamping: g0 + dy)
                bytes[o + 2] = UInt8(clamping: b0 + (dx - dy) / 2)
                o += 4
            }
        }
        return try? PixelBuffer(width: w, height: h, bytes: bytes)
    }

    /// 固定目标图（平滑色场 + 几个色斑，seed 固定）。1536×1152 ≈ 降采样后常见尺寸量级。
    static func target(width: Int = 1536, height: Int = 1152, seed: UInt64 = 0x7A26_E7) -> PixelBuffer {
        var rng = GPRandom(seed: seed)
        let blobs = (0..<6).map { _ in (rng.unit(), rng.unit(), 0.08 + 0.2 * rng.unit(), rng.int(256), rng.int(256), rng.int(256)) }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let fy = Double(y) / Double(height)
            var o = y * width * 4
            for x in 0..<width {
                let fx = Double(x) / Double(width)
                var r = 255 * fx, g = 255 * fy, b = 128 + 100 * sin(6.28 * (fx + fy))
                for (bx, by, br, cr, cg, cb) in blobs {
                    let d = ((fx - bx) * (fx - bx) + (fy - by) * (fy - by)) / (br * br)
                    if d < 1 { let t = 1 - d; r = r * (1 - t) + Double(cr) * t; g = g * (1 - t) + Double(cg) * t; b = b * (1 - t) + Double(cb) * t }
                }
                bytes[o] = UInt8(clamping: Int(r)); bytes[o + 1] = UInt8(clamping: Int(g)); bytes[o + 2] = UInt8(clamping: Int(b))
                o += 4
            }
        }
        return try! PixelBuffer(width: width, height: height, bytes: bytes)
    }
}

// MARK: - fake PhotoKit

final class GPLibrary: PhotoLibraryProviding, Sendable {
    let set: GPMaterialSet
    init(_ set: GPMaterialSet) { self.set = set }
    func authorizationStatus() -> PhotoAuthorization { .authorized }
    func requestAuthorization() async -> PhotoAuthorization { .authorized }
    func assetCount() async -> Int { set.assets.count }
    func assetMetadata(in range: Range<Int>) async -> [AssetMetadata] {
        let r = range.clamped(to: 0..<set.assets.count)
        return set.assets[r].map { AssetMetadata(id: $0.id, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                                                 pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight) }
    }
    func albums() async -> [AlbumInfo] { [] }
    func assetIDs(inAlbum albumID: String) async throws -> [String] { [] }
}

/// 缩略图（`PHImageManager.requestImage` 的替身）：计数；可对某些照片注入延迟 / 失败 / 本地取不到。
final class GPThumbnails: ThumbnailProviding, Sendable {
    struct State: Sendable {
        var requests: [String: Int] = [:]
        var requestSizes: [Int] = []
        var networkAllowedSeen = false
    }
    let set: GPMaterialSet
    let state = GPLocked(State())
    let delayNanos: [GPAssetKind: UInt64]
    let unavailable: Set<GPAssetKind>
    let failing: Set<GPAssetKind>

    init(_ set: GPMaterialSet, delayNanos: [GPAssetKind: UInt64] = [:], unavailable: Set<GPAssetKind> = [], failing: Set<GPAssetKind> = []) {
        self.set = set
        self.delayNanos = delayNanos
        self.unavailable = unavailable
        self.failing = failing
    }

    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        state.update { s in
            s.requests[assetID, default: 0] += 1
            s.requestSizes.append(request.targetPixelSize)
            if request.isNetworkAccessAllowed { s.networkAllowedSeen = true }
        }
        guard let a = set.byID[assetID] else { return .failed }
        if let d = delayNanos[a.kind], d > 0 { try? await Task.sleep(nanoseconds: d) }
        if unavailable.contains(a.kind) { return .unavailableLocal }
        if failing.contains(a.kind) { return .failed }
        guard let pb = set.image(assetID, maxEdge: request.targetPixelSize, square: request.centerCropToSquare) else { return .failed }
        return .image(pb)
    }

    func reset() { state.update { $0 = State() } }
    var totalRequests: Int { state.get().requests.values.reduce(0, +) }
    var maxRequestsPerAsset: Int { state.get().requests.values.max() ?? 0 }
    var distinctRequested: Int { state.get().requests.count }
}

/// 清晰度探测（`PhotoKitResolutionProbe` 的替身）：按素材类别判定，可注入延迟 / 挂住。只在 GenPerfWiring 注入探测器时被调用。
final class GPProbeLog: Sendable {
    struct State: Sendable {
        var calls: [String: Int] = [:]
        var inFlight = 0
        var maxInFlight = 0
    }
    let state = GPLocked(State())
    let set: GPMaterialSet
    let delayNanos: [GPAssetKind: UInt64]
    /// 挂住直到 Task 取消（模拟 iCloud-only 请求一直不回调）。
    let hang: Set<GPAssetKind>

    init(_ set: GPMaterialSet, delayNanos: [GPAssetKind: UInt64] = [:], hang: Set<GPAssetKind> = []) {
        self.set = set
        self.delayNanos = delayNanos
        self.hang = hang
    }

    /// 返回 (短边像素, 是否在云端, 是否报错)；探测器适配层据此套 `LocalResolutionPolicy.classify`。
    func probe(_ id: String) async -> (shortEdge: Int, inCloud: Bool, failed: Bool) {
        state.update { s in
            s.calls[id, default: 0] += 1
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
        }
        defer { state.update { $0.inFlight -= 1 } }
        guard let a = set.byID[id] else { return (0, false, true) }
        if hang.contains(a.kind) {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            return (0, false, true)
        }
        if let d = delayNanos[a.kind], d > 0 { try? await Task.sleep(nanoseconds: d) }
        switch a.kind {
        case .failing: return (0, false, true)
        case .iCloudOnly: return (0, true, false)
        case .lowRes, .local:
            let short = a.localLongEdge * min(a.pixelWidth, a.pixelHeight) / max(a.pixelWidth, a.pixelHeight, 1)
            return (short, false, false)
        }
    }

    var totalCalls: Int { state.get().calls.values.reduce(0, +) }
    var maxCallsPerAsset: Int { state.get().calls.values.max() ?? 0 }
    func reset() { state.update { $0 = State() } }
}

// MARK: - 计数结果

/// 一次「生成 + 换一种拼法 + 预览取图」的确定性计数。字段名与 baseline.json 一致。
struct GPCounts: Codable, Sendable, Equatable {
    var cells = 0
    /// `MosaicPipeline.generate` 调用次数（= 匹配 + 分配整图跑了几遍），由 PerfRecorder 的 generateTotal 样本数得出。
    var generatePassesRun = 0
    var generatePassesReshuffle = 0
    /// top-k 匹配阶段次数（generateMatching 样本数）。
    var matchPhasesTotal = 0
    /// 分配阶段次数（generateAssigning 样本数）。
    var assignPhasesTotal = 0
    /// 剔除后整图重配轮数（66dc745 无此概念 = 0）。
    var rematchRoundsRun = 0
    var rematchRoundsReshuffle = 0
    /// 最后兜底补格（MosaicPipeline.refill）次数。
    var refillCalls = 0
    /// PhotoKit 清晰度探测请求数（生成 / 换拼法）。
    var probeRequestsRun = 0
    var probeRequestsReshuffle = 0
    /// 同一张照片在一次会话内被探测的最多次数（应 ≤ 1）。
    var probeMaxPerAsset = 0
    /// 生成阶段（不含预览）的缩略图请求数（应为 0）。
    var thumbnailRequestsDuringGenerate = 0
    /// 预览取图请求数（生成 + 换拼法两次预览）；每次预览每张不同照片最多请求 1 次。
    var previewThumbnailRequests = 0
    var previewDistinctAssets = 0
    var previewMaxRequestsPerAssetPerRender = 0
}

/// 一次端到端跑的结果。
struct GPRun: Sendable {
    var counts: GPCounts
    var runSeconds: Double
    var reshuffleSeconds: Double
    var previewSeconds: Double
}

enum GPScenario {
    static let runSeed: UInt64 = 0xA11CE
    static let reshuffleSeed: UInt64 = 0xB0B

    /// 建索引（一次 / 进程），返回快照。
    static func buildSnapshot(set: GPMaterialSet, thumbnails: GPThumbnails) async throws -> IndexSnapshot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gp-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = PhotoIndex.Configuration()
        c.batchSize = 300
        c.maxConcurrentRequests = 16
        c.minRowsPerCommit = 10_000
        c.commitDutyFactor = 0
        let idx = PhotoIndex(directory: dir, library: GPLibrary(set), thumbnails: thumbnails,
                             backupExclusion: GPNoBackup(), configuration: c)
        await idx.load()
        _ = try await idx.synchronize()
        return try await idx.snapshot(for: .allPhotos)
    }

    /// 端到端：生成 → 预览取图 → 换一种拼法 → 预览取图。每次调用用新的 runner（新会话缓存，相当于冷启动后第一次）。
    static func run(density: DensityChoice, snapshot: IndexSnapshot, target: PixelBuffer, set: GPMaterialSet,
                    thumbnails: GPThumbnails, probe: GPProbeLog) async throws -> GPRun {
        let perf = PerfRecorder()
        let runner = GenPerfWiring.makeRunner(probe: probe, perf: perf)
        let settings = GenerationSettings(density: density)
        thumbnails.reset()
        probe.reset()
        let clock = ContinuousClock()
        var counts = GPCounts()

        let t0 = clock.now
        let first = try await runner.run(target: target, snapshot: snapshot, settings: settings, seed: runSeed, progress: nil)
        let tRun = clock.now
        counts.thumbnailRequestsDuringGenerate += thumbnails.totalRequests
        counts.probeRequestsRun = probe.totalCalls
        counts.generatePassesRun = perf.allSamples().filter { $0.phase == .generateTotal }.count
        counts.rematchRoundsRun = GenPerfWiring.rematchRounds(first)
        counts.refillCalls += GenPerfWiring.refilled(first) ? 1 : 0
        counts.cells = first.generation.layout.cellCount

        let (p1, max1) = try await preview(first, thumbnails: thumbnails)
        let tPrev1 = clock.now

        let probeBefore = probe.totalCalls
        let thumbsBefore = thumbnails.totalRequests
        let passesBefore = counts.generatePassesRun
        let second = try await runner.reshuffle(first, target: target, settings: settings, seed: reshuffleSeed, progress: nil)
        let tRe = clock.now
        counts.thumbnailRequestsDuringGenerate += thumbnails.totalRequests - thumbsBefore
        counts.probeRequestsReshuffle = probe.totalCalls - probeBefore
        counts.generatePassesReshuffle = perf.allSamples().filter { $0.phase == .generateTotal }.count - passesBefore
        counts.rematchRoundsReshuffle = GenPerfWiring.rematchRounds(second)
        counts.refillCalls += GenPerfWiring.refilled(second) ? 1 : 0

        let (p2, max2) = try await preview(second, thumbnails: thumbnails)
        let tPrev2 = clock.now

        let samples = perf.allSamples()
        counts.matchPhasesTotal = samples.filter { $0.phase == .generateMatching }.count
        counts.assignPhasesTotal = samples.filter { $0.phase == .generateAssigning }.count
        counts.probeMaxPerAsset = probe.maxCallsPerAsset
        counts.previewThumbnailRequests = p1.requests + p2.requests
        counts.previewDistinctAssets = p1.distinct + p2.distinct
        counts.previewMaxRequestsPerAssetPerRender = max(max1, max2)

        func s(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18 }
        return GPRun(counts: counts, runSeconds: s(tRun - t0), reshuffleSeconds: s(tRe - tPrev1),
                     previewSeconds: s(tPrev1 - tRun) + s(tPrev2 - tRe))
    }

    /// 预览取图（与 App 的 `MosaicPreviewRenderer.thumbnails` 同一取图计划与请求参数 `.scanDisplay`；绘制换成累加，不依赖 CoreGraphics）。
    static func preview(_ p: GenerationProduct, thumbnails: GPThumbnails) async throws -> (stats: (requests: Int, distinct: Int), maxPerAsset: Int) {
        let before = thumbnails.state.get().requests
        let plan = ThumbnailPreviewPlan(cellAssetIDs: p.cellAssetIDs, maxConcurrent: 12)
        var checksum = 0
        try await plan.run(fetch: { id in await thumbnails.thumbnail(for: id, request: .scanDisplay) }) { group, pb in
            checksum &+= pb.width &* group.cells.count
        }
        _ = checksum
        let after = thumbnails.state.get().requests
        var total = 0, maxPer = 0
        for (id, n) in after { let d = n - (before[id] ?? 0); total += d; maxPer = max(maxPer, d) }
        return ((total, plan.groups.count), maxPer)
    }
}

struct GPNoBackup: BackupExclusionApplying {
    func excludeFromBackup(_ url: URL) throws {}
}

// MARK: - 校准基准（与仓库代码无关的固定 CPU 负载，用来把耗时归一化到"本机快慢"）

enum GPCalibration {
    /// 约 30–80 ms 的固定浮点 + 整数负载（类似 top-k 距离内核的访存与乘加）。返回秒。
    static func once() -> Double {
        let n = 1 << 16
        var rng = GPRandom(seed: 42)
        var a = [Float](repeating: 0, count: n * 12)
        for i in a.indices { a[i] = Float(rng.next() & 0xFFFF) / 65535 }
        let q = Array(a[0..<12])
        let clock = ContinuousClock()
        let t0 = clock.now
        var best = Float.greatestFiniteMagnitude
        var bestI = 0
        for rep in 0..<24 {
            for i in 0..<n {
                var d: Float = 0
                let o = i * 12
                for k in 0..<12 { let x = a[o + k] - q[k] + Float(rep) * 1e-6; d += x * x }
                if d < best && i != 0 { best = d; bestI = i }
            }
        }
        let el = clock.now - t0
        precondition(bestI >= 0)
        return Double(el.components.seconds) + Double(el.components.attoseconds) * 1e-18
    }
}

func gpMedian(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// 仓库根目录：本文件在 <root>/Packages/MosaicAppCore/Tests/MosaicAppCoreTests/GenPerf/ 下——去掉文件名再往上 5 级；
/// 放在别处时用环境变量 PINYI_REPO_ROOT。
func gpRepoRoot(file: String = #filePath) -> URL {
    if let r = ProcessInfo.processInfo.environment["PINYI_REPO_ROOT"] { return URL(fileURLWithPath: r) }
    var u = URL(fileURLWithPath: file)
    for _ in 0..<6 { u.deleteLastPathComponent() }
    return u
}

/// 基线路径：PINYI_PERF_BASELINE > <repo>/perf/gen-perf-counts.json（入库，只有计数）> <repo>/perf/gen-perf-baseline.json（旧名）> <repo>/qa/perf/baseline.json（QA 本地，含耗时）。
func gpBaselineURL() -> URL? {
    let env = ProcessInfo.processInfo.environment
    if let p = env["PINYI_PERF_BASELINE"] { return URL(fileURLWithPath: p) }
    let root = gpRepoRoot()
    for rel in ["perf/gen-perf-counts.json", "perf/gen-perf-baseline.json", "qa/perf/baseline.json"] {
        let u = root.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    return nil
}
