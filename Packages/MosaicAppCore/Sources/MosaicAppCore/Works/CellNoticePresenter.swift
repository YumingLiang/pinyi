import Foundation
import MosaicCore

/// 缺图轻提示（`works.missing` / `works.replaced`，copy v1.3「几秒后自动消失，不打断操作」）。
///
/// 按格计数：`missingCells` / `replacedCells` 都是格子数，不是照片张数。两边都是 0 就不出。
/// 一次 `present` 只自动收起一次；`cancel()`（关掉查看页、换作品、手动点掉）让到点不再调用 `fire`。
/// 「只提示一次」由调用方保证：只在本次真的新出现格子时 `present`，收起之后再次打开本来就是 0 格。
public final class CellNoticePresenter {
    public var duration: Duration

    private struct Slot: Sendable {
        var generation: UInt64 = 0
        var job: Task<Void, Never>?
    }
    private let slot = LockedState(Slot())

    public init(duration: Duration = .seconds(4)) {
        self.duration = duration
    }

    /// 有格子才计时。到点、这次 present 没被取消、且 `stillCurrent` 仍为真时调用 `fire`
    /// （通常只清本次格数，不改作品）。新的一次 `present` 会取消上一次。
    /// 两个回调在主线程上跑，才能读查看页状态。
    public func present(missingCells: Int, replacedCells: Int,
                        stillCurrent: @escaping @MainActor () -> Bool,
                        fire: @escaping @MainActor () -> Void) {
        let duration = duration
        let generation: UInt64 = slot.withLock { s in
            s.job?.cancel()
            s.generation += 1
            s.job = nil
            return s.generation
        }
        guard missingCells > 0 || replacedCells > 0 else { return }
        let job = Task { [slot] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            let mine = slot.withLock { $0.generation == generation }
            guard mine else { return }
            let current = await stillCurrent()
            guard current else { return }
            await fire()
        }
        slot.withLock { s in
            if s.generation == generation { s.job = job }
            else { job.cancel() }
        }
    }

    /// 取消计时，不调用 `fire`。
    public func cancel() {
        slot.withLock { s in
            s.generation += 1
            s.job?.cancel()
            s.job = nil
        }
    }
}
