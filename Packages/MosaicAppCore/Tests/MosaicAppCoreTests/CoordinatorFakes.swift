import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 一次性闸门（不睡眠：测试靠它精确控制假实现在哪一步停住）。
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters = []
    }
}

/// 第 n 次请求时先 `reached.open()`，再等 `release`。
struct GatePoint: Sendable {
    let reached = AsyncGate()
    let release = AsyncGate()
}

/// 可在指定请求序号停住的缩略图来源（包一层 `FakeThumbnails`）。
final class GatedThumbnails: ThumbnailProviding, Sendable {
    let inner = FakeThumbnails()
    let gates: [Int: GatePoint]
    let counter = Locked(0)
    let stopAllCount = Locked(0)
    init(gates: [Int: GatePoint] = [:]) { self.gates = gates }
    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        let n = counter.update { c -> Int in c += 1; return c }
        if let g = gates[n] {
            await g.reached.open()
            await g.release.wait()
        }
        return await inner.thumbnail(for: assetID, request: request)
    }
    func stopAllCaching() async { stopAllCount.update { $0 += 1 } }
}

/// 手动推进的时钟：`sleep` 挂起到 `advance` 越过截止时间；被取消立即抛错。
final class FakeClock: AppClock, Sendable {
    private struct Sleeper: Sendable { let deadline: Double; let c: CheckedContinuation<Void, any Error> }
    private struct State: Sendable { var now = 0.0; var next = 0; var sleepers: [Int: Sleeper] = [:] }
    private let state = LockedState(State())

    func now() -> Double { state.withLock { $0.now } }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(seconds: Double) async throws {
        let id = state.withLock { s -> Int in s.next += 1; return s.next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let resumeNow = state.withLock { s -> Bool in
                    if seconds <= 0 { return true }
                    s.sleepers[id] = Sleeper(deadline: s.now + seconds, c: c)
                    return false
                }
                if resumeNow { c.resume() }
                if Task.isCancelled, let sl = state.withLock({ $0.sleepers.removeValue(forKey: id) }) {
                    sl.c.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            if let sl = state.withLock({ $0.sleepers.removeValue(forKey: id) }) { sl.c.resume(throwing: CancellationError()) }
        }
    }

    func advance(_ d: Double) {
        let due = state.withLock { s -> [Sleeper] in
            s.now += d
            let ready = s.sleepers.filter { $0.value.deadline <= s.now }
            for k in ready.keys { s.sleepers[k] = nil }
            return Array(ready.values)
        }
        for sl in due { sl.c.resume() }
    }
}

/// 生命周期事件源：测试 `send` 事件；记录后台宽限申请。
final class FakeLifecycle: LifecycleEvents, Sendable {
    private let stream: AsyncStream<LifecycleEvent>
    private let continuation: AsyncStream<LifecycleEvent>.Continuation
    let begun = Locked<[BackgroundWork]>([])
    let ended = Locked<[BackgroundWork]>([])
    init() { (stream, continuation) = AsyncStream<LifecycleEvent>.makeStream() }
    func events() -> AsyncStream<LifecycleEvent> { stream }
    func send(_ e: LifecycleEvent) { continuation.yield(e) }
    @MainActor func beginBackgroundWork(_ work: BackgroundWork) { begun.update { $0.append(work) } }
    @MainActor func endBackgroundWork(_ work: BackgroundWork) { ended.update { $0.append(work) } }
}

final class FakePreferences: PreferenceStore, Sendable {
    let values: Locked<[PreferenceKey: Bool]>
    init(_ v: [PreferenceKey: Bool] = [.onboardingCompleted: true]) { values = Locked(v) }
    func bool(_ key: PreferenceKey) -> Bool { values.get()[key] ?? false }
    func set(_ value: Bool, for key: PreferenceKey) { values.update { $0[key] = value } }
}

/// 包一层真实 `GenerationRunner`：计数、可在开跑前停住。
final class GatedGenerator: MosaicGenerating, Sendable {
    let runner = GenerationRunner()
    let calls = Locked(0)
    let gate: Locked<GatePoint?>
    init(gate: GatePoint? = nil) { self.gate = Locked(gate) }

    private func pass() async {
        calls.update { $0 += 1 }
        if let g = gate.get() {
            await g.reached.open()
            await g.release.wait()
        }
    }
    func run(target: PixelBuffer, snapshot: IndexSnapshot, settings: GenerationSettings, seed: UInt64,
             progress: (@Sendable (Double) -> Void)?) async throws -> GenerationProduct {
        await pass()
        return try await runner.run(target: target, snapshot: snapshot, settings: settings, seed: seed, progress: progress)
    }
    func reshuffle(_ previous: GenerationProduct, target: PixelBuffer, settings: GenerationSettings, seed: UInt64,
                   progress: (@Sendable (Double) -> Void)?) async throws -> GenerationProduct {
        await pass()
        return try await runner.reshuffle(previous, target: target, settings: settings, seed: seed, progress: progress)
    }
}

/// 假导出器：写一个小文件；可配置可用空间 / 错误 / 闸门。
final class FakeExporter: MosaicExporting, Sendable {
    struct State: Sendable {
        var available: Int64?
        var estimate: Int64 = 1_000
        var error: ExportError?
        var exports = 0
        var discarded: [String] = []
        var staleRemovals = 0
    }
    let state = Locked(State())
    let gate: Locked<GatePoint?>
    let dir: URL
    init(gate: GatePoint? = nil) {
        self.gate = Locked(gate)
        dir = makeTempDir()
    }
    func estimatedBytes(for request: ExportRequest) -> Int64 { state.get().estimate }
    func availableBytes() -> Int64? { state.get().available }
    func export(_ request: ExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        state.update { $0.exports += 1 }
        progress(0.5)
        if let g = gate.get() {
            await g.reached.open()
            await g.release.wait()
        }
        try Task.checkCancellation()
        if let e = state.get().error { throw e }
        let url = dir.appendingPathComponent("mosaic-\(request.longEdge)-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        progress(1)
        return url
    }
    func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        state.update { $0.discarded.append(url.lastPathComponent) }
    }
    func removeStaleExports() { state.update { $0.staleRemovals += 1 } }
}

/// 一套假依赖 + 协调器。
@MainActor
struct CoordinatorHarness {
    let library: FakePhotoLibrary
    let thumbnails: GatedThumbnails
    let store: InMemoryIndexStore
    let clock = FakeClock()
    let lifecycle = FakeLifecycle()
    let preferences: FakePreferences
    let generator: GatedGenerator
    let exporter: FakeExporter
    let memory = FakeMemory(100 * 1024 * 1024)
    let coordinator: AppCoordinator

    init(assets: Int, thumbnails: GatedThumbnails = GatedThumbnails(), generator: GatedGenerator = GatedGenerator(),
         exporter: FakeExporter = FakeExporter(), config: PhotoIndex.Configuration = smallConfig(batch: 100, concurrency: 4),
         preferences: FakePreferences = FakePreferences(), auth: PhotoAuthorization = .authorized,
         realExporter: (any MosaicExporting)? = nil) {
        library = FakePhotoLibrary(assetCount: assets)
        library.setAuth(auth)
        self.thumbnails = thumbnails
        self.store = InMemoryIndexStore()
        self.preferences = preferences
        self.generator = generator
        self.exporter = exporter
        let deps = AppDependencies(library: library, thumbnails: thumbnails, indexStore: store, clock: clock,
                                   lifecycle: lifecycle, preferences: preferences, generator: generator, exporter: realExporter ?? exporter,
                                   memory: memory, perf: PerfRecorder(), indexConfiguration: config, initialSeed: 42)
        coordinator = AppCoordinator(dependencies: deps)
    }

    /// 目标图：64×48 渐变。
    static func target() throws -> PixelBuffer {
        let w = 64, h = 48
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            bytes[o] = UInt8(x * 4); bytes[o + 1] = UInt8(y * 5); bytes[o + 2] = UInt8((x + y) * 2)
        } }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }
}

/// 等到状态满足条件（基于状态序列，不轮询、不睡眠）。看门狗只防测试写错时 CI 卡死。
@MainActor
func waitFor(_ c: AppCoordinator, _ what: String = "", file: StaticString = #filePath, line: UInt = #line,
             _ predicate: @escaping @MainActor (AppState) -> Bool) async {
    let waiter = Task { @MainActor () -> Bool in
        for await s in c.states() where predicate(s) { return true }
        return false
    }
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: 60_000_000_000)   // 看门狗（60 s），不是同步手段
        waiter.cancel()
    }
    let ok = await waiter.value
    watchdog.cancel()
    if !ok { XCTFail("等待状态超时：\(what)", file: file, line: line) }
}
