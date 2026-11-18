import MosaicCore
import XCTest
@testable import MosaicAppCore

final class GenerationMachineTests: XCTestCase {
    let ok = GenerationOutcome(seed: 42, shouldShowShortageNotice: false, cellCount: 4800)

    func testShortagePromptThenRun() {
        var m = GenerationMachine(initialSeed: 42)
        XCTAssertEqual(m.send(.startTapped(available: 150)), [])
        XCTAssertEqual(m.phase, .confirmingShortage(available: 150))
        XCTAssertEqual(m.send(.shortageBack), [])
        XCTAssertEqual(m.phase, .idle)
        _ = m.send(.startTapped(available: 150))
        XCTAssertEqual(m.send(.shortageContinue), [.setGenerationActive(true), .run(runID: 1, seed: 42)])
        // 充足时直接跑
        var m2 = GenerationMachine(initialSeed: 7)
        XCTAssertEqual(m2.send(.startTapped(available: 200)), [.setGenerationActive(true), .run(runID: 1, seed: 7)])
        var m3 = GenerationMachine(initialSeed: 7)
        _ = m3.send(.startTapped(available: 0))
        XCTAssertEqual(m3.phase, .failed(.noMaterial))
    }

    func testCancelConfirmFlowAndStaleResultsIgnored() {
        var m = GenerationMachine(initialSeed: 42)
        _ = m.send(.startTapped(available: 1000))
        _ = m.send(.progressed(runID: 1, fraction: 0.4))
        XCTAssertEqual(m.fraction, 0.4)
        _ = m.send(.progressed(runID: 1, fraction: 0.2))
        XCTAssertEqual(m.fraction, 0.4, "进度不倒退")
        _ = m.send(.cancelTapped)
        XCTAssertTrue(m.showsCancelConfirm)
        _ = m.send(.cancelDismissed)
        XCTAssertEqual(m.phase, .running(runID: 1, seed: 42, isReshuffle: false))
        _ = m.send(.cancelTapped)
        XCTAssertEqual(m.send(.cancelConfirmed), [.cancel(runID: 1), .setGenerationActive(false)])
        XCTAssertEqual(m.phase, .idle)
        // 取消后才到的结果 / 错误：忽略
        XCTAssertEqual(m.send(.succeeded(runID: 1, ok)), [])
        XCTAssertEqual(m.send(.finishedWithError(runID: 1, failure: nil)), [])
        XCTAssertEqual(m.phase, .idle)
        // 再开始是新的 runID、同一种子（还没成功过）
        XCTAssertEqual(m.send(.startTapped(available: 1000)), [.setGenerationActive(true), .run(runID: 2, seed: 42)])
        XCTAssertEqual(m.send(.succeeded(runID: 1, ok)), [], "旧 runID 忽略")
    }

    func testBackgroundSuspendsAndRerunsSameSeed() {
        var m = GenerationMachine(initialSeed: 42)
        _ = m.send(.startTapped(available: 1000))
        XCTAssertEqual(m.send(.enteredBackground), [.cancel(runID: 1), .setGenerationActive(false)])
        XCTAssertEqual(m.phase, .suspended(seed: 42, isReshuffle: false))
        XCTAssertEqual(m.send(.finishedWithError(runID: 1, failure: nil)), [], "被取消的旧运行回报忽略")
        XCTAssertEqual(m.send(.becameActive), [.setGenerationActive(true), .run(runID: 2, seed: 42)], "同一种子自动重跑")
        _ = m.send(.succeeded(runID: 2, ok))
        XCTAssertEqual(m.phase, .result(ok))
        XCTAssertNil(m.settingsNotice)
    }

    func testAutoRetryFailureReturnsToSettingsWithNotice() {
        var m = GenerationMachine(initialSeed: 42)
        _ = m.send(.startTapped(available: 1000))
        _ = m.send(.enteredBackground)
        _ = m.send(.becameActive)
        _ = m.send(.finishedWithError(runID: 2, failure: .other))
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.settingsNotice, .generateAutoRetryFailed)
        XCTAssertEqual(m.send(.retryTapped(available: 1000)), [.setGenerationActive(true), .run(runID: 3, seed: 42)])
        XCTAssertNil(m.settingsNotice)
        // 非自动重跑的失败 → 失败页
        _ = m.send(.finishedWithError(runID: 3, failure: .other))
        XCTAssertEqual(m.phase, .failed(.other))
        _ = m.send(.backToSettings)
        XCTAssertEqual(m.phase, .idle)
    }

    func testSystemCancellationIsSilentSuspend() {
        var m = GenerationMachine(initialSeed: 42)
        _ = m.send(.startTapped(available: 1000))
        _ = m.send(.finishedWithError(runID: 1, failure: nil))
        XCTAssertEqual(m.phase, .suspended(seed: 42, isReshuffle: false), "CancellationError 不进失败页")
    }

    func testReshuffleUsesNextSeedAndCancelReturnsToResult() {
        var m = GenerationMachine(initialSeed: 42)
        _ = m.send(.startTapped(available: 1000))
        _ = m.send(.succeeded(runID: 1, ok))
        let next = MosaicSeed.next(after: 42)
        XCTAssertEqual(m.send(.reshuffleTapped), [.setGenerationActive(true), .run(runID: 2, seed: next)])
        _ = m.send(.cancelTapped)
        _ = m.send(.cancelConfirmed)
        XCTAssertEqual(m.phase, .result(ok), "换一种拼法被取消 → 回到上一结果")
        _ = m.send(.reshuffleTapped)
        let o2 = GenerationOutcome(seed: next, shouldShowShortageNotice: true, cellCount: 4800)
        _ = m.send(.succeeded(runID: 3, o2))
        XCTAssertEqual(m.phase, .result(o2))
    }

    func testFailureClassification() {
        XCTAssertNil(GenerationFailure.classify(CancellationError()), "决定 (2)")
        XCTAssertEqual(GenerationFailure.classify(PhotoIndexError.albumUnreadable), .albumUnreadable)
        XCTAssertEqual(GenerationFailure.classify(MosaicError.noCandidates), .noMaterial)
        struct Other: Error {}
        XCTAssertEqual(GenerationFailure.classify(Other()), .other)
    }
}
