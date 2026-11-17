import Foundation
import XCTest
@testable import MosaicAppCore

/// T2：记住浏览位置（photo-picker-v0.1 §3；需求 v0.4 1b / 4b / §4.4 第 1–2 条）。
final class BrowsePositionStoreTests: XCTestCase {
    private func makeStore() -> (BrowsePositionStore, InMemoryPreferenceData) {
        let b = InMemoryPreferenceData()
        return (BrowsePositionStore(backend: b), b)
    }
    private let trip = BrowsePosition(album: .album(id: "A/L0/040"), anchorAssetID: "P/L0/001", anchorOffset: -12.5)

    // MARK: 存取

    func testNothingSavedReturnsNil() {
        let (s, _) = makeStore()
        for page in BrowsePage.allCases { XCTAssertNil(s.position(for: page)) }
    }

    func testSaveThenRead() {
        let (s, b) = makeStore()
        s.save(trip, for: .target)
        XCTAssertEqual(s.position(for: .target), trip)
        XCTAssertNotNil(b.data(forKey: "browse.position.target"))
        XCTAssertNil(b.data(forKey: "browse.position.source"))
    }

    func testPagesAreIndependent() {
        let (s, _) = makeStore()
        let src = BrowsePosition(album: .allPhotos, anchorAssetID: "X", anchorOffset: 0)
        s.save(trip, for: .target)
        s.save(src, for: .source)
        XCTAssertEqual(s.position(for: .target), trip)
        XCTAssertEqual(s.position(for: .source), src)
        s.clear(.source)
        XCTAssertNil(s.position(for: .source))
        XCTAssertEqual(s.position(for: .target), trip)
    }

    func testSaveOverwrites() {
        let (s, _) = makeStore()
        s.save(trip, for: .source)
        let later = BrowsePosition(album: .allPhotos, anchorAssetID: "Q", anchorOffset: 40)
        s.save(later, for: .source)
        XCTAssertEqual(s.position(for: .source), later)
    }

    func testSurvivesNewStoreInstance() {
        // 「重启后也记住」：同一个后端、新的 store 实例。
        let b = InMemoryPreferenceData()
        BrowsePositionStore(backend: b).save(trip, for: .target)
        XCTAssertEqual(BrowsePositionStore(backend: b).position(for: .target), trip)
    }

    func testClearWhenNothingSavedIsHarmless() {
        let (s, _) = makeStore()
        s.clear(.target)
        XCTAssertNil(s.position(for: .target))
    }

    func testUnstorableValuesAreNotWrittenAndKeepPrevious() {
        let (s, _) = makeStore()
        s.save(trip, for: .target)
        s.save(BrowsePosition(album: .allPhotos, anchorAssetID: "", anchorOffset: 0), for: .target)
        s.save(BrowsePosition(album: .allPhotos, anchorAssetID: "X", anchorOffset: .nan), for: .target)
        s.save(BrowsePosition(album: .allPhotos, anchorAssetID: "X", anchorOffset: .infinity), for: .target)
        s.save(BrowsePosition(album: .album(id: ""), anchorAssetID: "X", anchorOffset: 0), for: .target)
        s.save(BrowsePosition(album: .album(id: AlbumEntry.allPhotosID), anchorAssetID: "X", anchorOffset: 0), for: .target)
        XCTAssertEqual(s.position(for: .target), trip)
        s.save(BrowsePosition(album: .allPhotos, anchorAssetID: "", anchorOffset: 0), for: .source)
        XCTAssertNil(s.position(for: .source))
    }

    // MARK: 损坏 / 版本

    func testCorruptDataTreatedAsNotSaved() {
        let (s, b) = makeStore()
        for junk in [Data(), Data([0xFF, 0x00, 0x12]), Data("{".utf8), Data("[]".utf8), Data("null".utf8),
                     Data(#"{"version":1}"#.utf8),
                     Data(#"{"version":1,"album":{"bogus":{}},"anchorAssetID":"X","anchorOffset":0}"#.utf8),
                     Data(#"{"version":"1","album":{"allPhotos":{}},"anchorAssetID":"X","anchorOffset":0}"#.utf8)] {
            b.setData(junk, forKey: BrowsePage.target.preferenceKey)
            XCTAssertNil(s.position(for: .target), String(decoding: junk, as: UTF8.self))
            XCTAssertEqual(s.restore(for: .target, isSelectable: { _ in true }, indexOfAnchor: { _ in 0 }),
                           .allPhotosTop(reason: .noSavedPosition))
        }
    }

    func testValidHandWrittenJSONDecodes() {
        // 锁住存储格式：改了编码会让用户已存的位置失效，这个测试会提醒去加版本号。
        let (s, b) = makeStore()
        b.setData(Data(#"{"version":1,"album":{"album":{"id":"A"}},"anchorAssetID":"P","anchorOffset":-3}"#.utf8),
                  forKey: "browse.position.source")
        XCTAssertEqual(s.position(for: .source), BrowsePosition(album: .album(id: "A"), anchorAssetID: "P", anchorOffset: -3))
        b.setData(Data(#"{"version":1,"album":{"allPhotos":{}},"anchorAssetID":"P","anchorOffset":0}"#.utf8),
                  forKey: "browse.position.source")
        XCTAssertEqual(s.position(for: .source)?.album, .allPhotos)
    }

    func testUnknownVersionTreatedAsNotSaved() {
        let (s, _) = makeStore()
        for v in [0, -1, BrowsePosition.currentVersion + 1, 99] {
            s.save(BrowsePosition(album: .allPhotos, anchorAssetID: "X", anchorOffset: 0, version: v), for: .source)
            XCTAssertNil(s.position(for: .source), "version \(v)")
            XCTAssertEqual(s.restore(for: .source, isSelectable: { _ in true }, indexOfAnchor: { _ in 0 }),
                           .allPhotosTop(reason: .noSavedPosition))
        }
    }

    func testDecodedEmptyOrInvalidFieldsTreatedAsNotSaved() {
        let (s, b) = makeStore()
        b.setData(Data(#"{"version":1,"album":{"allPhotos":{}},"anchorAssetID":"","anchorOffset":0}"#.utf8),
                  forKey: "browse.position.source")
        XCTAssertNil(s.position(for: .source))
        b.setData(Data(#"{"version":1,"album":{"album":{"id":""}},"anchorAssetID":"P","anchorOffset":0}"#.utf8),
                  forKey: "browse.position.source")
        XCTAssertNil(s.position(for: .source))
    }

    // MARK: 恢复

    func testRestoreNothingSaved() {
        let (s, _) = makeStore()
        var askedSelectable = false, askedIndex = false
        let r = s.restore(for: .target, isSelectable: { _ in askedSelectable = true; return true },
                          indexOfAnchor: { _ in askedIndex = true; return 0 })
        XCTAssertEqual(r, .allPhotosTop(reason: .noSavedPosition))
        XCTAssertFalse(askedSelectable)
        XCTAssertFalse(askedIndex)
    }

    func testRestoreAnchorFound() {
        let (s, _) = makeStore()
        s.save(trip, for: .target)
        var seen: BrowsePosition?
        let r = s.restore(for: .target, isSelectable: { $0 == .album(id: "A/L0/040") },
                          indexOfAnchor: { seen = $0; return 1234 })
        XCTAssertEqual(r, .anchor(album: .album(id: "A/L0/040"), anchorIndex: 1234, anchorOffset: -12.5))
        XCTAssertEqual(seen, trip)
    }

    func testRestoreAlbumUnavailableDoesNotLookForAnchor() {
        let (s, _) = makeStore()
        s.save(trip, for: .target)
        var askedIndex = false
        let r = s.restore(for: .target, isSelectable: { _ in false }, indexOfAnchor: { _ in askedIndex = true; return 0 })
        XCTAssertEqual(r, .allPhotosTop(reason: .albumUnavailable))
        XCTAssertFalse(askedIndex, "相簿不可见时不该去数据源找锚点")
    }

    func testRestoreAnchorMissing() {
        let (s, _) = makeStore()
        s.save(trip, for: .target)
        XCTAssertEqual(s.restore(for: .target, isSelectable: { _ in true }, indexOfAnchor: { _ in nil }),
                       .allPhotosTop(reason: .anchorMissing))
    }

    func testRestoreNegativeIndexTreatedAsMissing() {
        let (s, _) = makeStore()
        s.save(trip, for: .target)
        XCTAssertEqual(s.restore(for: .target, isSelectable: { _ in true }, indexOfAnchor: { _ in -1 }),
                       .allPhotosTop(reason: .anchorMissing))
    }

    func testRestoreAllPhotosNeverAsksSelectable() {
        let (s, _) = makeStore()
        s.save(BrowsePosition(album: .allPhotos, anchorAssetID: "X", anchorOffset: 8), for: .source)
        var askedSelectable = false
        let r = s.restore(for: .source, isSelectable: { _ in askedSelectable = true; return false },
                          indexOfAnchor: { _ in 0 })
        XCTAssertEqual(r, .anchor(album: .allPhotos, anchorIndex: 0, anchorOffset: 8))
        XCTAssertFalse(askedSelectable, "「全部照片」始终可见")
        XCTAssertEqual(s.restore(for: .source, isSelectable: { _ in false }, indexOfAnchor: { _ in nil }),
                       .allPhotosTop(reason: .anchorMissing))
    }

    func testRestoreDoesNotClearSavedPosition() {
        // 回退只影响这次打开；存的值留着，下次（比如受限访问恢复后）还能用。
        let (s, _) = makeStore()
        s.save(trip, for: .target)
        _ = s.restore(for: .target, isSelectable: { _ in false }, indexOfAnchor: { _ in nil })
        XCTAssertEqual(s.position(for: .target), trip)
    }

    func testRestoreWithRealCatalog() {
        // 和 T1 联起来：相簿被删 / 变空 → albumUnavailable。
        let (s, _) = makeStore()
        s.save(trip, for: .target)
        let present = AlbumCatalog.sections(from: AlbumCatalogSnapshot(allPhotosCount: 10, myAlbums: [
            AlbumEntry(id: "A/L0/040", title: "旅行", kind: .userAlbum, imageCount: 3),
        ]))
        let deleted = AlbumCatalog.sections(from: AlbumCatalogSnapshot(allPhotosCount: 10))
        let ids = ["P/L0/009", "P/L0/001", "P/L0/007"]
        XCTAssertEqual(s.restore(for: .target, isSelectable: { AlbumCatalog.isSelectable($0, in: present) },
                                 indexOfAnchor: { ids.firstIndex(of: $0.anchorAssetID) }),
                       .anchor(album: .album(id: "A/L0/040"), anchorIndex: 1, anchorOffset: -12.5))
        XCTAssertEqual(s.restore(for: .target, isSelectable: { AlbumCatalog.isSelectable($0, in: deleted) },
                                 indexOfAnchor: { ids.firstIndex(of: $0.anchorAssetID) }),
                       .allPhotosTop(reason: .albumUnavailable))
    }

    func testWorksThroughProtocolExistential() {
        let store: any BrowsePositionStoring = BrowsePositionStore(backend: InMemoryPreferenceData())
        store.save(trip, for: .source)
        XCTAssertEqual(store.position(for: .source), trip)
        store.clear(.source)
        XCTAssertNil(store.position(for: .source))
    }
}
