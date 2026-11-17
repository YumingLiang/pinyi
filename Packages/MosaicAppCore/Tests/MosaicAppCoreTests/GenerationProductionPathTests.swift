import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

/// 回归（gen-perf-fix）：生产生成器不接清晰度探测，生成只跑一次匹配，不发任何逐张请求。
final class GenerationProductionPathTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func snapshot(assets: Int) async throws -> IndexSnapshot {
        let idx = PhotoIndex(directory: dir, library: FakePhotoLibrary(assetCount: assets), thumbnails: FakeThumbnails(),
                             backupExclusion: RecordingBackupExclusion(), configuration: smallConfig(batch: 100, concurrency: 16, minRows: 1000))
        await idx.load()
        _ = try await idx.synchronize()
        return try await idx.snapshot(for: .allPhotos)
    }

    func target(w: Int = 160, h: Int = 120) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            bytes[o] = UInt8(x * 255 / (w - 1)); bytes[o + 1] = UInt8(y * 255 / (h - 1)); bytes[o + 2] = 128
        } }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }

    func testProductionRunnerHasNoSharpnessChecker() {
        let r = GenerationRunner.production(pipeline: MosaicPipeline(), perf: PerfRecorder())
        XCTAssertNil(r.sharpness, "生产生成器不得注入逐张清晰度探测")
    }

    func testProductionRunGeneratesOnceWithoutProbeOrRematch() async throws {
        let snap = try await snapshot(assets: 300)
        let perf = PerfRecorder()
        let stages = Locked<[GenerationStage]>([])
        let fractions = Locked<[Double]>([])
        let r = GenerationRunner.production(pipeline: MosaicPipeline(), perf: perf)
        let p = try await r.run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 7,
                                progress: { f in fractions.update { $0.append(f) } },
                                stage: { s in stages.update { $0.append(s) } })
        XCTAssertFalse(p.lowRes.enabled)
        XCTAssertEqual(p.lowRes.excludedCount, 0)
        XCTAssertNil(p.outcome.availableAfterFilter, "不注入时没有筛选后张数，不会触发结果页筛选后「照片比较少」")
        XCTAssertEqual(p.snapshot.availableCount, 300, "快照不剔除任何照片")
        XCTAssertTrue(p.cellAssetIDs.allSatisfy { $0 != nil }, "每格都有照片（不引入白格子）")
        XCTAssertEqual(perf.report().row(.generateTotal)?.count, 1, "性能页「生成·总计」只有 1 条")
        XCTAssertNil(perf.report().row(.sharpnessProbe), "不再出现「清晰度探测」")
        XCTAssertFalse(perf.allSamples().contains { ($0.note ?? "").contains("重配") }, "不再出现「重配第 N 轮」")
        XCTAssertFalse(stages.get().contains(.checkingSharpness))
        let f = fractions.get()
        XCTAssertEqual(f, f.sorted(), "进度单调")

        // 结果与「无探测器」的旧路径（14ac550 等价）逐格相同：修复只提速，不改结果。
        let plain = try await GenerationRunner().run(target: try target(), snapshot: snap, settings: GenerationSettings(density: .coarse), seed: 7)
        XCTAssertEqual(p.cellAssetIDs, plain.cellAssetIDs)

        // 换一种拼法：同快照、同样只跑一次。
        let again = try await r.reshuffle(p, target: try target(), settings: GenerationSettings(density: .coarse), seed: 8)
        XCTAssertFalse(again.lowRes.enabled)
        XCTAssertEqual(perf.report().row(.generateTotal)?.count, 2)
    }
}
