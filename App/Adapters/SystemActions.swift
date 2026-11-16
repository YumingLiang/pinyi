import Photos
import PhotosUI
import UIKit

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

/// `beginBackgroundTask` 包装（决定 5：扫描 / 生成进后台申请宽限时间，到期回调里取消）。
@MainActor
final class BackgroundTaskGuard {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) {
        end()
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpire()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
