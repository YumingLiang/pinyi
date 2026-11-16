import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

final class GenerationRunnerTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func gradientTarget(w: Int = 160, h: Int = 120) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            bytes[o] = UInt8(x * 255 / (w - 1)); bytes[o + 1] = UInt8(y * 255 / (h - 1)); bytes[o + 2] = 128
        } }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }

    func makeIndex(assets: Int) async throws -> PhotoIndex {
        let idx = PhotoIndex(directory: dir, library: FakePhotoLibrary(assetCount: assets), thumbnails: FakeThumbnails(),
                             configuration: smallConfig(batch: 100, concurrency: 16, minRows: 1000))
        await idx.load()
        _ = try await idx.synchronize()
        return idx
    }

    func testEndToEndReproducibleAndMapsCellsToAssets() async throws {
        let idx = try await makeIndex(assets: 300)
        let snap = try await idx.snapshot(for: .allPhotos)
        let perf = PerfRecorder()
        let runner = GenerationRunner(perf: perf)
        let settings = GenerationSettings(density: .coarse)
        let fractions = Locked<[Double]>([])
        let p1 = try await runner.run(target: try gradientTarget(), snapshot: snap, settings: settings, seed: 9) { f in
            fractions.update { $0.append(f) }
        }
        XCTAssertEqual(p1.generation.layout.columns, 40)
        XCTAssertEqual(p1.generation.layout.rows, 30)
        XCTAssertFalse(p1.outcome.shouldShowShortageNotice)
        XCTAssertEqual(fractions.get().last ?? 0, 1, accuracy: 1e-9)
        let ids = p1.cellAssetIDs
        XCTAssertEqual(ids.count, 1200)
        XCTAssertTrue(ids.allSatisfy { $0 != nil })
        let p2 = try await runner.run(target: try gradientTarget(), snapshot: snap, settings: settings, seed: 9)
        XCTAssertEqual(p1.generation.assignment.tiles, p2.generation.assignment.tiles, "同种子同结果")
        let p3 = try await runner.reshuffle(p1, target: try gradientTarget(), settings: settings, seed: MosaicSeed.next(after: 9))
        XCTAssertNotEqual(p1.generation.assignment.tiles, p3.generation.assignment.tiles, "换一种拼法")
        let r = perf.report()
        XCTAssertEqual(r.row(.generateTotal)?.count, 3)
        XCTAssertNotNil(r.row(.generateMatching))
        XCTAssertNotNil(r.row(.generateAssigning))
        XCTAssertEqual(r.row(.generateSampling)?.totalItems, 3600)
    }

    func testShortageNoticeOnSmallLibrary() async throws {
        let idx = try await makeIndex(assets: 5)
        let snap = try await idx.snapshot(for: .allPhotos)
        XCTAssertTrue(snap.library.supply.needsWarning)
        let p = try await GenerationRunner().run(target: try gradientTarget(), snapshot: snap,
                                                 settings: GenerationSettings(density: .coarse), seed: 1)
        // 5 张铺 1200 格：8 邻域至少要 9 张不同的，必然放宽约束 → 结果页提示（可用 < 200 且放宽）
        XCTAssertTrue(p.outcome.shouldShowShortageNotice)
    }

    func testTaskCancellationThrowsCancellationErrorAndMachineStaysSilent() async throws {
        let idx = try await makeIndex(assets: 300)
        let snap = try await idx.snapshot(for: .allPhotos)
        let target = try gradientTarget(w: 400, h: 300)
        let gate = DispatchSemaphore(value: 0)
        let task = Task {
            try await GenerationRunner().run(target: target, snapshot: snap, settings: GenerationSettings(density: .fine), seed: 3) { f in
                if f > 0.05 { gate.signal() }
            }
        }
        // 等到进入匹配阶段再取消（不依赖固定时长）
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { gate.wait(); c.resume() }
        }
        task.cancel()
        do {
            _ = try await task.value
            // 极少数情况下取消到达前已算完：也可接受，但不应抛别的错
        } catch {
            XCTAssertTrue(error is CancellationError, "实际 \(error)")
            var m = GenerationMachine(initialSeed: 3)
            _ = m.send(.startTapped(available: 300))
            _ = m.send(.finishedWithError(runID: 1, failure: GenerationFailure.classify(error)))
            if case .failed = m.phase { XCTFail("取消不应进失败页") }
        }
    }

    func testPreviewRendererReproducesTileColors() async throws {
        let lib = FakePhotoLibrary(assetCount: 2)
        let thumbs = FakeThumbnails()
        thumbs.state.update { $0.colorOverride = ["a0": (200, 30, 40), "a1": (20, 180, 90)] }
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, configuration: smallConfig())
        await idx.load()
        _ = try await idx.synchronize()
        let snap = try await idx.snapshot(for: .allPhotos)
        let p = try await GenerationRunner().run(target: try PixelBuffer.solid(width: 40, height: 20, red: 200, green: 30, blue: 40),
                                                 snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 1)
        let img = try PreviewRenderer.render(p.generation, table: snap.library.table, cellPixels: 4)
        XCTAssertEqual(img.width, 160)
        XCTAssertEqual(img.height, 80)
        for cell in 0..<p.generation.layout.cellCount {
            let (cx, cy) = p.generation.layout.grid.position(of: cell)
            let id = p.cellAssetIDs[cell]!
            let expected = thumbs.state.get().colorOverride[id]!
            let px = img.rgb(x: cx * 4 + 1, y: cy * 4 + 1)
            XCTAssertLessThanOrEqual(abs(Int(px.r) - Int(expected.0)), 1)
            XCTAssertLessThanOrEqual(abs(Int(px.g) - Int(expected.1)), 1)
            XCTAssertLessThanOrEqual(abs(Int(px.b) - Int(expected.2)), 1)
        }
    }
}

