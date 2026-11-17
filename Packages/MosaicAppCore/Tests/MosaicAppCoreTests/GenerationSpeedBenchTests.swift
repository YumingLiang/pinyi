import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

/// 生成链路耗时基准（gen-perf-fix）。默认跳过，`PINYI_GEN_BENCH=1 swift test -c release --filter GenerationSpeedBenchTests` 手动跑。
///
/// - 「一次匹配」= 修复后生产路径（`GenerationRunner.production`，与 14ac550 的生成路径相同）：**实测**。
/// - 「d31925f 探测+重配」= 旧生产路径（注入 `LocalResolutionChecker`，8 并发，最多 3 轮重配 + 兜底补格）。
///   匹配 / 重配部分是**实测**；PhotoKit 逐张 `fetchAssets + requestImage(256, highQualityFormat)` 在 Linux 上跑不了，
///   用桩 `SimulatedLatencyProbe` 每次 `Task.sleep` 固定延迟**模拟**，不合格比例按资产 ID 哈希固定。
///   每次运行用新缓存（= 冷启动后第一次生成）。
/// 结果打印成 Markdown 表行（`BENCH|...`）。
final class GenerationSpeedBenchTests: XCTestCase {
    struct SimulatedLatencyProbe: LocalResolutionProbing {
        var latencyNanos: UInt64
        var unusablePercent: Int
        func probe(assetID: String, minPixelSize: Int) async -> LocalResolutionVerdict {
            try? await Task.sleep(nanoseconds: latencyNanos)
            let n = Int(assetID.dropFirst()) ?? 0
            return (n &* 2654435761) % 100 < unusablePercent ? .unusable(.inCloud) : .usable
        }
    }

    func target(w: Int, h: Int) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            bytes[o] = UInt8(x * 255 / (w - 1)); bytes[o + 1] = UInt8(y * 255 / (h - 1)); bytes[o + 2] = UInt8((x ^ y) & 255)
        } }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }

    func snapshot(assets: Int, dir: URL) async throws -> IndexSnapshot {
        let idx = PhotoIndex(directory: dir, library: FakePhotoLibrary(assetCount: assets), thumbnails: FakeThumbnails(),
                             backupExclusion: RecordingBackupExclusion(), configuration: smallConfig(batch: 200, concurrency: 32, minRows: 100_000))
        await idx.load()
        _ = try await idx.synchronize()
        return try await idx.snapshot(for: .allPhotos)
    }

    func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }

    func time(_ body: () async throws -> String) async rethrows -> (Double, String) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let note = try await body()
        return (Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9, note)
    }

    func testBenchGenerationPaths() async throws {
        guard ProcessInfo.processInfo.environment["PINYI_GEN_BENCH"] == "1" else { throw XCTSkip("PINYI_GEN_BENCH=1 才跑") }
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assetCounts = (ProcessInfo.processInfo.environment["PINYI_GEN_BENCH_N"] ?? "1000,3000").split(separator: ",").compactMap { Int($0) }
        let reps = 3
        let tgt = try target(w: 2048, h: 1536)
        print("BENCH|素材 N|密度|格子|路径|模拟每次请求|不合格比例|耗时中位数 s|探测次数|重配轮数")
        for n in assetCounts {
            let sub = dir.appendingPathComponent("n\(n)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let snap = try await snapshot(assets: n, dir: sub)
            for density in [DensityChoice.medium, .fine] {
                let settings = GenerationSettings(density: density)
                // 修复后 / 14ac550：一次匹配（实测）
                var ts: [Double] = []
                var cells = 0
                for i in 0..<reps {
                    let (t, _) = try await time {
                        let p = try await GenerationRunner.production(pipeline: MosaicPipeline(), perf: nil)
                            .run(target: tgt, snapshot: snap, settings: settings, seed: UInt64(i + 1))
                        cells = p.generation.layout.cellCount
                        return ""
                    }
                    ts.append(t)
                }
                print("BENCH|\(n)|\(density.rawValue)|\(cells)|修复后：一次匹配（实测）|—|—|\(String(format: "%.3f", median(ts)))|0|0")
                // d31925f：探测 + 重配（匹配实测 + 请求延迟模拟）
                for (ms, bad) in [(10, 0), (10, 30), (25, 30)] {
                    var ts2: [Double] = []
                    var probed = 0, rounds = 0
                    for i in 0..<reps {
                        let checker = LocalResolutionChecker(probe: SimulatedLatencyProbe(latencyNanos: UInt64(ms) * 1_000_000, unusablePercent: bad))
                        let r = GenerationRunner(pipeline: MosaicPipeline(), perf: nil, sharpness: checker)
                        let (t, _) = try await time {
                            let p = try await r.run(target: tgt, snapshot: snap, settings: settings, seed: UInt64(i + 1))
                            probed = p.lowRes.probedCount; rounds = p.lowRes.rematchRounds
                            return ""
                        }
                        ts2.append(t)
                    }
                    print("BENCH|\(n)|\(density.rawValue)|\(cells)|d31925f：探测+重配（匹配实测，请求模拟）|\(ms) ms|\(bad)%|\(String(format: "%.3f", median(ts2)))|\(probed)|\(rounds)")
                }
            }
        }
    }
}
