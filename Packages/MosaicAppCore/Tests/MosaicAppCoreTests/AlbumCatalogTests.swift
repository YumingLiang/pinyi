import Foundation
import XCTest
@testable import MosaicAppCore

/// T1：相簿列表纯逻辑（photo-picker-v0.1 §3、§5.1；需求 v0.4 §4.8 第 2 条）。
final class AlbumCatalogTests: XCTestCase {
    private func album(_ id: String, _ n: Int, title: String? = nil) -> AlbumEntry {
        AlbumEntry(id: id, title: title ?? id, kind: .userAlbum, imageCount: n)
    }
    private func folder(_ id: String, _ kids: [AlbumEntry]) -> AlbumEntry {
        AlbumEntry(id: id, title: id, kind: .folder, imageCount: 0, children: kids)
    }
    private func smart(_ k: SmartAlbumKind, _ n: Int, id: String? = nil) -> AlbumEntry {
        AlbumEntry(id: id ?? "S-\(k.rawValue)", title: k.rawValue, kind: .smart(k), imageCount: n)
    }
    private func shared(_ id: String, _ title: String, _ n: Int) -> AlbumEntry {
        AlbumEntry(id: id, title: title, kind: .cloudShared, imageCount: n)
    }
    private func ids(_ s: AlbumSection?) -> [String] { s?.entries.map(\.id) ?? [] }
    private func section(_ k: AlbumSectionKind, _ secs: [AlbumSection]) -> AlbumSection? { secs.first { $0.kind == k } }

    // MARK: 节

    func testEmptySnapshotStillHasAllPhotosSection() {
        let secs = AlbumCatalog.sections(from: AlbumCatalogSnapshot(allPhotosCount: 0))
        XCTAssertEqual(secs.map(\.kind), [.allPhotos])
        XCTAssertEqual(secs[0].entries, [.allPhotos(imageCount: 0)])
    }

    func testNegativeAllPhotosCountClampedToZero() {
        let secs = AlbumCatalog.sections(from: AlbumCatalogSnapshot(allPhotosCount: -5))
        XCTAssertEqual(secs[0].entries.first?.imageCount, 0)
    }

    func testSectionOrderIsAllMineMediaShared() {
        // 快照里故意乱序给，输出顺序固定。
        let snap = AlbumCatalogSnapshot(allPhotosCount: 50_000,
                                        myAlbums: [album("A", 3)],
                                        smartAlbums: [smart(.screenshots, 2)],
                                        sharedAlbums: [shared("C", "家庭", 9)])
        let secs = AlbumCatalog.sections(from: snap)
        XCTAssertEqual(secs.map(\.kind), [.allPhotos, .myAlbums, .mediaTypes, .shared])
        XCTAssertEqual(secs[0].entries, [.allPhotos(imageCount: 50_000)])
    }

    func testEmptySectionsOmitted() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 10, myAlbums: [album("A", 0)],
                                        smartAlbums: [smart(.favorites, 0)], sharedAlbums: [shared("C", "x", 0)])
        XCTAssertEqual(AlbumCatalog.sections(from: snap).map(\.kind), [.allPhotos])
    }

    // MARK: 我的相簿

    func testMyAlbumsKeepPhotoKitOrderAndHideEmpty() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, myAlbums: [
            album("Z", 1, title: "最后创建"), album("E", 0), album("A", 5, title: "旅行"), album("M", 2),
        ])
        XCTAssertEqual(ids(section(.myAlbums, AlbumCatalog.sections(from: snap))), ["Z", "A", "M"])
    }

    func testFolderWithOnlyEmptyAlbumsHidden() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, myAlbums: [
            folder("F1", [album("e1", 0), album("e2", 0)]),
            album("A", 1),
        ])
        XCTAssertEqual(ids(section(.myAlbums, AlbumCatalog.sections(from: snap))), ["A"])
    }

    func testEmptyFolderHidden() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, myAlbums: [folder("F", [])])
        XCTAssertNil(section(.myAlbums, AlbumCatalog.sections(from: snap)))
    }

    func testNestedFoldersPrunedRecursively() {
        // F → [G → [H → [空]], 空, B(3), K → [空]]  ⇒  F → [B]
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, myAlbums: [
            folder("F", [
                folder("G", [folder("H", [album("h", 0)])]),
                album("e", 0),
                album("B", 3),
                folder("K", [album("k", 0)]),
            ]),
        ])
        let mine = section(.myAlbums, AlbumCatalog.sections(from: snap))
        XCTAssertEqual(ids(mine), ["F"])
        XCTAssertEqual(mine?.entries.first?.children.map(\.id), ["B"])
    }

    func testFolderChildrenKeepOrder() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, myAlbums: [
            folder("F", [album("c", 1), album("a", 0), album("b", 1), folder("G", [album("g", 1)])]),
        ])
        let f = section(.myAlbums, AlbumCatalog.sections(from: snap))?.entries.first
        XCTAssertEqual(f?.children.map(\.id), ["c", "b", "G"])
        XCTAssertEqual(f?.children.last?.children.map(\.id), ["g"])
    }

    func testMyAlbumsDropForeignKinds() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, myAlbums: [
            smart(.favorites, 3), shared("C", "共享", 3), .allPhotos(imageCount: 9), album("A", 1),
            folder("F", [smart(.selfPortraits, 2)]),
        ])
        XCTAssertEqual(ids(section(.myAlbums, AlbumCatalog.sections(from: snap))), ["A"])
    }

    // MARK: 智能相簿

    func testSmartAlbumsInWhitelistOrder() {
        let shuffled: [SmartAlbumKind] = [.bursts, .favorites, .screenshots, .depthEffect, .livePhotos,
                                          .recentlyAdded, .panoramas, .selfPortraits]
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, smartAlbums: shuffled.map { smart($0, 1) })
        let media = section(.mediaTypes, AlbumCatalog.sections(from: snap))
        XCTAssertEqual(media?.entries.map(\.kind), AlbumCatalog.smartAlbumWhitelist.map { AlbumKind.smart($0) })
    }

    func testEmptySmartAlbumsHidden() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, smartAlbums: [
            smart(.favorites, 0), smart(.selfPortraits, 4), smart(.bursts, 0),
        ])
        XCTAssertEqual(ids(section(.mediaTypes, AlbumCatalog.sections(from: snap))), ["S-selfPortraits"])
    }

    func testDuplicateSmartKindKeepsFirst() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, smartAlbums: [
            smart(.favorites, 3, id: "first"), smart(.favorites, 7, id: "second"),
        ])
        XCTAssertEqual(ids(section(.mediaTypes, AlbumCatalog.sections(from: snap))), ["first"])
    }

    func testDuplicateSmartKindFirstEmptyDoesNotFallBackToSecond() {
        // 「每种只留第一个」：第一个是空的就整种不显示，不去用第二个（数据源本不该给两个）。
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, smartAlbums: [
            smart(.favorites, 0, id: "first"), smart(.favorites, 7, id: "second"),
        ])
        XCTAssertNil(section(.mediaTypes, AlbumCatalog.sections(from: snap)))
    }

    func testSmartSectionDropsNonSmartKinds() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, smartAlbums: [
            album("A", 3), shared("C", "x", 3), folder("F", [album("a", 1)]), smart(.panoramas, 1),
        ])
        XCTAssertEqual(ids(section(.mediaTypes, AlbumCatalog.sections(from: snap))), ["S-panoramas"])
    }

    func testNoHiddenAlbumAnywhere() {
        // 已隐藏相簿在类型上表达不了；名字叫「已隐藏」的用户相簿也只是普通相簿，不在媒体类型里。
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1,
                                        smartAlbums: SmartAlbumKind.allCases.map { smart($0, 1) })
        let secs = AlbumCatalog.sections(from: snap)
        let media = section(.mediaTypes, secs)?.entries ?? []
        XCTAssertEqual(media.count, 8)
        for e in media {
            guard case .smart(let k) = e.kind else { return XCTFail("媒体类型里只能是智能相簿") }
            XCTAssertFalse(k.rawValue.lowercased().contains("hidden"))
        }
    }

    // MARK: 共享相簿

    func testSharedAlbumsSortedByTitleThenID() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, sharedAlbums: [
            shared("c2", "Trip 10", 1), shared("c1", "Trip 2", 1), shared("c4", "家庭", 1),
            shared("c3", "family", 1), shared("b", "同名", 1), shared("a", "同名", 1),
        ])
        let order = ids(section(.shared, AlbumCatalog.sections(from: snap)))
        // localizedStandardCompare：数字按数值比（Trip 2 < Trip 10），不区分大小写；同名按 id。
        XCTAssertLessThan(order.firstIndex(of: "c1")!, order.firstIndex(of: "c2")!)
        XCTAssertLessThan(order.firstIndex(of: "a")!, order.firstIndex(of: "b")!)
        XCTAssertEqual(order.count, 6)
        // 和自己再排一次结果一致（纯函数、稳定）。
        XCTAssertEqual(order, ids(section(.shared, AlbumCatalog.sections(from: snap))))
    }

    func testSharedAlbumsHideEmptyAndDropForeignKindsAndDuplicates() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, sharedAlbums: [
            shared("x", "空", 0), album("A", 3), smart(.favorites, 2), shared("y", "有", 2), shared("y", "有（重复）", 5),
        ])
        let sec = section(.shared, AlbumCatalog.sections(from: snap))
        XCTAssertEqual(ids(sec), ["y"])
        XCTAssertEqual(sec?.entries.first?.imageCount, 2)
    }

    func testSharedPhotosAreSeparateFromMyAlbums() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 1, myAlbums: [album("A", 1)], sharedAlbums: [shared("C", "共享", 1)])
        let secs = AlbumCatalog.sections(from: snap)
        XCTAssertEqual(ids(section(.myAlbums, secs)), ["A"])
        XCTAssertEqual(ids(section(.shared, secs)), ["C"])
    }

    func testLeafChildrenStripped() {
        var bad = album("A", 1)
        bad.children = [album("ghost", 1)]
        let secs = AlbumCatalog.sections(from: AlbumCatalogSnapshot(allPhotosCount: 1, myAlbums: [bad]))
        XCTAssertEqual(section(.myAlbums, secs)?.entries.first?.children, [])
        XCTAssertNil(AlbumCatalog.entry(id: "ghost", in: secs))
    }

    func testSectionsDeterministic() {
        let snap = AlbumCatalogSnapshot(allPhotosCount: 3, myAlbums: [folder("F", [album("a", 1)]), album("b", 2)],
                                        smartAlbums: [smart(.bursts, 1), smart(.favorites, 1)],
                                        sharedAlbums: [shared("s2", "B", 1), shared("s1", "A", 1)])
        XCTAssertEqual(AlbumCatalog.sections(from: snap), AlbumCatalog.sections(from: snap))
    }

    // MARK: entry / isSelectable

    private var sample: [AlbumSection] {
        AlbumCatalog.sections(from: AlbumCatalogSnapshot(
            allPhotosCount: 100,
            myAlbums: [folder("F", [folder("G", [album("deep", 4)]), album("empty", 0)]), album("A", 2)],
            smartAlbums: [smart(.favorites, 5), smart(.bursts, 0)],
            sharedAlbums: [shared("C", "共享", 3)]))
    }

    func testEntryFindsAcrossSectionsAndFolders() {
        let s = sample
        XCTAssertEqual(AlbumCatalog.entry(id: AlbumEntry.allPhotosID, in: s)?.kind, .allPhotos)
        XCTAssertEqual(AlbumCatalog.entry(id: "A", in: s)?.imageCount, 2)
        XCTAssertEqual(AlbumCatalog.entry(id: "deep", in: s)?.imageCount, 4)
        XCTAssertEqual(AlbumCatalog.entry(id: "G", in: s)?.kind, .folder)
        XCTAssertEqual(AlbumCatalog.entry(id: "S-favorites", in: s)?.kind, .smart(.favorites))
        XCTAssertEqual(AlbumCatalog.entry(id: "C", in: s)?.kind, .cloudShared)
        XCTAssertNil(AlbumCatalog.entry(id: "empty", in: s), "空相簿已被去掉")
        XCTAssertNil(AlbumCatalog.entry(id: "S-bursts", in: s))
        XCTAssertNil(AlbumCatalog.entry(id: "nope", in: s))
        XCTAssertNil(AlbumCatalog.entry(id: "A", in: []))
    }

    func testIsSelectable() {
        let s = sample
        XCTAssertTrue(AlbumCatalog.isSelectable(.allPhotos, in: s))
        XCTAssertTrue(AlbumCatalog.isSelectable(.allPhotos, in: []), "「全部照片」始终可见")
        XCTAssertTrue(AlbumCatalog.isSelectable(.album(id: "A"), in: s))
        XCTAssertTrue(AlbumCatalog.isSelectable(.album(id: "deep"), in: s), "文件夹子树里的相簿")
        XCTAssertTrue(AlbumCatalog.isSelectable(.album(id: "S-favorites"), in: s))
        XCTAssertTrue(AlbumCatalog.isSelectable(.album(id: "C"), in: s))
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: "F"), in: s), "文件夹不能选")
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: "G"), in: s))
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: "empty"), in: s), "空相簿不可见")
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: "S-bursts"), in: s))
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: "gone"), in: s), "已删除")
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: AlbumEntry.allPhotosID), in: s),
                       "allPhotosID 不是相簿 id，要用 .allPhotos")
    }

    func testIsSelectableOnUnfilteredSectionsStillRejectsEmpty() {
        // 调用方直接拼节（没走 sections(from:)）时，空相簿也不算可见。
        let raw = [AlbumSection(kind: .myAlbums, entries: [album("E", 0)])]
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: "E"), in: raw))
    }

    func testRestrictedAccessAlbumBecomesUnavailable() {
        // 受限访问：数据源只数已允许的照片，相簿变 0 张 → 列表里消失 → 不可选（需求 v0.4 §1 验收 2）。
        let full = AlbumCatalog.sections(from: AlbumCatalogSnapshot(allPhotosCount: 9, myAlbums: [album("T", 30, title: "旅行")]))
        let limited = AlbumCatalog.sections(from: AlbumCatalogSnapshot(allPhotosCount: 2, myAlbums: [album("T", 0, title: "旅行")]))
        XCTAssertTrue(AlbumCatalog.isSelectable(.album(id: "T"), in: full))
        XCTAssertFalse(AlbumCatalog.isSelectable(.album(id: "T"), in: limited))
    }
}
