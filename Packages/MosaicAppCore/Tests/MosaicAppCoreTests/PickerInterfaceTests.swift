import Foundation
import XCTest
@testable import MosaicAppCore

/// T0：选图页接口的基本行为（类型可构造、Codable 往返、白名单不含已隐藏）。逻辑由 T1 / T2 / T4 各自补测试。
final class PickerInterfaceTests: XCTestCase {
    // MARK: AlbumCatalog

    func testSmartAlbumWhitelistIsExactlyEightAndHasNoHidden() {
        XCTAssertEqual(AlbumCatalog.smartAlbumWhitelist,
                       [.favorites, .recentlyAdded, .selfPortraits, .depthEffect, .livePhotos, .panoramas, .screenshots, .bursts])
        for k in SmartAlbumKind.allCases {
            XCTAssertFalse(k.rawValue.lowercased().contains("hidden"), k.rawValue)
        }
        XCTAssertNil(SmartAlbumKind(rawValue: "allHidden"))
        XCTAssertNil(SmartAlbumKind(rawValue: "hidden"))
    }

    func testAlbumEntryConstructionAndSelection() {
        let all = AlbumEntry.allPhotos(imageCount: 50_000)
        XCTAssertEqual(all.id, AlbumEntry.allPhotosID)
        XCTAssertEqual(all.kind, .allPhotos)
        XCTAssertEqual(all.selection, .allPhotos)

        let trip = AlbumEntry(id: "A/L0/040", title: "旅行", kind: .userAlbum, imageCount: 120)
        XCTAssertEqual(trip.selection, .album(id: "A/L0/040"))
        XCTAssertFalse(trip.isFolder)

        let folder = AlbumEntry(id: "F/L0/020", title: "2026", kind: .folder, imageCount: 0, children: [trip])
        XCTAssertTrue(folder.isFolder)
        XCTAssertNil(folder.selection, "文件夹不能被选中")
        XCTAssertEqual(folder.children.first, trip)

        XCTAssertEqual(AlbumEntry(id: "S", title: "自拍", kind: .smart(.selfPortraits), imageCount: 3).selection, .album(id: "S"))
        XCTAssertEqual(AlbumEntry(id: "C", title: "家庭", kind: .cloudShared, imageCount: 9).selection, .album(id: "C"))
    }

    func testAlbumEntryCodableRoundTrip() throws {
        let tree = AlbumEntry(id: "F", title: "文件夹", kind: .folder, imageCount: 0, children: [
            AlbumEntry(id: "A", title: "旅行", kind: .userAlbum, imageCount: 1),
            AlbumEntry(id: "S", title: "实况", kind: .smart(.livePhotos), imageCount: 2),
            AlbumEntry(id: "C", title: "共享", kind: .cloudShared, imageCount: 3),
        ])
        let back = try JSONDecoder().decode(AlbumEntry.self, from: JSONEncoder().encode(tree))
        XCTAssertEqual(back, tree)
    }

    func testSnapshotAndSectionConstruction() {
        let s = AlbumCatalogSnapshot(allPhotosCount: 10,
                                     myAlbums: [AlbumEntry(id: "A", title: "旅行", kind: .userAlbum, imageCount: 1)],
                                     smartAlbums: [AlbumEntry(id: "S", title: "截屏", kind: .smart(.screenshots), imageCount: 0)])
        XCTAssertEqual(s.sharedAlbums, [])
        let sec = AlbumSection(kind: .myAlbums, entries: s.myAlbums)
        XCTAssertEqual(sec.id, .myAlbums)
    }

    func testFakeCatalogProviderConforms() async {
        struct Fake: AlbumCatalogProviding {
            func catalogSnapshot() async -> AlbumCatalogSnapshot { AlbumCatalogSnapshot(allPhotosCount: 3) }
        }
        let p: any AlbumCatalogProviding = Fake()
        let snap = await p.catalogSnapshot()
        XCTAssertEqual(snap.allPhotosCount, 3)
    }

    // MARK: BrowsePosition

    func testBrowsePageKeysAreDistinctAndStable() {
        XCTAssertEqual(BrowsePage.source.preferenceKey, "browse.position.source")
        XCTAssertEqual(BrowsePage.target.preferenceKey, "browse.position.target")
    }

    func testBrowsePositionCodableRoundTrip() throws {
        for p in [
            BrowsePosition(album: .album(id: "A/L0/040"), anchorAssetID: "X/L0/001", anchorOffset: -12.5),
            BrowsePosition(album: .allPhotos, anchorAssetID: "Y/L0/001", anchorOffset: 0),
        ] {
            let data = try JSONEncoder().encode(p)
            let back = try JSONDecoder().decode(BrowsePosition.self, from: data)
            XCTAssertEqual(back, p)
            XCTAssertEqual(back.version, BrowsePosition.currentVersion)
        }
    }

    func testRestoreResultAndReasonValues() throws {
        let a = BrowseRestoreResult.anchor(album: .album(id: "A"), anchorIndex: 30, anchorOffset: 8)
        XCTAssertNotEqual(a, .allPhotosTop(reason: .anchorMissing))
        XCTAssertEqual(Set([BrowseFallbackReason.noSavedPosition, .albumUnavailable, .anchorMissing]).count, 3)
        let r = try JSONDecoder().decode(BrowseFallbackReason.self, from: JSONEncoder().encode(BrowseFallbackReason.albumUnavailable))
        XCTAssertEqual(r, .albumUnavailable)
    }

    func testPreferenceDataStoreFakeAndStoreConstruction() {
        let backend = InMemoryPreferenceData()
        backend.setData(Data([1, 2]), forKey: "k")
        XCTAssertEqual(backend.data(forKey: "k"), Data([1, 2]))
        backend.setData(nil, forKey: "k")
        XCTAssertNil(backend.data(forKey: "k"))
        let store: any BrowsePositionStoring = BrowsePositionStore(backend: backend)
        XCTAssertNotNil(store)
    }

    // MARK: Grid

    @MainActor
    func testFakeGridDataSourceAndLoaderConform() {
        let ds = FakeGridDataSource(ids: ["n2", "n1", "n0"], live: ["n1"])
        XCTAssertEqual(ds.count, 3)
        XCTAssertEqual(ds.assetID(at: 0), "n2")
        XCTAssertTrue(ds.isLivePhoto(at: 1))
        XCTAssertEqual(ds.index(ofAssetID: "n0"), 2)
        XCTAssertNil(ds.index(ofAssetID: "gone"))

        var got: [AssetGridChange] = []
        ds.setChangeHandler { got.append($0) }
        let change = AssetGridChange.incremental(removed: IndexSet([0]), inserted: IndexSet(), changed: IndexSet([1]),
                                                 moves: [AssetGridMove(from: 2, to: 0)])
        ds.emit(change)
        ds.emit(.reload)
        XCTAssertEqual(got, [change, .reload])

        let loader: any GridThumbnailLoading<String> = FakeGridLoader()
        var delivered: [GridThumbnail<String>] = []
        let id = loader.requestThumbnail(assetID: "n2", targetPixelSize: 300) { delivered.append($0) }
        XCTAssertEqual(id, GridThumbnailRequestID(rawValue: 1))
        XCTAssertEqual(delivered.map(\.image), ["n2@300"])
        XCTAssertEqual(delivered.map(\.isDegraded), [false])
    }

    func testCacheWindowTypes() {
        let w = ThumbnailCacheWindow()
        XCTAssertEqual(w.cached, 0..<0)
        XCTAssertEqual(CacheWindowUpdate(), CacheWindowUpdate(start: [], stop: []))
    }
}

// MARK: - 测试替身（T2 / T4 可直接复用）

final class InMemoryPreferenceData: PreferenceDataStore, Sendable {
    let values = Locked<[String: Data]>([:])
    func data(forKey key: String) -> Data? { values.get()[key] }
    func setData(_ data: Data?, forKey key: String) { values.update { $0[key] = data } }
}

@MainActor
final class FakeGridDataSource: AssetGridDataSource {
    var album: SourceSelection = .allPhotos
    var ids: [String]
    var live: Set<String>
    private var handler: (@MainActor (AssetGridChange) -> Void)?

    init(ids: [String], live: Set<String> = []) {
        self.ids = ids
        self.live = live
    }

    var count: Int { ids.count }
    func assetID(at index: Int) -> String { ids[index] }
    func isLivePhoto(at index: Int) -> Bool { live.contains(ids[index]) }
    func index(ofAssetID assetID: String) -> Int? { ids.firstIndex(of: assetID) }
    func setChangeHandler(_ handler: (@MainActor (AssetGridChange) -> Void)?) { self.handler = handler }
    func emit(_ c: AssetGridChange) { handler?(c) }
}

@MainActor
final class FakeGridLoader: GridThumbnailLoading {
    private var next: Int32 = 0
    func requestThumbnail(assetID: String, targetPixelSize: Int,
                          handler: @escaping @MainActor (GridThumbnail<String>) -> Void) -> GridThumbnailRequestID? {
        next += 1
        handler(GridThumbnail(image: "\(assetID)@\(targetPixelSize)", isDegraded: false))
        return GridThumbnailRequestID(rawValue: next)
    }
    func cancel(_ id: GridThumbnailRequestID) {}
    func startCaching(assetIDs: [String], targetPixelSize: Int) {}
    func stopCaching(assetIDs: [String], targetPixelSize: Int) {}
    func stopCachingAll() {}
}
