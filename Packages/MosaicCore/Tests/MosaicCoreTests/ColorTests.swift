import XCTest
@testable import MosaicCore

final class ColorTests: XCTestCase {
    func testSRGBTransferFunctionReferenceValues() {
        XCTAssertEqual(SRGB.toLinear(0), 0)
        XCTAssertEqual(SRGB.toLinear(1), 1, accuracy: 1e-6)
        XCTAssertClose(SRGB.toLinear(0.5), 0.21404114048223255, accuracy: 1e-6)
        // 线性段（≤ 0.04045）
        XCTAssertClose(SRGB.toLinear(0.04), 0.04 / 12.92, accuracy: 1e-7)
        XCTAssertClose(SRGB.linear(fromByte: 128), 0.21586050011389926, accuracy: 1e-6)
        XCTAssertEqual(SRGB.linearLUT.count, 256)
    }

    func testSRGBRoundTrip() {
        for i in 0...255 {
            let v = Float(i) / 255
            XCTAssertEqual(SRGB.fromLinear(SRGB.toLinear(v)), v, accuracy: 1e-5)
        }
    }

    /// 参考值：CSS Color 4 / Björn Ottosson 原始矩阵（Python 双精度计算）。
    func testOKLabPrimariesReferenceValues() {
        let cases: [((Float, Float, Float), (Double, Double, Double))] = [
            ((1, 0, 0), (0.6279553606145516, 0.22486306106597398, 0.1258462985307351)),
            ((0, 1, 0), (0.8664396115356694, -0.23388757418790812, 0.17949847989672985)),
            ((0, 0, 1), (0.4520137183853429, -0.03245698416876397, -0.3115281476783751)),
            ((1, 1, 1), (1.0, 0.0, 0.0)),
            ((0, 0, 0), (0.0, 0.0, 0.0)),
        ]
        for (rgb, expected) in cases {
            let lab = OKLab(srgbRed: rgb.0, green: rgb.1, blue: rgb.2)
            XCTAssertClose(lab.L, expected.0, "L for \(rgb)")
            XCTAssertClose(lab.a, expected.1, "a for \(rgb)")
            XCTAssertClose(lab.b, expected.2, "b for \(rgb)")
        }
    }

    func testOKLabGrayIsAchromatic() {
        let gray = OKLab(LinearRGB(srgb8Red: 128, green: 128, blue: 128))
        XCTAssertClose(gray.L, 0.5998708017071177)
        XCTAssertClose(gray.a, 0)
        XCTAssertClose(gray.b, 0)
    }

    func testOKLabRoundTrip() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<500 {
            let rgb = LinearRGB(r: rng.nextUnitFloat(), g: rng.nextUnitFloat(), b: rng.nextUnitFloat())
            let back = OKLab(rgb).linearRGB
            XCTAssertEqual(back.r, rgb.r, accuracy: 1e-4)
            XCTAssertEqual(back.g, rgb.g, accuracy: 1e-4)
            XCTAssertEqual(back.b, rgb.b, accuracy: 1e-4)
        }
    }

    /// 参考值：Bruce Lindbloom 计算器（sRGB, D65）。
    /// A-03：CIELAB 对照表，容差 1e-4（QA 要求）。参考值由同一组常数（Lindbloom sRGB→XYZ 矩阵、
    /// D65 白点 0.95047/1/1.08883、CIE 分段函数）用 Python 双精度独立计算，保留 6 位小数。
    func testA03CIELabReferenceValues() {
        let table: [((Float, Float, Float), (Double, Double, Double))] = [
            ((1, 0, 0), (53.240794, 80.092460, 67.203197)),
            ((0, 1, 0), (87.734722, -86.182716, 83.179321)),
            ((0, 0, 1), (32.297011, 79.187520, -107.860162)),
            ((1, 1, 1), (100.000004, -0.000017, 0.000007)),   // 矩阵行和非精确归一，白点不严格为 0
            ((0, 0, 0), (0.0, 0.0, 0.0)),
            ((0.5, 0.5, 0.5), (53.388967, -0.000010, 0.000004)),
            ((0.2, 0.4, 0.6), (42.008146, -0.151708, -32.846036)),
        ]
        for (rgb, ref) in table {
            let c = CIELab(srgbRed: rgb.0, green: rgb.1, blue: rgb.2)
            XCTAssertClose(c.L, ref.0, accuracy: 1e-4, "L \(rgb)")
            XCTAssertClose(c.a, ref.1, accuracy: 1e-4, "a \(rgb)")
            XCTAssertClose(c.b, ref.2, accuracy: 1e-4, "b \(rgb)")
        }
    }

    func testColorSpaceDispatch() {
        let rgb = LinearRGB(r: 0.2, g: 0.4, b: 0.6)
        XCTAssertEqual(FeatureColorSpace.oklab.convert(rgb), OKLab(rgb).simd)
        XCTAssertEqual(FeatureColorSpace.cielab.convert(rgb), CIELab(rgb).simd)
    }

    func testOKLabDistance() {
        let a = OKLab(L: 0.5, a: 0.1, b: -0.1)
        let b = OKLab(L: 0.6, a: 0.0, b: 0.1)
        XCTAssertEqual(a.squaredDistance(to: b), 0.01 + 0.01 + 0.04, accuracy: 1e-6)
        XCTAssertEqual(a.squaredDistance(to: a), 0)
    }
}
