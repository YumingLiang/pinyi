import XCTest
@testable import MosaicAppCore

final class PerfTests: XCTestCase {
    func testMeasureWithManualClockAndReport() {
        let mc = ManualClock()
        let perf = PerfRecorder(clock: mc.clock, capacity: 100)
        for ms in [10.0, 20, 30, 40, 100] {
            perf.measure(.thumbnailFetch, items: 300) { mc.advance(ms / 1000) }
        }
        let r = perf.report()
        let row = try! XCTUnwrap(r.row(.thumbnailFetch))
        XCTAssertEqual(row.count, 5)
        XCTAssertEqual(row.totalSeconds, 0.2, accuracy: 1e-9)
        XCTAssertEqual(row.medianSeconds, 0.03, accuracy: 1e-9)
        XCTAssertEqual(row.p90Seconds, 0.1, accuracy: 1e-9)
        XCTAssertEqual(row.maxSeconds, 0.1, accuracy: 1e-9)
        XCTAssertEqual(row.itemsPerSecond!, 1500 / 0.2, accuracy: 1e-6)
        let text = r.plainText(deviceNote: "iPhone11")
        XCTAssertTrue(text.hasPrefix("iPhone11\nphase\t"))
        XCTAssertTrue(text.contains("thumbnailFetch\t5\t200.0\t30.0\t100.0\t100.0\t1500\t7500.0"), text)
        perf.reset()
        XCTAssertEqual(perf.report().sampleCount, 0)
    }

    func testCapacityBound() {
        let perf = PerfRecorder(capacity: 3)
        for i in 0..<10 { perf.record(.indexCommit, seconds: Double(i)) }
        XCTAssertEqual(perf.allSamples().map(\.seconds), [7, 8, 9])
    }

    func testGenerationPhaseTimer() {
        let mc = ManualClock()
        let t = GenerationPhaseTimer(clock: mc.clock)
        mc.advance(0.01); t.observe(.sampling)
        mc.advance(0.05); t.observe(.matching)
        mc.advance(0.5); t.observe(.matching)
        mc.advance(0.2); t.observe(.assigning)
        mc.advance(0.3)
        let s = t.finish(cells: 4800, note: "medium")
        XCTAssertEqual(s.map(\.phase), [.generateSampling, .generateMatching, .generateAssigning, .generateTotal])
        XCTAssertEqual(s[0].seconds, 0.05, accuracy: 1e-9)
        XCTAssertEqual(s[1].seconds, 0.7, accuracy: 1e-9)
        XCTAssertEqual(s[2].seconds, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s[3].seconds, 1.06, accuracy: 1e-9)
    }

    func testScanThroughputIncludesSkipped() {
        // 决定：iCloud 跳过的也计入张数
        XCTAssertEqual(PerfReport.scanThroughput(processed: 10000, wallSeconds: 90)!, 111.11, accuracy: 0.01)
        XCTAssertNil(PerfReport.scanThroughput(processed: 0, wallSeconds: 1))
    }

    func testSystemClockMonotonic() {
        let a = MonotonicClock.system.now()
        let b = MonotonicClock.system.now()
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testAsyncMeasure() async {
        let mc = ManualClock()
        let perf = PerfRecorder(clock: mc.clock)
        let v = await perf.measure(.targetDecode) { () async -> Int in mc.advance(0.25); return 7 }
        XCTAssertEqual(v, 7)
        XCTAssertEqual(perf.report().row(.targetDecode)?.totalSeconds ?? 0, 0.25, accuracy: 1e-9)
    }
}
