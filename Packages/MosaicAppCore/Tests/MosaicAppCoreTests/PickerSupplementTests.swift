import Foundation
import XCTest
@testable import MosaicAppCore

/// QA 补测收进正式测试（picker-checklist v0.2 L0、H 段自动化）：OverlayDegrade 清单边界 / 单调性 / 滑块组合，
/// 以及全隐藏相簿按空处理、白名单解不出 hidden、锚点被隐藏或相簿全被隐藏时回到「全部照片」顶部。
/// 依赖 `InMemoryPreferenceData`（`PickerInterfaceTests.swift`）。
final class PickerSupplementTests: XCTestCase {
    private func k(_ s: Double) -> Double { OverlayDegrade.factor(effectiveLongSide: s) }
    private let eps = 1e-12

    /// 清单期望公式（独立写一遍，不复用实现）。
    private func expectedK(_ s: Double) -> Double {
        if s < 160 { return 0 }
        if s < 480 { return 0.5 * (s - 160) / 320 }
        if s < 1024 { return 0.5 + 0.5 * (s - 480) / 544 }
        return 1
    }

    // MARK: L0 边界值（清单 12 个点）

    func testL0BoundaryValuesFromChecklist() {
        let points: [Double] = [0, 1, 159, 160, 161, 479, 480, 481, 1023, 1024, 1025, 4096]
        for s in points {
            XCTAssertEqual(k(s), expectedK(s), accuracy: eps, "s=\(s)")
        }
        XCTAssertEqual(k(1), 0); XCTAssertEqual(k(159), 0); XCTAssertEqual(k(160), 0)
        XCTAssertEqual(k(161), 0.5 / 320, accuracy: eps)
        XCTAssertEqual(k(480), 0.5)
        XCTAssertEqual(k(481), 0.5 + 0.5 / 544, accuracy: eps)
        XCTAssertEqual(k(1024), 1); XCTAssertEqual(k(1025), 1); XCTAssertEqual(k(4096), 1)
    }

    /// 门槛处不能跳变：相邻整数 s 的差不超过最陡一段的斜率（0.5/320）。
    func testL0NoJumpAtThresholds() {
        let maxStep = 0.5 / 320 + 1e-9
        for edge in [160.0, 480, 1024] {
            for d in [-2.0, -1, 0, 1] {
                let a = k(edge + d), b = k(edge + d + 1)
                XCTAssertLessThanOrEqual(abs(b - a), maxStep, "edge=\(edge) d=\(d)")
            }
            XCTAssertEqual(k(edge.nextDown), k(edge), accuracy: 1e-9)
        }
    }

    /// 0–8192 逐个整数 s，再加 0.5 步长：单调不减、始终在 [0,1]、与期望公式一致。
    func testL0MonotonicAndInRange0to8192() {
        var prev = -1.0
        var s = 0.0
        while s <= 8192 {
            let v = k(s)
            XCTAssertGreaterThanOrEqual(v, prev, "s=\(s)")
            XCTAssertGreaterThanOrEqual(v, 0); XCTAssertLessThanOrEqual(v, 1)
            XCTAssertEqual(v, expectedK(s), accuracy: 1e-9, "s=\(s)")
            prev = v
            s += 0.5
        }
    }

    /// 实际强度 = min(滑块值, 0.3 × k)：滑块 0 / 0.1 / 0.3 × k = 0 / 0.25 / 0.5 / 0.75 / 1。
    func testL0EffectiveAlphaCombinations() {
        // s 与 k 的对应：159→0，320→0.25，480→0.5，752→0.75，1024→1
        let sForK: [(Double, Double)] = [(159, 0), (320, 0.25), (480, 0.5), (752, 0.75), (1024, 1), (4096, 1)]
        for user in [0.0, 0.1, 0.3] {
            for (s, kk) in sForK {
                XCTAssertEqual(k(s), kk, accuracy: eps)
                let a = OverlayDegrade.effectiveAlpha(user: user, effectiveLongSide: s)
                XCTAssertEqual(a, min(user, 0.3 * kk), accuracy: eps, "user=\(user) s=\(s)")
                XCTAssertLessThanOrEqual(a, user + eps, "降级不能超过用户值")
            }
        }
    }

    // MARK: H 段：AlbumCatalog

    /// 全是隐藏照片的相簿：数据源按 PhotoFetch 计数得到 0 → 按空相簿处理，不显示，也不可选中。
    func testAllHiddenAlbumTreatedAsEmpty() {
        let allHiddenUser = AlbumEntry(id: "U-hiddenOnly", title: "只有隐藏照片", kind: .userAlbum, imageCount: 0)
        let allHiddenSmart = AlbumEntry(id: "S-selfies", title: "自拍", kind: .smart(.selfPortraits), imageCount: 0)
        let allHiddenShared = AlbumEntry(id: "C-1", title: "共享", kind: .cloudShared, imageCount: 0)
        let folder = AlbumEntry(id: "F-1", title: "文件夹", kind: .folder, imageCount: 0, children: [allHiddenUser])
        let ok = AlbumEntry(id: "U-ok", title: "正常", kind: .userAlbum, imageCount: 3)
        let snap = AlbumCatalogSnapshot(allPhotosCount: 3, myAlbums: [folder, allHiddenUser, ok],
                                        smartAlbums: [allHiddenSmart], sharedAlbums: [allHiddenShared])
        let secs = AlbumCatalog.sections(from: snap)
        let all = secs.flatMap { flatten($0.entries) }.map(\.id)
        XCTAssertEqual(Set(all), [AlbumEntry.allPhotosID, "U-ok"])
        XCTAssertFalse(secs.contains { $0.kind == .mediaTypes })
        XCTAssertFalse(secs.contains { $0.kind == .shared })
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: "U-hiddenOnly"), in: secs))
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: "S-selfies"), in: secs))
        XCTAssertTrue(AlbumCatalog.isSelectable(.album(id: "U-ok"), in: secs))
    }

    /// 白名单正好 8 个，没有任何 hidden 相关成员；Codable 不能解出 allHidden 之类的值。
    func testWhitelistHasNoHiddenAndCannotDecodeHidden() {
        XCTAssertEqual(AlbumCatalog.smartAlbumWhitelist.count, 8)
        XCTAssertEqual(Set(AlbumCatalog.smartAlbumWhitelist), Set(SmartAlbumKind.allCases))
        for k in SmartAlbumKind.allCases { XCTAssertFalse(k.rawValue.lowercased().contains("hidden")) }
        for raw in ["allHidden", "hidden", "smartAlbumAllHidden"] {
            XCTAssertNil(SmartAlbumKind(rawValue: raw))
            let json = Data("\"\(raw)\"".utf8)
            XCTAssertNil(try? JSONDecoder().decode(SmartAlbumKind.self, from: json))
        }
    }

    // MARK: H 段：BrowsePositionStore

    /// 锚点照片被隐藏（数据源里找不到）→ 回到「全部照片」顶部，原因 anchorMissing，不崩溃。
    func testAnchorHiddenFallsBackToAllPhotosTop() {
        let store = BrowsePositionStore(backend: InMemoryPreferenceData())
        store.save(BrowsePosition(album: .album(id: "A/L0/040"), anchorAssetID: "P-hidden", anchorOffset: 0), for: .target)
        let r = store.restore(for: .target, isSelectable: { _ in true }, indexOfAnchor: { _ in nil })
        XCTAssertEqual(r, .allPhotosTop(reason: .anchorMissing))
        // 「全部照片」里的锚点被隐藏，也回顶部
        store.save(BrowsePosition(album: .allPhotos, anchorAssetID: "P-hidden", anchorOffset: 4), for: .source)
        XCTAssertEqual(store.restore(for: .source, isSelectable: { _ in true }, indexOfAnchor: { _ in nil }),
                       .allPhotosTop(reason: .anchorMissing))
    }

    /// 相簿里的照片全被隐藏 → 计数 0 → 不可选 → albumUnavailable → 「全部照片」顶部。用真实 AlbumCatalog 串起来。
    func testAlbumBecomesAllHiddenFallsBackToAllPhotosTop() {
        let store = BrowsePositionStore(backend: InMemoryPreferenceData())
        store.save(BrowsePosition(album: .album(id: "U-1"), anchorAssetID: "P-1", anchorOffset: 0), for: .target)
        let secs = AlbumCatalog.sections(from: AlbumCatalogSnapshot(
            allPhotosCount: 10,
            myAlbums: [AlbumEntry(id: "U-1", title: "旅行", kind: .userAlbum, imageCount: 0)]))
        var asked = false
        let r = store.restore(for: .target, isSelectable: { AlbumCatalog.isSelectable($0, in: secs) },
                              indexOfAnchor: { _ in asked = true; return 0 })
        XCTAssertEqual(r, .allPhotosTop(reason: .albumUnavailable))
        XCTAssertFalse(asked)
    }

    private func flatten(_ es: [AlbumEntry]) -> [AlbumEntry] { es.flatMap { [$0] + flatten($0.children) } }
}
