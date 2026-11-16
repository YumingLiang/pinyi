import XCTest
@testable import MosaicCore

final class RandomTests: XCTestCase {
    /// 参考值：Vigna splitmix64.c，种子 1234567（Rosetta Code 同值）。
    func testSplitMix64ReferenceVector() {
        var g = SplitMix64(seed: 1_234_567)
        let expected: [UInt64] = [
            6_457_827_717_110_365_317, 3_203_168_211_198_807_973, 9_817_491_932_198_370_423,
            4_593_380_528_125_082_431, 16_408_922_859_458_223_821,
        ]
        XCTAssertEqual((0..<5).map { _ in g.next() }, expected)
    }

    /// 参考值：xoshiro256** 参考实现，状态 {1, 2, 3, 4}（与 rand_xoshiro 测试向量一致）。
    func testXoshiro256StarStarReferenceVector() {
        var g = Xoshiro256StarStar(state: (1, 2, 3, 4))
        let expected: [UInt64] = [
            11520, 0, 1_509_978_240, 1_215_971_899_390_074_240, 1_216_172_134_540_287_360,
            607_988_272_756_665_600, 16_172_922_978_634_559_625, 8_476_171_486_693_032_832,
            10_595_114_339_597_558_777, 2_904_607_092_377_533_576,
        ]
        XCTAssertEqual((0..<10).map { _ in g.next() }, expected)
    }

    /// 种子经 SplitMix64 展开（与 Python 独立实现对拍）。
    func testXoshiroSeedExpansion() {
        var g = Xoshiro256StarStar(seed: 42)
        XCTAssertEqual([g.next(), g.next(), g.next()],
                       [1_546_998_764_402_558_742, 6_990_951_692_964_543_102, 12_544_586_762_248_559_009])
    }

    func testBoundedIsInRangeAndRoughlyUniform() {
        var g = Xoshiro256StarStar(seed: 9)
        var buckets = [Int](repeating: 0, count: 7)
        for _ in 0..<70_000 {
            let v = g.nextBounded(7)
            XCTAssertLessThan(v, 7)
            buckets[Int(v)] += 1
        }
        for b in buckets { XCTAssertEqual(Double(b), 10_000, accuracy: 600) }
        XCTAssertEqual(g.nextBounded(1), 0)
    }

    func testPermutationIsReproducibleAndValid() {
        var a = Xoshiro256StarStar(seed: 123)
        var b = Xoshiro256StarStar(seed: 123)
        var c = Xoshiro256StarStar(seed: 124)
        let pa = a.permutation(count: 1000)
        XCTAssertEqual(pa, b.permutation(count: 1000))
        XCTAssertNotEqual(pa, c.permutation(count: 1000))
        XCTAssertEqual(pa.sorted(), Array(0..<1000))
        XCTAssertEqual(a.permutation(count: 0), [])
        XCTAssertEqual(a.permutation(count: 1), [0])
    }

    func testUnitFloatRange() {
        var g = SplitMix64(seed: 0)
        for _ in 0..<10_000 {
            let f = g.nextUnitFloat()
            XCTAssertTrue(f >= 0 && f < 1)
        }
    }
}
