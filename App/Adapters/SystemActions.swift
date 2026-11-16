import Photos
import PhotosUI
import SwiftUI
import UIKit
import MosaicAppCore

/// 系统动作（权限页 / 来源页的副作用）。⚠️ 盲写。
@MainActor
enum SystemActions {
    /// 跳系统设置（`.openSettings`）。
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 受限访问：调系统选择器增加可用照片（决定 1）。iOS 15+ API；回调式版本在 iOS 17 才有，这里用无回调版本，
    /// 选择结果通过 `PHPhotoLibraryChangeObserver` 反映到索引。
    static func presentLimitedLibraryPicker() {
        guard let root = topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

/// 生命周期事件源 + 后台宽限（G-3 `LifecycleEvents` 的 Apple 实现）。
/// scenePhase 由 `RootView` 转进来；`beginBackgroundTask` 到期回调里送 `.backgroundTimeExpired` 并立即结束该任务。
@MainActor
final class AppLifecycle: LifecycleEvents {
    nonisolated let stream: AsyncStream<LifecycleEvent>
    nonisolated let continuation: AsyncStream<LifecycleEvent>.Continuation
    private var tasks: [BackgroundWork: UIBackgroundTaskIdentifier] = [:]

    init() {
        (stream, continuation) = AsyncStream<LifecycleEvent>.makeStream()
    }

    nonisolated func events() -> AsyncStream<LifecycleEvent> { stream }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background: continuation.yield(.enteredBackground)
        case .active: continuation.yield(.becameActive)
        default: break
        }
    }

    func beginBackgroundWork(_ work: BackgroundWork) {
        guard tasks[work] == nil else { return }
        let continuation = self.continuation
        tasks[work] = UIApplication.shared.beginBackgroundTask(withName: work.rawValue) { [weak self] in
            // 到期回调在主线程；必须在回调返回前 endBackgroundTask，所以这里同步处理（R4：assumeIsolated 有运行时检查）。
            MainActor.assumeIsolated {
                continuation.yield(.backgroundTimeExpired(work))
                self?.endBackgroundWork(work)
            }
        }
    }

    func endBackgroundWork(_ work: BackgroundWork) {
        guard let id = tasks.removeValue(forKey: work), id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
