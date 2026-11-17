import Foundation
import Photos
import MosaicAppCore

/// 选图页 / 来源页共用的相册变化监听（photo-picker-v0.1 §2「相册变化」、§3；T3）。
///
/// - 全 App 一个（`shared`），第一次有人订阅时才向 `PHPhotoLibrary` 注册（避免授权前注册）。
/// - `photoLibraryDidChange` 在 PhotoKit 的后台串行队列回调；这里只把 `PHChange` 转发到主线程，
///   由各个网格数据源各自取 `changeDetails(for:)`、先换成新的 fetch result、再通知网格（`AssetGridChange`）。
/// - 增量还是整体 reload 由 `GridChangePlanner.plan`（MosaicAppCore，Linux 单测）决定。
/// - 相簿列表等只关心「变了」的订阅方用 `addListener`，收到后自己重新读（例如 `AlbumCatalogProviding.catalogSnapshot()`）。
///
/// 隐藏照片：所有 fetch result 都来自 `PhotoFetch`（`includeHiddenAssets = false`）。照片被设为隐藏后，PhotoKit 算出的
/// `fetchResultAfterChanges` 里就没有它，`removedIndexes` 里有它的旧下标，所以网格里表现为删除，不需要特殊处理。
///
/// 素材索引仍由 `LibraryChangeObserver` → `AppCoordinator.libraryDidChange()` → 防抖后 `PhotoIndex.applyFullDiff()` 处理：
/// diff 时 `PhotoKitLibrary.assetCount()` 重新调用 `PhotoFetch.allImages`，隐藏照片不在 `current` 里，
/// `LibraryDiff.compute` 把它判为 `deleted`（tombstone + 删条目），下次生成不会用到。见 `PickerSupportTests`。
/// 两个监听以后（T5/T6）可以合并成这一个，本 PR 不动 AppModel 的注册逻辑。
/// ⚠️ 盲写（Linux 只做 swiftc -parse）。
@MainActor
final class PhotoLibraryObserver {
    static let shared = PhotoLibraryObserver()

    private final class WeakTarget {
        weak var value: (any PhotoLibraryChangeTarget)?
        init(_ v: any PhotoLibraryChangeTarget) { value = v }
    }

    private var bridge: Bridge?
    private var targets: [WeakTarget] = []
    private var listeners: [UUID: @MainActor () -> Void] = [:]

    private init() {}

    /// 订阅变化（网格数据源用）。重复订阅同一对象只算一次。
    func register(_ target: any PhotoLibraryChangeTarget) {
        ensureRegistered()
        targets.removeAll { $0.value == nil || $0.value === target }
        targets.append(WeakTarget(target))
    }

    func unregister(_ target: any PhotoLibraryChangeTarget) {
        targets.removeAll { $0.value == nil || $0.value === target }
    }

    /// 只要「变了」的订阅（相簿列表、缩略图加载器清缓存等）。返回的 token 用于取消。
    @discardableResult
    func addListener(_ handler: @escaping @MainActor () -> Void) -> UUID {
        ensureRegistered()
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func removeListener(_ id: UUID) { listeners[id] = nil }

    private func ensureRegistered() {
        guard bridge == nil else { return }
        bridge = Bridge { box in
            // 后台队列 → 主线程。PHChange 只在主线程读（见 ChangeBox）。
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PhotoLibraryObserver.shared.deliver(box.change) }
            }
        }
    }

    private func deliver(_ change: PHChange) {
        targets.removeAll { $0.value == nil }
        // 先让数据源换成新 fetch result，再通知只关心「变了」的订阅方（它们可能会读数据源）。
        for t in targets { t.value?.photoLibraryDidChange(change) }
        for h in listeners.values { h() }
    }

    /// `PHChange` 不一定标了 Sendable：它是 PhotoKit 交给我们的不可变快照，这里只做一次跨线程转交（后台 → 主线程），
    /// 之后只在主线程读，所以用 `@unchecked Sendable` 包一层（和 MosaicCore 里只读指针包装同一做法）。
    struct ChangeBox: @unchecked Sendable {
        let change: PHChange
    }

    /// 真正注册到 PHPhotoLibrary 的对象（nonisolated，回调在后台队列）。
    private final class Bridge: NSObject, PHPhotoLibraryChangeObserver, Sendable {
        private let onChange: @Sendable (ChangeBox) -> Void

        init(onChange: @escaping @Sendable (ChangeBox) -> Void) {
            self.onChange = onChange
            super.init()
            PHPhotoLibrary.shared().register(self)
        }

        deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

        func photoLibraryDidChange(_ changeInstance: PHChange) {
            onChange(ChangeBox(change: changeInstance))
        }
    }
}

/// 能处理 `PHChange` 的订阅方（网格数据源）。`PhotoLibraryObserver` 弱引用它，释放后自动失效。
@MainActor
protocol PhotoLibraryChangeTarget: AnyObject {
    func photoLibraryDidChange(_ change: PHChange)
}
