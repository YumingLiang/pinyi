import Dispatch
import Foundation
import XCTest
@testable import MosaicCore

/// 线程安全的收集器（测试用）。
final class Box<T: Sendable>: Sendable {
    private let state: LockedState<T>
    init(_ v: T) { state = LockedState(v) }
    var value: T { state.get() }
    func mutate(_ f: (inout T) -> Void) { state.withLock { f(&$0) } }
}

/// 只实现不可取消接口的内核，用来验证协议默认实现。
private struct PlainKernel: DistanceKernel {
    func topK(queries: UnsafeBufferPointer<Float>, m: Int, candidates: UnsafeBufferPointer<Float>, n: Int,
              dims: Int, k: Int, mask: BitMask?) -> TopKResult {
        ScalarSIMDKernel(parallel: false).topK(queries: queries, m: m, candidates: candidates, n: n, dims: dims, k: k, mask: mask)
    }
}

func gradientImage(width: Int, height: Int) throws -> PixelBuffer {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let o = (y * width + x) * 4
            bytes[o] = UInt8(x * 255 / max(1, width - 1))
            bytes[o + 1] = UInt8(y * 255 / max(1, height - 1))
            bytes[o + 2] = UInt8((x + y) * 127 / max(1, width + height - 2))
        }
    }
    return try PixelBuffer(width: width, height: height, bytes: bytes)
}

/// 原缺陷 7（D7）/ 技术方案 §5.1：可取消生成。**不是 A-16**；
/// 其中 `testRerunAfterCancelIsIdenticalToUncancelledRun` 只是「取消不破坏可复现性」的附加覆盖。
final class CancellationTests: XCTestCase {
    private func fixture(library: Int = 2_000, cols: Int = 30, rows: Int = 20)
        throws -> (grid: MosaicGrid, cells: FeatureMatrix, lib: FeatureMatrix) {
        let grid = try MosaicGrid(columns: cols, rows: rows)
        return (grid, FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: 21)),
                FeatureMatrix(vectors: syntheticVectors(count: library, seed: 22)))
    }

    private func assertCancelled(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { e in
            XCTAssertTrue(e is CancellationError, "expected CancellationError, got \(e)", file: file, line: line)
        }
    }

    func testPreCancelledTokenStopsEverything() throws {
        let f = try fixture()
        let token = CancellationToken()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
        assertCancelled { _ = try ScalarSIMDKernel().topK(queries: f.cells, candidates: f.lib, k: 8, mask: nil, cancellation: token, progress: nil) }
        assertCancelled { _ = try PlainKernel().topK(queries: f.cells, candidates: f.lib, k: 8, mask: nil, cancellation: token, progress: nil) }
        assertCancelled {
            _ = try GreedyAssigner().assign(grid: f.grid, cellFeatures: f.cells, library: f.lib, mask: nil,
                                            lightnessVariance: nil, cancellation: token, progress: nil)
        }
        let img = try gradientImage(width: 64, height: 48)
        assertCancelled {
            _ = try MosaicPipeline().generate(target: img, density: .custom(columns: 16), table: FeatureTable(records:
                syntheticVectors(count: 300, seed: 1).map { FeatureRecord(vector: $0) }), cancellation: token)
        }
    }

    func testCancelDuringMatchingAndAssigningPhases() throws {
        let f = try fixture()
        for phase in [MosaicProgress.Phase.matching, .assigning] {
            let token = CancellationToken()
            let seen = Box<[MosaicProgress]>([])
            assertCancelled {
                _ = try GreedyAssigner().assign(grid: f.grid, cellFeatures: f.cells, library: f.lib, mask: nil,
                                                lightnessVariance: nil, cancellation: token) { p in
                    seen.mutate { $0.append(p) }
                    if p.phase == phase, p.completed >= (phase == .matching ? 2 : 128) { token.cancel() }
                }
            }
            let ps = seen.value
            XCTAssertTrue(ps.contains { $0.phase == phase }, "phase \(phase)")
            // 被取消后不会报告"完成"。
            XCTAssertFalse(ps.contains { $0.phase == .assigning && $0.completed == $0.total }, "phase \(phase)")
        }
    }

    func testRerunAfterCancelIsIdenticalToUncancelledRun() throws {
        let f = try fixture()
        let config = AssignmentConfiguration(seed: 1234)
        let baseline = try GreedyAssigner(configuration: config).assign(grid: f.grid, cellFeatures: f.cells, library: f.lib)

        let token = CancellationToken()
        assertCancelled {
            _ = try GreedyAssigner(configuration: config).assign(grid: f.grid, cellFeatures: f.cells, library: f.lib, mask: nil,
                                                                 lightnessVariance: nil, cancellation: token) { p in
                if p.phase == .assigning, p.completed >= 64 { token.cancel() }
            }
        }
        let progress = Box<[MosaicProgress]>([])
        let rerun = try GreedyAssigner(configuration: config).assign(
            grid: f.grid, cellFeatures: f.cells, library: f.lib, mask: nil, lightnessVariance: nil,
            cancellation: CancellationToken()) { p in progress.mutate { $0.append(p) } }
        XCTAssertEqual(rerun, baseline)

        // 进度：每阶段单调不减，最终到达 total。
        for phase in [MosaicProgress.Phase.matching, .assigning] {
            let xs = progress.value.filter { $0.phase == phase }
            XCTAssertFalse(xs.isEmpty)
            XCTAssertEqual(xs.map(\.completed), xs.map(\.completed).sorted())
            XCTAssertEqual(xs.last?.completed, xs.last?.total)
        }
        XCTAssertEqual(progress.value.last?.overallFraction ?? 0, 1, accuracy: 1e-9)
    }

    /// 跨线程取消。**硬判逻辑**：抛 `CancellationError`、不产出结果、取消后每个工作线程最多再完成一个检查点批次
    /// （这里体现为：取消后再到达的匹配进度事件 ≤ 并行线程数）。**墙钟只记录**：超过 250 ms 打 `::warning::`，不失败——
    /// CI 模拟器 Debug、共享 runner 的耗时不稳定（PR #1 曾测到 805 ms，根因是检查粒度，已改为每个候选块检查）。
    func testCancellationLatencyFromAnotherThread() throws {
        // 由进度回调触发"另一个线程"去取消，保证取消时仍在计算中（debug / release 都成立）。
        let f = try fixture(library: 20_000, cols: 80, rows: 60)
        let token = CancellationToken()
        let cancelAt = Box<UInt64>(0)
        let trigger = DispatchSemaphore(value: 0)
        let ack = DispatchSemaphore(value: 0)   // S-8：回调等到取消真正发出再返回，快机器上也不会先跑完
        let fired = Box<Bool>(false)
        let eventsAfterCancel = Box<Int>(0)
        DispatchQueue.global().async {
            trigger.wait()
            cancelAt.mutate { $0 = DispatchTime.now().uptimeNanoseconds }
            token.cancel()
            ack.signal()
        }
        var thrown: Error?
        var result: MosaicAssignment?
        do {
            result = try GreedyAssigner().assign(grid: f.grid, cellFeatures: f.cells, library: f.lib, mask: nil,
                                                 lightnessVariance: nil, cancellation: token) { p in
                if fired.value { eventsAfterCancel.mutate { $0 += 1 } }
                if p.phase == .matching, p.completed >= 3 {
                    var first = false
                    fired.mutate { if !$0 { $0 = true; first = true } }
                    if first { trigger.signal(); ack.wait() }
                }
            }
        } catch { thrown = error }
        let end = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(thrown is CancellationError, "finished before cancel? \(String(describing: thrown))")
        XCTAssertNil(result, "取消后不得产出结果")
        let workers = ProcessInfo.processInfo.activeProcessorCount
        XCTAssertLessThanOrEqual(eventsAfterCancel.value, workers,
                                 "取消后每个工作线程最多再完成一个批次（\(workers) 线程）")
        let latencyMs = Double(end - cancelAt.value) / 1e6
        print(String(format: "[bench] cancel latency (assign 80x60 × 20000, cross-thread) = %.2f ms; events after cancel = %d",
                     latencyMs, eventsAfterCancel.value))
        if latencyMs >= 250 {
            print(String(format: "::warning::cancel latency %.0f ms ≥ 250 ms（只记录，不失败；检查粒度由 testKernelChecksCancellationBetweenCandidateTiles 硬判）", latencyMs))
        }
    }

    /// 串行内核下取消后**不再完成任何批次**：在第 3 个匹配批次的进度回调里同步取消，之后不得再有进度事件，
    /// 抛 `CancellationError`、无结果。不依赖墙钟、不依赖线程调度。
    func testSerialKernelStopsAtNextCheckpointAfterCancel() throws {
        let f = try fixture(library: 5_000, cols: 40, rows: 30)
        let token = CancellationToken()
        let cancelled = Box<Bool>(false)
        let after = Box<Int>(0)
        var result: MosaicAssignment?
        var thrown: Error?
        do {
            result = try GreedyAssigner(kernel: ScalarSIMDKernel(parallel: false))
                .assign(grid: f.grid, cellFeatures: f.cells, library: f.lib, mask: nil,
                        lightnessVariance: nil, cancellation: token) { p in
                    if cancelled.value { after.mutate { $0 += 1 }; return }
                    // >=：ProgressCounter 可能跳过中间值（与 PerformanceTests 同一写法）；上面 cancelled.value 保证只取消一次
                    if p.phase == .matching, p.completed >= 3 { cancelled.mutate { $0 = true }; token.cancel() }
                }
        } catch { thrown = error }
        XCTAssertTrue(cancelled.value)
        XCTAssertTrue(thrown is CancellationError)
        XCTAssertNil(result)
        XCTAssertEqual(after.value, 0, "取消后不得再完成任何批次")
    }

    /// 取消检查粒度（PR #1 CI：模拟器 Debug 取消延迟 805 ms 的根因）：距离内核在**每个候选块**之前检查，
    /// 而不只是每组查询之前。不依赖墙钟：第 3 次检查时要求停止，必须恰好只扫了 2 个候选块就返回。
    func testKernelChecksCancellationBetweenCandidateTiles() {
        let dims = 12, m = 16, n = 5000, k = 4, tile = 1024
        var rng = SplitMix64(seed: 9)
        let q = (0..<(dims * m)).map { _ in rng.nextUnitFloat() }
        let c = (0..<(dims * n)).map { _ in rng.nextUnitFloat() }
        var oi = [UInt32](repeating: 0, count: m * k)
        var od = [Float](repeating: 0, count: m * k)
        var checks = 0
        let finished = q.withUnsafeBufferPointer { qp in
            c.withUnsafeBufferPointer { cp in
                ScalarSIMDKernel.processBlock(qStart: 0, qEnd: m, m: m, q: qp.baseAddress!, n: n, c: cp.baseAddress!,
                                              dims: dims, k: k, tile: tile, maskWords: nil,
                                              outIndices: &oi, outDistances: &od,
                                              shouldStop: { checks += 1; return checks >= 3 })
            }
        }
        XCTAssertFalse(finished)
        XCTAssertEqual(checks, 3, "每个候选块前检查一次")
        // 不取消时：检查次数 = 候选块数 ⌈5000/1024⌉ = 5
        checks = 0
        let done = q.withUnsafeBufferPointer { qp in
            c.withUnsafeBufferPointer { cp in
                ScalarSIMDKernel.processBlock(qStart: 0, qEnd: m, m: m, q: qp.baseAddress!, n: n, c: cp.baseAddress!,
                                              dims: dims, k: k, tile: tile, maskWords: nil,
                                              outIndices: &oi, outDistances: &od,
                                              shouldStop: { checks += 1; return false })
            }
        }
        XCTAssertTrue(done)
        XCTAssertEqual(checks, 5)
    }

    func testSwiftTaskCancellationAsyncAPI() async throws {
        let img = try gradientImage(width: 320, height: 240)
        let records = syntheticVectors(count: 20_000, seed: 5).map { FeatureRecord(vector: $0, lightnessVariance: 0.001) }
        let table = FeatureTable(records: records)
        let pipeline = MosaicPipeline()
        // 评审 ca6a4ca S-8：不靠固定 sleep。进入匹配阶段的第一次进度回调里**停住**，直到测试发出取消，
        // 因此无论机器多快，任务都不可能在取消前跑完。
        let started = Box<Bool>(false)
        let go = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try await pipeline.generate(target: img, density: .fine, table: table, seed: 1) { p in
                guard p.phase == .matching else { return }
                var first = false
                started.mutate { if !$0 { $0 = true; first = true } }
                if first { go.wait() }
            }
        }
        while !started.value { try await Task.sleep(nanoseconds: 1_000_000) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        go.signal()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            print(String(format: "[bench] Task.cancel latency (pipeline .fine × 20000) = %.2f ms", ms))
            // 墙钟只记录（CI 共享 runner / 模拟器 Debug 不稳定）；逻辑由 CancellationError 与粒度测试硬判。
            if ms >= 250 { print(String(format: "::warning::Task.cancel latency %.0f ms ≥ 250 ms（只记录，不失败）", ms)) }
        }
    }

    func testSyncAPIObservesEnclosingTaskCancellation() async throws {
        let f = try fixture()
        let task = Task.detached { () throws -> MosaicAssignment in
            while !Task.isCancelled { await Task.yield() }
            // 无令牌：同步入口仍能看到当前 Task 已取消。
            return try GreedyAssigner().assign(grid: f.grid, cellFeatures: f.cells, library: f.lib, mask: nil,
                                               lightnessVariance: nil, cancellation: nil, progress: nil)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    func testAsyncAPIUncancelledMatchesSyncAPI() async throws {
        let img = try gradientImage(width: 96, height: 64)
        let table = FeatureTable(records: syntheticVectors(count: 600, seed: 8).enumerated().map {
            FeatureRecord(vector: $1, lightnessVariance: $0 % 3 == 0 ? 0 : 0.001)
        })
        let p = MosaicPipeline()
        let a = try await p.generate(target: img, density: .custom(columns: 24), table: table, seed: 77)
        let b = try p.generate(target: img, density: .custom(columns: 24), table: table, seed: 77, cancellation: nil)
        XCTAssertEqual(a, b)
    }

    func testCheckIntervalValidated() {
        var c = AssignmentConfiguration()
        c.cancellationCheckInterval = 0
        XCTAssertThrowsError(try c.validate())
    }
}
