import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

/// 产品 03:16 / 03:25（§2f 补充 8）：「照片比较少」确认框弹着时（或生成途中）所选相簿被删 → 点「继续」静默改用「全部照片」
/// 在同一次运行里生成，不提示、不算失败；全部照片也不到 200 张时不再弹第二次「照片比较少」。
@MainActor
final class AlbumDeletedDuringGenerateTests: XCTestCase {
    /// assets 张：C = a0..a29（30 张，< 200 → 先弹「照片比较少」）。
    private func harness(assets: Int) -> CoordinatorHarness {
        CoordinatorHarness(assets: assets, auth: .authorized, preferenceData: InMemoryPreferenceData(), configureLibrary: { lib in
            lib.state.update { s in
                s.albums = [AlbumInfo(id: "C", title: "猫", assetCount: 30)]
                s.albumMembers = ["C": (0..<30).map { "a\($0)" }]
            }
        })
    }

    private func start(_ h: CoordinatorHarness) async throws -> AppCoordinator {
        let c = h.coordinator
        c.start(); await c.settle()
        await waitFor(c, "扫描完成") { SourceListLogic.isScanComplete($0.indexStatus) }
        await c.refreshAlbums()
        c.setTarget(try CoordinatorHarness.target())
        c.openAlbumList()
        c.toggleAlbum("C")
        XCTAssertTrue(c.finishAlbumSelection())
        XCTAssertEqual(c.state.flow.source.selection, .album(id: "C"))
        return c
    }

    private func deleteC(_ h: CoordinatorHarness) {
        h.library.state.update { s in s.albums.removeAll { $0.id == "C" }; s.albumMembers["C"] = nil }
    }

    private func finished(_ c: AppCoordinator) async {
        await waitFor(c, "生成结束") { s in
            switch s.flow.generation.phase {
            case .failed, .result: return true
            default: return false
            }
        }
    }

    func testDeletedWhileShortagePromptOpenContinuesWithAllPhotos() async throws {
        let h = harness(assets: 300)
        let c = try await start(h)
        await c.generateTapped()
        guard case .confirmingShortage = c.state.flow.generation.phase else { return XCTFail("应先弹「照片比较少」") }
        deleteC(h)
        c.send(.shortageContinue)
        await finished(c)
        guard case .result = c.state.flow.generation.phase else {
            return XCTFail("应当用全部照片生成出结果，实际 \(c.state.flow.generation.phase)")
        }
        XCTAssertEqual(c.state.flow.source.selection, .allPhotos, "静默改用全部照片")
        XCTAssertNil(c.state.transientNotice, "不提示")
        XCTAssertNotEqual(c.state.transientNotice, .sourceAlbumUnreadable)
        XCTAssertFalse(c.state.postFilterShortageNotice, "已经提示过一次，结果页不补提示")
        c.stop()
    }

    /// 全部照片也不到 200 张：不再弹第二次「照片比较少」，直接生成。
    func testAllPhotosAlsoShortDoesNotPromptAgain() async throws {
        let h = harness(assets: 120)
        let c = try await start(h)
        await c.generateTapped()
        guard case .confirmingShortage = c.state.flow.generation.phase else { return XCTFail("应先弹「照片比较少」") }
        deleteC(h)
        c.send(.shortageContinue)
        let promptedAgain = Locked(false)
        await waitFor(c, "生成结束") { s in
            switch s.flow.generation.phase {
            case .confirmingShortage: promptedAgain.set(true); return true
            case .failed, .result: return true
            default: return false
            }
        }
        XCTAssertFalse(promptedAgain.get(), "不再弹第二次「照片比较少」")
        guard case .result = c.state.flow.generation.phase else {
            return XCTFail("直接生成，实际 \(c.state.flow.generation.phase)")
        }
        XCTAssertEqual(c.state.flow.source.selection, .allPhotos)
        XCTAssertNil(c.state.transientNotice)
        XCTAssertFalse(c.state.postFilterShortageNotice)
        c.stop()
    }

    /// 用全部照片生成后：结果记的输入是「全部照片」（「再调一调」回来不改设置，主按钮是「完成」）。
    func testResultInputsUseAllPhotos() async throws {
        let h = harness(assets: 300)
        let c = try await start(h)
        await c.generateTapped()
        deleteC(h)
        c.send(.shortageContinue)
        await finished(c)
        c.send(.backToSettings); await c.settle()
        XCTAssertEqual(c.settingsPrimaryAction, .done)
        c.stop()
    }
}
