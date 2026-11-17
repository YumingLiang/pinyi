import Foundation
import MosaicCore
import MosaicAppCore

/// `UserDefaults` 偏好（只存两个布尔值）。
struct UserDefaultsPreferences: PreferenceStore {
    func bool(_ key: PreferenceKey) -> Bool { UserDefaults.standard.bool(forKey: key.rawValue) }
    func set(_ value: Bool, for key: PreferenceKey) { UserDefaults.standard.set(value, forKey: key.rawValue) }
}

extension AppDependencies {
    /// 生产依赖（G-3 `.live`）。索引放 `Application Support/Index`，目录排除备份（MF-2）。
    @MainActor
    static func live(lifecycle: AppLifecycle, thumbnails: PhotoKitThumbnails, perf: PerfRecorder,
                     onExportSucceeded: @escaping @Sendable (MosaicLayout, URL) async -> Void = { _, _ in }) -> AppDependencies {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index", isDirectory: true)
        let library = PhotoKitLibrary()
        return AppDependencies(
            library: library,
            thumbnails: thumbnails,
            indexStore: JSONIndexStore(directory: support, backupExclusion: FileBackupExclusion()),
            clock: SystemClock(),
            lifecycle: lifecycle,
            preferences: UserDefaultsPreferences(),
            // 生成只跑一次匹配：不再逐张探测清晰度、不剔除重配（AndyL 11-16 取消 #5 逐张检查，速度回到 14ac550）。
            generator: GenerationRunner.production(pipeline: MosaicPipeline(assigner: GreedyAssigner(kernel: KernelProvider.make())),
                                                   perf: perf),
            exporter: LiveMosaicExporter(thumbnails: thumbnails, perf: perf),
            memory: PhysFootprintReader(),
            perf: perf,
            initialSeed: UInt64.random(in: 1...UInt64.max),
            onExportSucceeded: onExportSucceeded,
            // 记住素材来源（§1a，整组相簿）：只存相簿 ID 的 JSON，key `source.selection`
            preferenceData: UserDefaultsPreferenceData()
        )
    }
}
