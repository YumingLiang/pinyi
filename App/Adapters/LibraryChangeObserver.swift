import Foundation
import Photos
import MosaicAppCore

/// `PHPhotoLibraryChangeObserver` → `AppCoordinator.libraryDidChange()`（去抖在 MosaicAppCore，时间走注入的时钟）。
/// 决定 11：不解析 changeDetails，只触发全量元数据 diff。
/// G-1：只有不可变的 `@Sendable` 闭包，`Sendable` 由编译器检查（NSObject 子类 + final + let）。
/// ⚠️ 盲写：`photoLibraryDidChange` 在后台串行队列回调；闭包里只转发到 MainActor。
final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
