import Foundation
import XCTest
@testable import MosaicAppCore

/// 叠加层静默降级（photo-picker-v0.1 §6.1；需求 v0.4 §4.7 验收 0）。
final class OverlayDegradeTests: XCTestCase {
    private func k(_ s: Double) -> Double { OverlayDegrade.factor(effectiveLongSide: s) }
    private let eps = 1e-12

    func testStandardThresholds() {
        let t = OverlayDegrade.Thresholds.standard
        XCTAssertEqual(t.full, 1024)
        XCTAssertEqual(t.half, 480)
        XCTAssertEqual(t.zero, 160)
        XCTAssertEqual(OverlayBlendLimits.maxAlpha, 0.3)
    }

    func testBoundaryValues() {
        XCTAssertEqual(k(0), 0)
        XCTAssertEqual(k(159), 0)
        XCTAssertEqual(k(160), 0)
        XCTAssertEqual(k(479), 0.5 * 319 / 320, accuracy: eps)
        XCTAssertEqual(k(480), 0.5)
        XCTAssertEqual(k(1023), 0.5 + 0.5 * 543 / 544, accuracy: eps)
        XCTAssertEqual(k(1024), 1)
        XCTAssertEqual(k(4096), 1)
        XCTAssertEqual(k(1e12), 1)
        XCTAssertEqual(k(.greatestFiniteMagnitude), 1)
        XCTAssertEqual(k(.infinity), 1)
    }

    func testMidpoints() {
        XCTAssertEqual(k(320), 0.25, accuracy: eps)   // (160+480)/2
        XCTAssertEqual(k(752), 0.75, accuracy: eps)   // (480+1024)/2
        XCTAssertEqual(k(600), 0.5 + 0.5 * 120 / 544, accuracy: eps)
        XCTAssertEqual(k(300), 0.5 * 140 / 320, accuracy: eps)
        XCTAssertEqual(k(120), 0)
    }

    func testContinuousAtEachThreshold() {
        for edge in [160.0, 480, 1024] {
            let below = k(edge.nextDown), at = k(edge), above = k(edge.nextUp)
            XCTAssertEqual(below, at, accuracy: 1e-9, "\(edge) 左侧")
            XCTAssertEqual(above, at, accuracy: 1e-9, "\(edge) 右侧")
        }
    }

    func testMonotonicNonDecreasingAndInRange() {
        var prev = -Double.infinity
        var s = -10.0
        while s <= 1500 {
            let v = k(s)
            XCTAssertGreaterThanOrEqual(v, prev, "s = \(s)")
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
            prev = v
            s += 0.25
        }
    }

    func testNegativeAndNaN() {
        XCTAssertEqual(k(-1), 0)
        XCTAssertEqual(k(-1024), 0)
        XCTAssertEqual(k(-.infinity), 0)
        XCTAssertEqual(k(.nan), 0)
        XCTAssertEqual(k(-0.0), 0)
    }

    func testCustomThresholds() throws {
        let t = try XCTUnwrap(OverlayDegrade.Thresholds(full: 2000, half: 1000, zero: 0))
        XCTAssertEqual(OverlayDegrade.factor(effectiveLongSide: 0, thresholds: t), 0)
        XCTAssertEqual(OverlayDegrade.factor(effectiveLongSide: 500, thresholds: t), 0.25, accuracy: eps)
        XCTAssertEqual(OverlayDegrade.factor(effectiveLongSide: 1000, thresholds: t), 0.5)
        XCTAssertEqual(OverlayDegrade.factor(effectiveLongSide: 1500, thresholds: t), 0.75, accuracy: eps)
        XCTAssertEqual(OverlayDegrade.factor(effectiveLongSide: 2000, thresholds: t), 1)
    }

    func testInvalidThresholdsRejected() {
        XCTAssertNil(OverlayDegrade.Thresholds(full: 480, half: 480, zero: 160))
        XCTAssertNil(OverlayDegrade.Thresholds(full: 1024, half: 160, zero: 160))
        XCTAssertNil(OverlayDegrade.Thresholds(full: 1024, half: 480, zero: -1))
        XCTAssertNil(OverlayDegrade.Thresholds(full: 100, half: 480, zero: 160))
        XCTAssertNil(OverlayDegrade.Thresholds(full: .infinity, half: 480, zero: 160))
        XCTAssertNil(OverlayDegrade.Thresholds(full: 1024, half: .nan, zero: 160))
        XCTAssertNotNil(OverlayDegrade.Thresholds(full: 1024, half: 480, zero: 160))
    }

    // MARK: effectiveAlpha

    func testEffectiveAlphaNoDegrade() {
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0.2, effectiveLongSide: 4096), 0.2, accuracy: eps)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0.3, effectiveLongSide: 1024), 0.3, accuracy: eps)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0, effectiveLongSide: 4096), 0)
    }

    func testEffectiveAlphaCapsAtMaxTimesK() {
        // s = 480 → k = 0.5 → 上限 0.15；用户 0.3 被压到 0.15，用户 0.1 不变。
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0.3, effectiveLongSide: 480), 0.15, accuracy: eps)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0.1, effectiveLongSide: 480), 0.1, accuracy: eps)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0.3, effectiveLongSide: 320), 0.075, accuracy: eps)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0.3, effectiveLongSide: 159), 0)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0.3, effectiveLongSide: .nan), 0)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0.3, effectiveLongSide: -5), 0)
    }

    func testEffectiveAlphaClampsUserValue() {
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: 0.9, effectiveLongSide: 4096), 0.3, accuracy: eps)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: -0.2, effectiveLongSide: 4096), 0)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: .nan, effectiveLongSide: 4096), 0)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: .infinity, effectiveLongSide: 4096), 0.3, accuracy: eps)
        XCTAssertEqual(OverlayDegrade.effectiveAlpha(user: -.infinity, effectiveLongSide: 4096), 0)
    }

    func testEffectiveAlphaMonotonicInLongSideAndNeverAboveUser() {
        for user in [0.0, 0.05, 0.15, 0.3] {
            var prev = -1.0
            var s = 0.0
            while s <= 1200 {
                let a = OverlayDegrade.effectiveAlpha(user: user, effectiveLongSide: s)
                XCTAssertGreaterThanOrEqual(a, prev)
                XCTAssertLessThanOrEqual(a, user + eps)
                XCTAssertLessThanOrEqual(a, OverlayBlendLimits.maxAlpha + eps)
                prev = a
                s += 1
            }
        }
    }
}
