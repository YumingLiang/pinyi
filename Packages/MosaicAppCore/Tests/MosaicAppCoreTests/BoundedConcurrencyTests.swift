import XCTest
@testable import MosaicAppCore

final class BoundedConcurrencyTests: XCTestCase {
    func testOrderPreservedAndLimitRespected() async throws {
        let inflight = Locked((0, 0))
        let out = try await BoundedConcurrency.map(Array(0..<50), maxConcurrent: 5) { i -> Int in
            inflight.update { $0.0 += 1; $0.1 = max($0.1, $0.0) }
            try? await Task.sleep(nanoseconds: UInt64((i % 7) * 300_000))
            inflight.update { $0.0 -= 1 }
            return i * 2
        }
        XCTAssertEqual(out, (0..<50).map { $0 * 2 })
        XCTAssertLessThanOrEqual(inflight.get().1, 5)
        let empty = try await BoundedConcurrency.map([Int](), maxConcurrent: 3) { $0 }
        XCTAssertEqual(empty, [])
    }

    func testCancellationThrows() async {
        let started = Locked(0)
        let task = Task {
            try await BoundedConcurrency.map(Array(0..<1000), maxConcurrent: 2) { i -> Int in
                started.update { $0 += 1 }
                try? await Task.sleep(nanoseconds: 1_000_000)
                return i
            }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应取消")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(started.get(), 1000)
    }
}
