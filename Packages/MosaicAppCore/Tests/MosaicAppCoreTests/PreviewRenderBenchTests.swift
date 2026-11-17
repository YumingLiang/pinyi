import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 预览绘制改前/改后对照，以及生成总耗时（证明本 PR 未改生成链路）。
/// 只在 `MOSAIC_BENCH=1` 时运行；Linux debug 数字不能代替真机「预览绘制」和 SwiftUI 显示耗时。
final class PreviewRenderBenchTests: XCTestCase {
    static func legacyCellPixels(columns: Int, rows: Int) -> Int {
        max(8, min(32, 2400 / max(max(columns, rows), 1)))
    }

    /// 把已准备好的正方形格子像素按行优先写入预览位图（最近邻缩放到 cellPixels）。
    /// 用来在 Linux 上估算「缩略图格点合成」的像素量；App 层实际是 CGContext.draw，路径不同。
    static func blitTiles(columns: Int, rows: Int, cellPixels: Int, tiles: [PixelBuffer]) throws -> PixelBuffer {
        let w = columns * cellPixels, h = rows * cellPixels
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let n = max(tiles.count, 1)
        for cell in 0..<(columns * rows) {
            let tile = tiles[cell % n]
            let cx = cell % columns, cy = cell / columns
            let tw = max(tile.width, 1), th = max(tile.height, 1)
            for y in 0..<cellPixels {
                let sy = y * th / cellPixels
                var o = ((cy * cellPixels + y) * w + cx * cellPixels) * 4
                for x in 0..<cellPixels {
                    let sx = x * tw / cellPixels
                    let so = sy * tile.bytesPerRow + sx * 4
                    bytes[o] = tile.bytes[so]
                    bytes[o + 1] = tile.bytes[so + 1]
                    bytes[o + 2] = tile.bytes[so + 2]
                    bytes[o + 3] = 255
                    o += 4
                }
            }
        }
        return try PixelBuffer(width: w, height: h, bytes: bytes)
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    static func time(_ n: Int, _ body: () throws -> Void) throws -> (median: Double, last: Double) {
        var samples: [Double] = []
        // 预热 1 次，不计
        try body()
        for _ in 0..<n {
            let t0 = Date().timeIntervalSince1970
            try body()
            samples.append(Date().timeIntervalSince1970 - t0)
        }
        return (median(samples), samples.last ?? 0)
    }

    func testBenchPreviewDrawAndGeneration() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MOSAIC_BENCH"] == "1", "设 MOSAIC_BENCH=1 运行")

        let cases: [(name: String, density: Density, columns: Int, rows: Int, assets: Int)] = [
            ("粗 40×30 / 300 张", .coarse, 40, 30, 300),
            ("中 80×60 / 300 张", .medium, 80, 60, 300),
            ("细 120×90 / 300 张", .fine, 120, 90, 300),
        ]

        for c in cases {
            let records = (0..<c.assets).map { i in
                FeatureRecord(vector: FeatureVector(uniform: SIMD3(0.3 + Float(i % 50) * 0.004,
                                                                   0.02 - Float(i % 7) * 0.002,
                                                                   -0.01 + Float(i % 5) * 0.003)),
                              lightnessVariance: 0.01)
            }
            let table = FeatureTable(records: records)
            let target = try PixelBuffer.solid(width: 160, height: 120, red: 180, green: 40, blue: 50)
            let genT0 = Date().timeIntervalSince1970
            let g = try await MosaicPipeline().generate(target: target, density: c.density, table: table, seed: 9)
            let genSeconds = Date().timeIntervalSince1970 - genT0
            XCTAssertEqual(g.layout.columns, c.columns)
            XCTAssertEqual(g.layout.rows, c.rows)

            let oldCP = Self.legacyCellPixels(columns: c.columns, rows: c.rows)
            let newCP = PreviewImageLimits.cellPixels(columns: c.columns, rows: c.rows)

            let colorOld = try Self.time(3) { _ = try PreviewRenderer.render(g, table: table, cellPixels: oldCP) }
            let colorNew = try Self.time(3) { _ = try PreviewRenderer.render(g, table: table, cellPixels: newCP) }

            // 64 张 128×128 占位缩略图循环铺格，模拟扫描显示图再写入格子（不含 PhotoKit）
            var thumbs: [PixelBuffer] = []
            thumbs.reserveCapacity(64)
            for i in 0..<64 {
                thumbs.append(try PixelBuffer.solid(width: 128, height: 128,
                                                    red: UInt8((i * 3) % 256),
                                                    green: UInt8((i * 7) % 256),
                                                    blue: UInt8((i * 11) % 256)))
            }
            let blitOld = try Self.time(2) { _ = try Self.blitTiles(columns: c.columns, rows: c.rows, cellPixels: oldCP, tiles: thumbs) }
            let blitNew = try Self.time(2) { _ = try Self.blitTiles(columns: c.columns, rows: c.rows, cellPixels: newCP, tiles: thumbs) }

            let oldBytes = c.columns * oldCP * c.rows * oldCP * 4
            let newBytes = PreviewImageLimits.rgbaByteCount(columns: c.columns, rows: c.rows)
            print(String(format: "[bench] %@  生成(MosaicPipeline) %.1f ms  格子 %d  素材 %d",
                         c.name, genSeconds * 1000, c.columns * c.rows, c.assets))
            print(String(format: "[bench]   色块预览  改前每格 %d px / %.1f MB  中位 %.1f ms；改后每格 %d px / %.1f MB  中位 %.1f ms",
                         oldCP, Double(oldBytes) / 1_048_576, colorOld.median * 1000,
                         newCP, Double(newBytes) / 1_048_576, colorNew.median * 1000))
            print(String(format: "[bench]   格点合成(软件拷贝, 128px 占位图)  改前中位 %.1f ms；改后中位 %.1f ms",
                         blitOld.median * 1000, blitNew.median * 1000))
        }

        // 与 GenerationRunner 同一条生成路径（含取样/匹配/分配记账），素材 300、中档 80×60
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let idx = PhotoIndex(directory: dir, library: FakePhotoLibrary(assetCount: 300), thumbnails: FakeThumbnails(),
                             backupExclusion: RecordingBackupExclusion(),
                             configuration: smallConfig(batch: 100, concurrency: 16, minRows: 1000))
        await idx.load()
        _ = try await idx.synchronize()
        let snap = try await idx.snapshot(for: .allPhotos)
        let target = try PixelBuffer.solid(width: 160, height: 120, red: 180, green: 40, blue: 50)
        let perf = PerfRecorder()
        let runner = GenerationRunner(perf: perf)
        // 预热一次
        _ = try await runner.run(target: target, snapshot: snap, settings: GenerationSettings(density: .medium), seed: 9)
        var times: [Double] = []
        for i in 0..<3 {
            let t0 = Date().timeIntervalSince1970
            _ = try await runner.run(target: target, snapshot: snap, settings: GenerationSettings(density: .medium), seed: UInt64(11 + i))
            times.append(Date().timeIntervalSince1970 - t0)
        }
        let r = perf.report()
        print(String(format: "[bench] GenerationRunner 中档 80×60 / 300 张  墙钟中位 %.1f ms（三次：%@）",
                     Self.median(times) * 1000,
                     times.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ")))
        if let total = r.row(.generateTotal) {
            print(String(format: "[bench]   generateTotal n=%d total=%.1f ms median=%.1f ms（含预热）",
                         total.count, total.totalSeconds * 1000, total.medianSeconds * 1000))
        }
        for phase in [PerfPhase.generateSampling, .generateMatching, .generateAssigning] {
            if let row = r.row(phase) {
                print(String(format: "[bench]   %@ median=%.1f ms", phase.rawValue, row.medianSeconds * 1000))
            }
        }
    }
}
