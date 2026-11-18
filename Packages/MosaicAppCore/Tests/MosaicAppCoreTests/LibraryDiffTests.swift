import Foundation
import XCTest
@testable import MosaicAppCore

final class LibraryDiffTests: XCTestCase {
    func meta(_ id: String, _ t: Double) -> AssetMetadata { AssetMetadata(id: id, modificationDate: Date(timeIntervalSince1970: t)) }

    func testAddedModifiedDeletedRetried() {
        var m = IndexManifest(featureVersion: 2)
        m.entries["keep"] = IndexEntry(modificationDate: Date(timeIntervalSince1970: 1), status: .ok, row: 0)
        m.entries["edit"] = IndexEntry(modificationDate: Date(timeIntervalSince1970: 1), status: .ok, row: 1)
        m.entries["gone"] = IndexEntry(modificationDate: Date(timeIntervalSince1970: 1), status: .ok, row: 2)
        m.entries["cloud"] = IndexEntry(modificationDate: Date(timeIntervalSince1970: 1), status: .unavailableLocal)
        m.entries["bad"] = IndexEntry(modificationDate: Date(timeIntervalSince1970: 1), status: .failed)
        let cur = [meta("keep", 1), meta("edit", 9), meta("new2", 1), meta("cloud", 1), meta("bad", 1), meta("new1", 1)]
        let d = LibraryDiff.compute(manifest: m, current: cur)
        XCTAssertEqual(d.added, ["new2", "new1"], "保留当前顺序")
        XCTAssertEqual(d.modified, ["edit"])
        XCTAssertEqual(d.deleted, ["gone"])
        XCTAssertEqual(d.retried, ["cloud", "bad"])
        let d2 = LibraryDiff.compute(manifest: m, current: cur, retryUnavailable: false)
        XCTAssertEqual(d2.retried, [])
    }

    func testDuplicateIDsCountedOnceAndNilDates() {
        var m = IndexManifest(featureVersion: 2)
        m.entries["x"] = IndexEntry(modificationDate: nil, status: .ok, row: 0)
        let d = LibraryDiff.compute(manifest: m, current: [AssetMetadata(id: "x", modificationDate: nil),
                                                           AssetMetadata(id: "y", modificationDate: nil),
                                                           AssetMetadata(id: "y", modificationDate: nil)])
        XCTAssertEqual(d.added, ["y"])
        XCTAssertTrue(d.modified.isEmpty)
        XCTAssertTrue(LibraryDiff.compute(manifest: m, current: [AssetMetadata(id: "x", modificationDate: nil)]).isEmpty)
    }

    func testRemapRows() {
        var m = IndexManifest(featureVersion: 2)
        m.entries["a"] = IndexEntry(modificationDate: nil, status: .ok, row: 0)
        m.entries["b"] = IndexEntry(modificationDate: nil, status: .ok, row: 2)
        m.entries["c"] = IndexEntry(modificationDate: nil, status: .ok, row: 1)
        m.remapRows([0, nil, 1])
        XCTAssertEqual(m.entries["a"]?.row, 0)
        XCTAssertEqual(m.entries["b"]?.row, 1)
        XCTAssertEqual(m.entries["c"]?.status, .pending)
        XCTAssertNil(m.entries["c"]?.row)
        XCTAssertEqual(m.assetIDsByRow(rowCount: 2), ["a", "b"])
    }

    func testDebouncerCoalescesAndCapsDelay() {
        var d = ChangeDebouncer(interval: 2, maxDelay: 10)
        XCTAssertNil(d.nextFireTime)
        d.noteChange(at: 0)
        d.noteChange(at: 1.5)
        XCTAssertEqual(d.nextFireTime, 3.5)
        XCTAssertFalse(d.fire(now: 3))
        XCTAssertTrue(d.fire(now: 3.5))
        XCTAssertFalse(d.hasPending)
        // 连续变化不会无限推迟
        for t in stride(from: 20.0, through: 40, by: 1) { d.noteChange(at: t) }
        XCTAssertEqual(d.nextFireTime, 30)
        XCTAssertTrue(d.fire(now: 30))
    }
}
