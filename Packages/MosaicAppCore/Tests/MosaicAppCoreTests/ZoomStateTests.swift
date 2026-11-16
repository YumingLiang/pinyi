import XCTest
@testable import MosaicAppCore

/// 真机 32ec2b5：预览「第一次放大正常，再放大没反应」。
/// QA 回归用例以 ZoomRegression 前缀命名。
final class ZoomStateTests: XCTestCase {
    typealias V = ZoomState.Vector

    /// 390×700 视口里放一张 4:3 的 120×90 格网格（fitted 390×292.5，单格 3.25 pt）。
    private func make() -> ZoomState {
        var z = ZoomState()
        z.updateLayout(viewport: V(x: 390, y: 700), fittedSize: V(x: 390, y: 292.5), columns: 120, rows: 90)
        return z
    }

    /// 粗网格：2×2 格放在 390×390，上限 = minimumMaxScale = 4。
    private func makeCoarse() -> ZoomState {
        var z = ZoomState()
        z.updateLayout(viewport: V(x: 390, y: 700), fittedSize: V(x: 390, y: 390), columns: 2, rows: 2)
        return z
    }

    private func pinch(_ z: inout ZoomState, _ v: Double) {
        z.pinchChanged(1)
        z.pinchChanged((1 + v) / 2)
        z.pinchChanged(v)
        z.pinchEnded(v)
    }

    func testZoomRegressionFivePinchesTimes1_5AccumulateAndStopAtMax() {
        var fine = make()                       // 上限 120，不会碰顶
        var expected = 1.0
        for _ in 0..<5 {
            fine.pinchChanged(1)
            XCTAssertEqual(fine.scale, expected, accuracy: 1e-9, "新一次捏合开始时保持上一次倍数，不弹回 1")
            pinch(&fine, 1.5)
            expected *= 1.5
            XCTAssertEqual(fine.baseScale, expected, accuracy: 1e-9, "基准 = 累乘")
        }
        XCTAssertEqual(fine.scale, 7.59375, accuracy: 1e-9)

        var coarse = makeCoarse()               // 上限 4：1.5, 2.25, 3.375, 4, 4
        var seen: [Double] = []
        for _ in 0..<5 { pinch(&coarse, 1.5); seen.append(coarse.scale) }
        XCTAssertEqual(seen[0], 1.5, accuracy: 1e-9)
        XCTAssertEqual(seen[2], 3.375, accuracy: 1e-9)
        XCTAssertEqual(Array(seen.suffix(2)), [4, 4], "到上限停住")
    }

    func testZoomRegressionFivePinchOutsStopAtMinThenZoomInContinues() {
        var z = make()
        pinch(&z, 3)
        var seen: [Double] = []
        for _ in 0..<5 { pinch(&z, 1 / 1.5); seen.append(z.scale) }
        XCTAssertEqual(seen[0], 2, accuracy: 1e-9)
        XCTAssertEqual(seen[1], 4.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(Array(seen.suffix(3)), [1, 1, 1], "到下限停住")
        XCTAssertEqual(z.offset, .zero)
        pinch(&z, 1.5)
        XCTAssertEqual(z.scale, 1.5, accuracy: 1e-9, "从当前倍数（下限）接着放大")
        pinch(&z, 1.5)
        XCTAssertEqual(z.scale, 2.25, accuracy: 1e-9)
    }

    func testZoomRegressionCancelledPinchKeepsBase() {
        var z = make()
        pinch(&z, 2)
        z.pinchChanged(1.8)
        XCTAssertEqual(z.scale, 3.6, accuracy: 1e-9)
        z.pinchCancelled()                       // onEnded 未触发
        XCTAssertEqual(z.scale, 2, accuracy: 1e-9, "基准不变")
        XCTAssertEqual(z.baseScale, 2, accuracy: 1e-9)
        pinch(&z, 1.5)
        XCTAssertEqual(z.scale, 3, accuracy: 1e-9, "取消后下一次正常累乘")
        // 视图里 @GestureState 复位与 onEnded 的先后不确定：先取消再 onEnded(值) 也得到同一结果
        z.pinchChanged(2); z.pinchCancelled(); z.pinchEnded(2)
        XCTAssertEqual(z.scale, 6, accuracy: 1e-9)
        // onEnded 之后再收到取消是空操作
        pinch(&z, 0.5); z.pinchCancelled()
        XCTAssertEqual(z.scale, 3, accuracy: 1e-9)
    }

    func testZoomRegressionCancelledPanKeepsOffset() {
        var z = make()
        pinch(&z, 2)
        z.panChanged(V(x: 80, y: 0)); z.panEnded()
        z.panChanged(V(x: 60, y: 0)); z.panCancelled()
        XCTAssertEqual(z.offset, V(x: 80, y: 0))
    }

    func testZoomRegressionDoubleTapAndPinchAlternate() {
        var z = make()
        z.doubleTap();          XCTAssertEqual(z.scale, 2, accuracy: 1e-9)
        pinch(&z, 1.5);         XCTAssertEqual(z.scale, 3, accuracy: 1e-9)
        z.doubleTap();          XCTAssertEqual(z.scale, 6, accuracy: 1e-9)
        pinch(&z, 0.5);         XCTAssertEqual(z.scale, 3, accuracy: 1e-9)
        z.pinchChanged(1.5); z.doubleTap()      // 捏合进行中双击：先提交再放大
        XCTAssertEqual(z.scale, 9, accuracy: 1e-9)
        pinch(&z, 100);         XCTAssertEqual(z.scale, z.maxScale)
        z.doubleTap();          XCTAssertEqual(z.scale, 1, "到顶双击复位")
        pinch(&z, 1.5);         XCTAssertEqual(z.scale, 1.5, accuracy: 1e-9)
    }

    func testZoomRegressionRotationAndBackgroundKeepScale() {
        var z = make()
        pinch(&z, 2); pinch(&z, 1.5)
        z.panChanged(V(x: 150, y: 0)); z.panEnded()
        // 旋转到横屏：fitted 变成 700×525（视口 700×390，按高适配 → 520×390）
        z.updateLayout(viewport: V(x: 700, y: 390), fittedSize: V(x: 520, y: 390), columns: 120, rows: 90)
        XCTAssertEqual(z.scale, 3, accuracy: 1e-9, "旋转后倍数保持")
        XCTAssertLessThanOrEqual(abs(z.offset.x), (520 * 3 - 700) / 2, "偏移按新视口重新夹取")
        // 切后台 / 过渡中 GeometryReader 报 0
        z.updateLayout(viewport: .zero, fittedSize: .zero, columns: 120, rows: 90)
        XCTAssertEqual(z.scale, 3, accuracy: 1e-9, "视口为 0 时不丢倍数")
        XCTAssertEqual(z.maxScale, 390 / (520.0 / 120), accuracy: 1e-9)
        // 转回竖屏
        z.updateLayout(viewport: V(x: 390, y: 700), fittedSize: V(x: 390, y: 292.5), columns: 120, rows: 90)
        XCTAssertEqual(z.scale, 3, accuracy: 1e-9)
    }

    func testMaxScaleLetsOneCellFillScreen() {
        let z = make()
        // 单格 3.25 pt，视口短边 390 → 至少 120 倍
        XCTAssertEqual(z.maxScale, 120, accuracy: 1e-9)
        XCTAssertEqual(ZoomState.maxScaleToFillOneCell(viewport: V(x: 390, y: 700), fittedSize: V(x: 390, y: 390), columns: 2, rows: 2),
                       ZoomState.minimumMaxScale, "很粗的网格也至少 4 倍")
        XCTAssertEqual(ZoomState.maxScaleToFillOneCell(viewport: .zero, fittedSize: .zero, columns: 0, rows: 0), ZoomState.minimumMaxScale)
    }

    /// 根因回归（AndyL 复现：第二次捏合时图弹回原大小）：每次手势的值都从 1 开始，
    /// 结束时必须累乘进基准；下一次捏合开始时保持上一次的倍数。
    func testZoomRegressionFiveConsecutivePinchesEachKeepsPreviousScale() {
        var z = make()
        var expected = 1.0
        for _ in 0..<5 {
            z.pinchChanged(1)
            XCTAssertEqual(z.scale, expected, accuracy: 1e-9, "新一次捏合开始时不弹回 1")
            for v in stride(from: 1.0, through: 2.0, by: 0.25) {
                z.pinchChanged(v)
                XCTAssertEqual(z.scale, expected * v, accuracy: 1e-9, "手势中 = 基准 × 增量")
            }
            z.pinchEnded(2)
            expected *= 2
            XCTAssertEqual(z.scale, expected, accuracy: 1e-9)
            XCTAssertEqual(z.baseScale, expected, accuracy: 1e-9)
            XCTAssertEqual(z.liveMagnification, 1)
        }
        XCTAssertEqual(z.scale, 32, accuracy: 1e-9)
    }

    func testZoomRegressionClampLowerAndUpperBounds() {
        var z = make()
        z.pinchChanged(0.3)
        XCTAssertEqual(z.scale, 1, "手势中也不小于 1")
        z.pinchEnded(0.3)
        XCTAssertEqual(z.baseScale, 1)
        z.pinchChanged(500)
        XCTAssertEqual(z.scale, z.maxScale, "手势中也不超上限")
        z.pinchEnded(500)
        XCTAssertEqual(z.baseScale, z.maxScale)
    }

    func testPinchEndedWithoutValueCommitsLastChange() {
        var z = make()
        z.pinchChanged(3)
        z.pinchEnded()
        z.pinchChanged(1.5)
        z.pinchEnded()
        XCTAssertEqual(z.scale, 4.5, accuracy: 1e-9)
    }

    func testZoomRegressionZoomOutThenZoomInAgain() {
        var z = make()
        z.pinchChanged(6); z.pinchEnded(6)
        z.pinchChanged(0.5); z.pinchEnded(0.5)
        XCTAssertEqual(z.scale, 3, accuracy: 1e-9)
        z.pinchChanged(0.1); z.pinchEnded(0.1)
        XCTAssertEqual(z.scale, 1, "夹到 1")
        XCTAssertEqual(z.offset, .zero, "回到 1 时居中")
        z.pinchChanged(2.5); z.pinchEnded(2.5)
        XCTAssertEqual(z.scale, 2.5, accuracy: 1e-9, "缩回后再放大从 1 累乘，不卡住")
    }

    func testPinchClampsAtMaxAndKeepsWorkingAfter() {
        var z = make()
        z.pinchChanged(1000); z.pinchEnded(1000)
        XCTAssertEqual(z.scale, z.maxScale)
        z.pinchChanged(0.5); z.pinchEnded(0.5)
        XCTAssertEqual(z.scale, z.maxScale / 2, accuracy: 1e-9, "从上限缩小，基准是上限不是 1000×")
    }

    func testDoubleTapStepsUpToMaxThenResets() {
        var z = make()
        var seen: [Double] = []
        for _ in 0..<9 { z.doubleTap(); seen.append(z.scale) }
        XCTAssertEqual(Array(seen.prefix(7)), [2, 4, 8, 16, 32, 64, 120], "上限前逐级放大，最后一级停在上限")
        XCTAssertEqual(seen[7], 1, "到顶后复位")
        XCTAssertEqual(seen[8], 2, "复位后还能继续放大")
    }

    func testDoubleTapAfterPinchUsesCommittedScale() {
        var z = make()
        z.pinchChanged(3); z.pinchEnded(3)
        z.doubleTap()
        XCTAssertEqual(z.scale, 6, accuracy: 1e-9)
        z.pinchChanged(1.5); z.pinchEnded(1.5)
        XCTAssertEqual(z.scale, 9, accuracy: 1e-9)
    }

    func testPanClampedToContentAndAccumulates() {
        var z = make()
        z.panChanged(V(x: 100, y: 100)); z.panEnded()
        XCTAssertEqual(z.offset, .zero, "未放大不能拖")
        z.pinchChanged(2); z.pinchEnded(2)
        // 放大后内容 780×585：x 可偏 ±195，y 不超视口 700 → 0
        z.panChanged(V(x: 100, y: 50)); z.panEnded()
        z.panChanged(V(x: 50, y: 0)); z.panEnded()
        XCTAssertEqual(z.offset, V(x: 150, y: 0))
        z.panChanged(V(x: 500, y: 0)); z.panEnded()
        XCTAssertEqual(z.offset, V(x: 195, y: 0))
        z.pinchChanged(0.75); z.pinchEnded(0.75)
        // 1.5×：585 宽，最多 ±97.5
        XCTAssertEqual(z.offset.x, 97.5, accuracy: 1e-9, "缩小时偏移重新夹取")
    }

    func testLayoutChangeKeepsScaleAndReclamps() {
        var z = make()
        z.pinchChanged(200); z.pinchEnded(200)
        z.updateLayout(viewport: V(x: 390, y: 700), fittedSize: V(x: 390, y: 292.5), columns: 30, rows: 22)
        XCTAssertEqual(z.maxScale, 30, accuracy: 1e-9)
        XCTAssertEqual(z.scale, 30, accuracy: 1e-9)
    }

    func testIgnoresBadGestureValues() {
        var z = make()
        z.pinchChanged(.nan); z.pinchChanged(0); z.pinchChanged(-1)
        XCTAssertEqual(z.scale, 1)
    }
}
