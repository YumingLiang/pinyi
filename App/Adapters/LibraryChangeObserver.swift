import Foundation
import Photos
import MosaicAppCore

/// `PHPhotoLibraryChangeObserver` → 去抖（2 s）→ 全量 diff（决定 11：不解析 changeDetails，只触发全量元数据 diff）。
/// ⚠️ 盲写：`photoLibraryDidChange` 在后台串行队列回调；这里只转发到 MainActor。
final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
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

/// 把 `ChangeDebouncer`（纯逻辑）接到真实时钟和定时器上。
@MainActor
final class DebouncedTrigger {
    private var debouncer = ChangeDebouncer(interval: 2, maxDelay: 10)
    private var timer: Timer?
    private let clock = MonotonicClock.system
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) { self.action = action }

    func noteChange() {
        debouncer.noteChange(at: clock.now())
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        guard let t = debouncer.nextFireTime else { return }
        let delay = max(0, t - clock.now())
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.debouncer.fire(now: self.clock.now()) { self.action() } else { self.schedule() }
            }
        }
    }
}
