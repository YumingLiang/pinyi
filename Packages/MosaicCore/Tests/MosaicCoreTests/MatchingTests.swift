import XCTest
@testable import MosaicCore

final class MatchingTests: XCTestCase {
    func testSquaredEuclideanDistance() {
        XCTAssertEqual(squaredEuclideanDistance([0, 0, 0], [1, 2, 2]), 9)
        XCTAssertEqual(squaredEuclideanDistance([1, 1], [1, 1]), 0)
        XCTAssertEqual(squaredEuclideanDistance([], []), 0)
    }

    func testBitMask() {
        var m = BitMask(count: 130)
        XCTAssertEqual(m.setCount, 0)
        m[0] = true; m[64] = true; m[129] = true
        XCTAssertTrue(m[64])
        XCTAssertFalse(m[63])
        XCTAssertEqual(m.setCount, 3)
        m[64] = false
        XCTAssertEqual(m.setCount, 2)
        XCTAssertEqual(BitMask(count: 130, allSet: true).setCount, 130)
        XCTAssertEqual(BitMask(count: 64, allSet: true).setCount, 64)
        XCTAssertEqual(BitMask(count: 0, allSet: true).setCount, 0)
        let a = BitMask(count: 10, setIndices: [1, 2, 3])
        let b = BitMask(count: 10, setIndices: [3, 4])
        XCTAssertEqual(a.union(b).setCount, 4)
        XCTAssertEqual(a.intersection(b), BitMask(count: 10, setIndices: [3]))
    }

    /// 与朴素排序对拍：随机数据、不同 k、串行/并行、不同分块参数。
    func testTopKMatchesNaiveReference() throws {
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 3000, seed: 11))
        let queries = FeatureMatrix(vectors: syntheticVectors(count: 37, seed: 12))
        let kernels: [ScalarSIMDKernel] = [
            ScalarSIMDKernel(parallel: false),
            ScalarSIMDKernel(parallel: true),
            ScalarSIMDKernel(parallel: true, queryBlockSize: 3, candidateTileSize: 97),
        ]
        for k in [1, 5, 32, 128] {
            for kernel in kernels {
                let r = try kernel.topK(queries: queries, candidates: lib, k: k)
                XCTAssertEqual(r.k, k)
                XCTAssertEqual(r.queryCount, 37)
                for q in 0..<37 {
                    let expected = naiveTopK(query: queries.row(q), library: lib, k: k)
                    let got = r.neighbors(forQuery: q)
                    XCTAssertEqual(got.map(\.index), expected.map(\.index), "k=\(k) q=\(q)")
                    for (g, e) in zip(got, expected) {
                        XCTAssertEqual(g.distance, e.distance, accuracy: max(1e-6, e.distance * 1e-4))
                    }
                }
            }
        }
    }

    func testTopKIsSortedAndParallelEqualsSerial() throws {
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 5000, seed: 21))
        let queries = FeatureMatrix(vectors: syntheticVectors(count: 200, seed: 22))
        let a = try ScalarSIMDKernel(parallel: false).topK(queries: queries, candidates: lib, k: 32)
        let b = try ScalarSIMDKernel(parallel: true, queryBlockSize: 7, candidateTileSize: 333).topK(queries: queries, candidates: lib, k: 32)
        XCTAssertEqual(a, b)
        for q in 0..<200 {
            let d = Array(a.distances(forQuery: q))
            XCTAssertEqual(d, d.sorted())
        }
    }

    /// 距离相同的候选按下标升序（跨内核一致性的前提）。
    func testTiesBrokenByIndex() throws {
        let same = FeatureVector(uniform: SIMD3(0.5, 0, 0))
        let far = FeatureVector(uniform: SIMD3(0.9, 0, 0))
        let lib = FeatureMatrix(vectors: [far, same, far, same, same, far])
        let r = try ScalarSIMDKernel(candidateTileSize: 2).topK(queries: FeatureMatrix(vectors: [same]), candidates: lib, k: 4)
        XCTAssertEqual(r.indices(forQuery: 0).map { Int($0) }, [1, 3, 4, 0])
    }

    func testExactMatchIsFirst() throws {
        let vs = syntheticVectors(count: 1000, seed: 31)
        let lib = FeatureMatrix(vectors: vs)
        let r = try ScalarSIMDKernel().topK(queries: FeatureMatrix(vectors: [vs[421], vs[7]]), candidates: lib, k: 3)
        XCTAssertEqual(r.indices(forQuery: 0).first, 421)
        XCTAssertEqual(r.distances(forQuery: 0).first, 0)
        XCTAssertEqual(r.indices(forQuery: 1).first, 7)
    }

    func testMaskRestrictsCandidatesAndClampsK() throws {
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 500, seed: 41))
        let queries = FeatureMatrix(vectors: syntheticVectors(count: 10, seed: 42))
        let allowed = [3, 77, 150, 151, 499]
        let mask = BitMask(count: 500, setIndices: allowed)
        let r = try ScalarSIMDKernel().topK(queries: queries, candidates: lib, k: 32, mask: mask)
        XCTAssertEqual(r.k, 5) // 只有 5 个可用
        for q in 0..<10 {
            XCTAssertEqual(Set(r.indices(forQuery: q).map { Int($0) }), Set(allowed))
            XCTAssertEqual(r.neighbors(forQuery: q).map(\.index), naiveTopK(query: queries.row(q), library: lib, k: 5, mask: mask).map(\.index))
        }
    }

    func testKLargerThanLibrary() throws {
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 3, seed: 51))
        let r = try ScalarSIMDKernel().topK(queries: FeatureMatrix(vectors: syntheticVectors(count: 2, seed: 52)), candidates: lib, k: 32)
        XCTAssertEqual(r.k, 3)
        XCTAssertEqual(Set(r.indices(forQuery: 1)), [0, 1, 2])
    }

    func testEmptyInputs() throws {
        let kernel = ScalarSIMDKernel()
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 10, seed: 61))
        let none = FeatureMatrix(vectors: [])
        let r1 = try kernel.topK(queries: none, candidates: lib, k: 5)
        XCTAssertEqual(r1.queryCount, 0)
        XCTAssertEqual(r1.indices, [])
        let r2 = try kernel.topK(queries: lib, candidates: none, k: 5)
        XCTAssertEqual(r2.k, 0)
        XCTAssertEqual(r2.queryCount, 10)
        let r3 = try kernel.topK(queries: lib, candidates: lib, k: 0)
        XCTAssertEqual(r3.k, 0)
        let r4 = try kernel.topK(queries: lib, candidates: lib, k: 5, mask: BitMask(count: 10))
        XCTAssertEqual(r4.k, 0)
    }

    func testValidationErrors() throws {
        let kernel = ScalarSIMDKernel()
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 10, seed: 71))
        let q3 = try FeatureMatrix(dimension: 3, rows: [[0, 0, 0]])
        XCTAssertThrowsError(try kernel.topK(queries: q3, candidates: lib, k: 1)) {
            XCTAssertEqual($0 as? MosaicError, .dimensionMismatch(expected: 12, actual: 3))
        }
        XCTAssertThrowsError(try kernel.topK(queries: lib, candidates: lib, k: 1, mask: BitMask(count: 9)))
        XCTAssertThrowsError(try kernel.topK(queries: lib, candidates: lib, k: -1))
    }

    /// 非 12 维（例如方案中的 3×3 = 27 维备选）同样可用。
    func testArbitraryDimension() throws {
        var rng = SplitMix64(seed: 81)
        let rows = (0..<200).map { _ in (0..<27).map { _ in rng.nextUnitFloat() } }
        let lib = try FeatureMatrix(dimension: 27, rows: rows)
        let r = try ScalarSIMDKernel().topK(queries: lib.subset(17), candidates: lib, k: 4)
        XCTAssertEqual(r.indices(forQuery: 0).first, 17)
        XCTAssertEqual(r.neighbors(forQuery: 0).map(\.index), naiveTopK(query: rows[17], library: lib, k: 4).map(\.index))
    }
}
