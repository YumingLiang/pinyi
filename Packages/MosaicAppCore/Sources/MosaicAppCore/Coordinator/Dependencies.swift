import Foundation
import MosaicCore

// 架构师 G-3：AppCoordinator 的依赖全部是协议，生产用 `.live`（App target），测试用假实现。
// 不用单例、不在生产代码里放 `#if TESTING` 钩子。

// MARK: - 相册

/// 相册客户端：读取授权 / 枚举（`PhotoLibraryProviding`）+ 「仅添加」授权与写入相册（导出保存）。
/// 取图走 `ThumbnailProviding`（扫描 / 预览）和 `MosaicExporting`（导出取原图）。
public protocol PhotoLibraryClient: PhotoLibraryProviding {
    /// 「仅添加照片」授权（`PHPhotoLibrary.authorizationStatus(for: .addOnly)`，T8：保存只要 add-only）。
    func addOnlyAuthorizationStatus() -> PhotoAuthorization
    func requestAddOnlyAuthorization() async -> PhotoAuthorization
    /// 把文件写进系统相册（`PHAssetCreationRequest`）。
    func saveImageToLibrary(fileURL: URL) async throws
}

// MARK: - 时钟

/// 时钟：读单调时间 + 睡眠（提交间隔、去抖、内存采样间隔）。测试用手动推进的假时钟，不真睡。
public protocol AppClock: Sendable {
    /// 单调秒。
    func now() -> Double
    /// 睡 `seconds` 秒；被取消时抛 `CancellationError`。
    func sleep(seconds: Double) async throws
}

public extension AppClock {
    var monotonic: MonotonicClock { MonotonicClock { self.now() } }
}

/// 系统时钟（`ContinuousClock`）。
public struct SystemClock: AppClock {
    private let origin = ContinuousClock.now
    public init() {}
    public func now() -> Double {
        let d = origin.duration(to: ContinuousClock.now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
    }
}

// MARK: - 生命周期

/// 需要后台宽限的工作（`beginBackgroundTask`）。
public enum BackgroundWork: String, Sendable, Hashable, CaseIterable {
    case scan, generate, export
}

public enum LifecycleEvent: Sendable, Hashable {
    /// 回到前台并激活（scenePhase `.active`）。
    case becameActive
    /// 进入后台（scenePhase `.background`）。
    case enteredBackground
    /// 某项后台宽限到期（`beginBackgroundTask` 的 expiration handler）。
    case backgroundTimeExpired(BackgroundWork)
}

/// 前台 / 后台 / 后台到期事件源 + 后台宽限申请。App 里由 scenePhase 与 `UIApplication.beginBackgroundTask` 驱动。
public protocol LifecycleEvents: Sendable {
    /// 事件流（每次调用返回同一事件源的一个订阅；`AppCoordinator.start()` 只订阅一次）。
    func events() -> AsyncStream<LifecycleEvent>
    /// 申请后台宽限；到期时事件流送出 `.backgroundTimeExpired(work)`。重复申请同一项是幂等的。
    /// 主线程调用（`UIApplication.beginBackgroundTask` 需要主线程）。
    @MainActor func beginBackgroundWork(_ work: BackgroundWork)
    @MainActor func endBackgroundWork(_ work: BackgroundWork)
}

// MARK: - 本地偏好

/// 只存两个布尔偏好（首启已看完、受限已确认）。App 用 `UserDefaults`。
public protocol PreferenceStore: Sendable {
    func bool(_ key: PreferenceKey) -> Bool
    func set(_ value: Bool, for key: PreferenceKey)
}

public enum PreferenceKey: String, Sendable, Hashable, CaseIterable {
    case onboardingCompleted = "onboarding.completed"
    case limitedAcknowledged = "permission.limited.acknowledged"
}

// MARK: - 生成

/// 生成引擎（`GenerationRunner` 是生产实现；测试可包一层计数 / 阻塞）。
public protocol MosaicGenerating: Sendable {
    func run(target: PixelBuffer, snapshot: IndexSnapshot, settings: GenerationSettings, seed: UInt64,
             progress: (@Sendable (Double) -> Void)?) async throws -> GenerationProduct
    func reshuffle(_ previous: GenerationProduct, target: PixelBuffer, settings: GenerationSettings, seed: UInt64,
                   progress: (@Sendable (Double) -> Void)?) async throws -> GenerationProduct
    func run(target: PixelBuffer, snapshot: IndexSnapshot, settings: GenerationSettings, seed: UInt64,
             progress: (@Sendable (Double) -> Void)?, stage: (@Sendable (GenerationStage) -> Void)?) async throws -> GenerationProduct
    func reshuffle(_ previous: GenerationProduct, target: PixelBuffer, settings: GenerationSettings, seed: UInt64,
                   progress: (@Sendable (Double) -> Void)?, stage: (@Sendable (GenerationStage) -> Void)?) async throws -> GenerationProduct
    func invalidateLocalResolution()
}

/// 带阶段回报的版本 + 相册变化通知（默认实现转发到旧接口 / 什么都不做，旧的测试替身不用改）。
public extension MosaicGenerating {
    func run(target: PixelBuffer, snapshot: IndexSnapshot, settings: GenerationSettings, seed: UInt64,
             progress: (@Sendable (Double) -> Void)?, stage: (@Sendable (GenerationStage) -> Void)?) async throws -> GenerationProduct {
        try await run(target: target, snapshot: snapshot, settings: settings, seed: seed, progress: progress)
    }
    func reshuffle(_ previous: GenerationProduct, target: PixelBuffer, settings: GenerationSettings, seed: UInt64,
                   progress: (@Sendable (Double) -> Void)?, stage: (@Sendable (GenerationStage) -> Void)?) async throws -> GenerationProduct {
        try await reshuffle(previous, target: target, settings: settings, seed: seed, progress: progress)
    }
    /// 相册变化（清晰度探测缓存失效）。
    func invalidateLocalResolution() {}
}

extension GenerationRunner: MosaicGenerating {}

// MARK: - 导出

/// ⚠️ 已作废（由 `ExportTier` 取代），保留类型只为兼容旧引用。
public enum ExportSize: Int, Sendable, Hashable, CaseIterable, Codable {
    case standard = 4000
    case large = 6000
    case internal8000 = 8000

    public var longEdge: Int { rawValue }
    public static let userChoices: [ExportSize] = [.standard, .large]

    public var titleKey: L10nKey? {
        switch self {
        case .standard: return .exportSizeShare
        case .large: return .exportSizeHD
        case .internal8000: return nil
        }
    }
}

public struct ExportRequest: Sendable {
    /// 显式布局（结果页由 `MosaicLayout(product:)` 固化，作品页直接给保存的布局）。
    public var layout: MosaicLayout
    /// 叠加层用的目标图；nil 时不叠加。
    public var target: PixelBuffer?
    public var overlayAlpha: Double
    public var tier: ExportTier
    /// 「我的作品」兜底格：格子下标 → 小图（旧预览裁出的那一格）。这些格子不取照片，把小图放大填满
    /// （`.high` 插值，不用最近邻），再照常叠加。结果页导出为空。
    public var cellFallbacks: [Int: PixelBuffer]

    public init(layout: MosaicLayout, target: PixelBuffer?, overlayAlpha: Double? = nil, tier: ExportTier,
                cellFallbacks: [Int: PixelBuffer] = [:]) {
        self.layout = layout
        self.target = target
        self.overlayAlpha = target == nil ? 0 : (overlayAlpha ?? layout.params.overlayAlpha)
        self.tier = tier
        self.cellFallbacks = cellFallbacks
    }

    public init(product: GenerationProduct, target: PixelBuffer, overlayAlpha: Double, tier: ExportTier) {
        self.init(layout: MosaicLayout(product: product, overlayAlpha: overlayAlpha),
                  target: target, overlayAlpha: overlayAlpha, tier: tier)
    }

    /// 尺寸方案；平台层分配位图前传入 `os_proc_available_memory()`，上限随可用内存变化。
    public func plan(availableMemoryBytes: Int64?) -> ExportPlan {
        ExportPlan(tier: tier, columns: layout.cols, rows: layout.rows, availableMemoryBytes: availableMemoryBytes)
    }
}

public enum ExportError: Error, Sendable, Equatable {
    /// 预检或写入中磁盘不足。
    case insufficientStorage
    /// 编码失败等其他错误。
    case encodingFailed
}

/// 导出器：把结果渲染成文件（`tmp/export/` 下），返回文件 URL。
public protocol MosaicExporting: Sendable {
    /// 本次导出预计需要的磁盘字节数（预检用）。
    func estimatedBytes(for request: ExportRequest) -> Int64
    /// 可用磁盘字节数（`volumeAvailableCapacityForImportantUsage`）；读不到返回 nil（不拦截）。
    func availableBytes() -> Int64?
    /// 渲染并编码到临时文件。被取消时抛 `CancellationError` 并删掉半截文件。
    func export(_ request: ExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// 删除单个导出文件（保存 / 分享结束后）。
    func discard(_ url: URL)
    /// 启动时清空 `tmp/export/`（B-27：上次导出中被杀留下的临时文件）。
    func removeStaleExports()
}

// MARK: - 依赖集合

/// AppCoordinator 的全部依赖。
public struct AppDependencies: Sendable {
    public var library: any PhotoLibraryClient
    public var thumbnails: any ThumbnailProviding
    public var indexStore: any IndexStore
    public var clock: any AppClock
    public var lifecycle: any LifecycleEvents
    public var preferences: any PreferenceStore
    public var generator: any MosaicGenerating
    public var exporter: any MosaicExporting
    public var memory: any MemoryFootprintReading
    public var perf: PerfRecorder
    public var indexConfiguration: PhotoIndex.Configuration
    public var initialSeed: UInt64
    /// 导出成功（文件已在 tmp/export，保存 / 分享之前）时通知：「我的作品」由这里刷新「存到我的作品」按钮（导出不自动存，B10-1）。默认空实现。
    public var onExportSucceeded: @Sendable (MosaicLayout, URL) async -> Void

    public init(library: any PhotoLibraryClient, thumbnails: any ThumbnailProviding, indexStore: any IndexStore,
                clock: any AppClock, lifecycle: any LifecycleEvents, preferences: any PreferenceStore,
                generator: any MosaicGenerating, exporter: any MosaicExporting, memory: any MemoryFootprintReading,
                perf: PerfRecorder, indexConfiguration: PhotoIndex.Configuration = .init(), initialSeed: UInt64,
                onExportSucceeded: @escaping @Sendable (MosaicLayout, URL) async -> Void = { _, _ in }) {
        self.library = library
        self.thumbnails = thumbnails
        self.indexStore = indexStore
        self.clock = clock
        self.lifecycle = lifecycle
        self.preferences = preferences
        self.generator = generator
        self.exporter = exporter
        self.memory = memory
        self.perf = perf
        self.indexConfiguration = indexConfiguration
        self.initialSeed = initialSeed
        self.onExportSucceeded = onExportSucceeded
    }
}
