import Foundation
import XCTest
@testable import MosaicCore

/// 掩码为 nil 的路径（加 activeCells 之前的老路径）的结果摘要。
///
/// - 所有平台都把摘要打印到日志（`NIL-PATH-DIGEST …` 一行）。
/// - 跨提交的逐位金标准只在 x86_64 Linux 上比：金标准是在 x86_64 Linux 上用 fbc03fa 算的，
///   浮点在 arm64（iOS 模拟器 / Apple Silicon）上可能因 FMA、SIMD 归约顺序不同而差最低位，不能拿来比。
///   「传 nil 与传全 1 掩码结果完全相同」在所有平台都断言，见 `ActiveCellsTests`。
/// - 本文件只用 fbc03fa 就有的 API，可以原样拷到 fbc03fa 的 `Tests/MosaicCoreTests/` 下运行，
///   拿该平台上加掩码之前的摘要，与新 head 打印的值对照（步骤见 PR 说明）。
final class NilPathDigestTests: XCTestCase {
    static let goldenAssignLinuxX86: UInt64 = 15_918_930_707_374_718_768
    static let goldenPipelineLinuxX86: UInt64 = 17_248_742_613_598_977_437

    func testNilPathDigest() throws {
        let grid = try MosaicGrid(columns: 40, rows: 30)
        let lib = FeatureMatrix(vectors: syntheticVectors(count: 300, seed: 3))
        let cells = FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: 4))
        let a = try GreedyAssigner(configuration: AssignmentConfiguration(seed: 42))
            .assign(grid: grid, cellFeatures: cells, library: lib)

        let snap = try LibrarySnapshot(table: Self.table(500, seed: 11))
        let g = try MosaicPipeline().generate(target: Self.gradientTarget(), density: .coarse, snapshot: snap, seed: 7)

        let assignDigest = Self.digest(a), pipelineDigest = Self.digest(g.assignment)
        print("NIL-PATH-DIGEST platform=\(Self.platform) assign=\(assignDigest) pipeline=\(pipelineDigest)")
        XCTAssertEqual(a.tiles.count, grid.cellCount)
        XCTAssertFalse(g.assignment.tiles.contains(-1), "nil 路径每格都有照片")

        #if os(Linux) && arch(x86_64)
        XCTAssertEqual(assignDigest, Self.goldenAssignLinuxX86, "与 fbc03fa（x86_64 Linux）逐位一致")
        XCTAssertEqual(pipelineDigest, Self.goldenPipelineLinuxX86, "与 fbc03fa（x86_64 Linux）逐位一致")
        #endif
    }

    static var platform: String {
        var os = "other", arch = "other"
        #if os(Linux)
        os = "linux"
        #elseif os(iOS)
        os = "ios"
        #elseif os(macOS)
        os = "macos"
        #endif
        #if arch(x86_64)
        arch = "x86_64"
        #elseif arch(arm64)
        arch = "arm64"
        #endif
        return "\(os)-\(arch)"
    }

    static func gradientTarget(width: Int = 64, height: Int = 48) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                bytes[o] = UInt8((x * 4) & 255)
                bytes[o + 1] = UInt8((y * 5) & 255)
                bytes[o + 2] = UInt8(((x + y) * 2) & 255)
            }
        }
        return try PixelBuffer(width: width, height: height, bytes: bytes)
    }

    static func table(_ n: Int, seed: UInt64) -> FeatureTable {
        let records = syntheticVectors(count: n, seed: seed).enumerated().map { i, v in
            FeatureRecord(vector: v, lightnessVariance: Float(i % 7) * 0.0002, aspectRatio: 1)
        }
        return FeatureTable(records: records)
    }

    /// FNV‑1a：tiles、距离的位模式、回退级别、关键统计。
    static func digest(_ a: MosaicAssignment) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ v: UInt64) {
            var x = v
            for _ in 0..<8 {
                h ^= x & 0xff
                h = h &* 0x0000_0100_0000_01b3
                x >>= 8
            }
        }
        for t in a.tiles { mix(UInt64(bitPattern: Int64(t))) }
        for d in a.distances { mix(UInt64(d.bitPattern)) }
        for l in a.levels { mix(UInt64(l.rawValue)) }
        mix(UInt64(a.statistics.cellCount))
        mix(UInt64(bitPattern: Int64(a.statistics.resolvedCap ?? -1)))
        mix(UInt64(a.statistics.distinctTilesUsed))
        mix(UInt64(a.statistics.maxUses))
        return h
    }
}
