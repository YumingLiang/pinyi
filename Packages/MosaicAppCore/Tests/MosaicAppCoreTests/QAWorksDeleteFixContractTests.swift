import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

// 需要先打上 suggested-fix-e8355ae.diff（WorksController.deleteConfirmed(_ id:)）才能编译。
// 模拟真机 UI 顺序：弹窗按钮 action 只建 Task，SwiftUI 收起弹窗时 Binding.set(false) → deleteCancelled() 先跑。
@MainActor
final class QAWorksDeleteFixContractTests: XCTestCase {
    private func harness() -> (FileWorksStore, WorksController, URL) {
        let dir = makeTempDir().appendingPathComponent("Works")
        let images = FakeWorkImages()
        let store = FileWorksStore(directory: dir, images: images, now: FakeWallClock().provider)
        return (store, WorksController(store: store, existence: FakeExistence(), images: images), dir)
    }

    private func save(_ store: FileWorksStore, _ ids: [String]) async throws -> WorkID {
        try await store.save(WorkDraft(layout: sampleLayout(ids), target: try smallTarget(), overlayAlpha: 0.15,
                                       tier: "uhd", seed: 7, origin: .savedManually)).summary.id
    }

    func testUIOrderDeleteWithExplicitIDDeletes() async throws {
        let (store, c, dir) = harness()
        let a = try await save(store, ["a", "b", "c"])
        await c.start()
        await c.open(a)
        c.deleteTapped(a)
        let action = Task { @MainActor in await c.deleteConfirmed(a) }   // WorksViews:150 修复后
        c.deleteCancelled()                                               // 弹窗收起
        await action.value
        XCTAssertEqual(c.state.count, 0)
        XCTAssertNil(c.state.opened)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(a.directoryName).path))
        let relaunched = WorksController(store: FileWorksStore(directory: dir, images: FakeWorkImages()), existence: FakeExistence(), images: FakeWorkImages())
        await relaunched.start()
        XCTAssertEqual(relaunched.state.count, 0, "重启后仍不在")
    }

    func testInterleavedDeletesWithExplicitIDs() async throws {
        let (store, c, _) = harness()
        let a = try await save(store, ["a", "b", "c"])
        let b = try await save(store, ["d", "e", "f"])
        await c.start()
        c.deleteTapped(a); let t1 = Task { @MainActor in await c.deleteConfirmed(a) }
        c.deleteTapped(b); let t2 = Task { @MainActor in await c.deleteConfirmed(b) }
        await t1.value; await t2.value
        XCTAssertEqual(c.state.count, 0)
        XCTAssertNil(c.state.pendingDelete)
    }

    func testCancelStillDoesNothing() async throws {
        let (store, c, _) = harness()
        let a = try await save(store, ["a", "b", "c"])
        await c.start()
        c.deleteTapped(a); c.deleteCancelled()
        await c.deleteConfirmed()   // 旧入口：无待确认 → 不删
        XCTAssertEqual(c.state.count, 1)
    }
}
