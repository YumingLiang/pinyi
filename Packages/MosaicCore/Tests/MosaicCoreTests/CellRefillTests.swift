import XCTest
@testable import MosaicCore

final class CellRefillTests: XCTestCase {
    func makeTable(_ n: Int) -> FeatureTable {
        let records = syntheticVectors(count: n, seed: 99).map { FeatureRecord(vector: $0, lightnessVariance: 0.05, aspectRatio: 1) }
        return FeatureTable(records: records)
    }

    func target() throws -> PixelBuffer {
        let w = 64, h = 48
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            bytes[o] = UInt8(x * 4); bytes[o + 1] = UInt8(y * 5); bytes[o + 2] = UInt8((x + y) * 2)
        } }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }

    func testRefillReplacesOnlyGivenCellsWithAllowedTilesIgnoringCap() throws {
        let table = makeTable(200)
        let snap = try LibrarySnapshot(table: table)
        let pipe = MosaicPipeline()
        let t = try target()
        let g = try pipe.generate(target: t, density: .coarse, snapshot: snap, seed: 5)
        let cells = Array(stride(from: 0, to: g.layout.cellCount, by: 2))
        let allowed = BitMask(count: 200, setIndices: [3, 7])
        let r = try pipe.refill(g, target: t, snapshot: snap, cells: cells, allowed: allowed)
        let set = Set(cells)
        for c in 0..<g.layout.cellCount {
            if set.contains(c) {
                XCTAssertTrue([3, 7].contains(r.assignment.tiles[c]), "格 \(c) 只能用允许的素材")
                XCTAssertTrue([.capIgnored, .neighborhoodIgnored].contains(r.assignment.levels[c]))
            } else {
                XCTAssertEqual(r.assignment.tiles[c], g.assignment.tiles[c], "其余格子不动")
                XCTAssertEqual(r.assignment.levels[c], g.assignment.levels[c])
            }
        }
        let uses = r.assignment.tiles.filter { $0 == 3 || $0 == 7 }.count
        XCTAssertGreaterThan(uses, g.assignment.statistics.resolvedCap ?? Int.max, "忽略单张上限")
        XCTAssertEqual(r.assignment.statistics.levelCounts.reduce(0, +), g.layout.cellCount)
        XCTAssertEqual(r.assignment.statistics.maxUses, Dictionary(grouping: r.assignment.tiles, by: { $0 }).values.map(\.count).max())
    }

    func testRefillWithNoAllowedThrowsNoCandidates() throws {
        let table = makeTable(50)
        let snap = try LibrarySnapshot(table: table)
        let pipe = MosaicPipeline()
        let t = try target()
        let g = try pipe.generate(target: t, density: .coarse, snapshot: snap, seed: 1)
        XCTAssertThrowsError(try pipe.refill(g, target: t, snapshot: snap, cells: [0], allowed: BitMask(count: 50))) { e in
            XCTAssertEqual(e as? MosaicError, .noCandidates)
        }
    }
}
