import Foundation
import XCTest
@testable import MosaicCore

final class FeatureFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mosaic-ff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeTable(count: Int, seed: UInt64 = 7, deleteEvery: Int = 0) -> FeatureTable {
        var rng = Xoshiro256StarStar(seed: seed)
        let vecs = syntheticVectors(count: count, seed: seed)
        let records = vecs.enumerated().map { i, v -> FeatureRecord in
            var flags: FeatureFlags = []
            let variance = rng.nextUnitFloat() * 0.002
            if variance < 0.0004 { flags.insert(.lowDetail) }
            if deleteEvery > 0, i % deleteEvery == 0 { flags.insert(.deleted) }
            return FeatureRecord(vector: v, lightnessVariance: variance, aspectRatio: 0.5 + rng.nextUnitFloat(), flags: flags)
        }
        return FeatureTable(records: records)
    }

    private func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }
    private func put(_ b: [UInt8], _ url: URL) throws { try Data(b).write(to: url) }

    /// 修改头部字段后重算头部 CRC（模拟"合法但版本不同"的文件）。
    private func patchHeader(_ b: inout [UInt8], _ body: (inout [UInt8]) -> Void) {
        body(&b)
        let crc = CRC32.checksum(b[0..<56])
        withUnsafeBytes(of: crc.littleEndian) { for (i, x) in $0.enumerated() { b[56 + i] = x } }
    }

    // MARK: CRC

    func testCRC32ReferenceVectors() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum([UInt8]()), 0)
        XCTAssertEqual(CRC32.checksum(Array("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
        var inc = CRC32()
        inc.update(Array("12345".utf8))
        inc.update(Array("6789".utf8))
        XCTAssertEqual(inc.value, 0xCBF4_3926)
    }

    // MARK: 往返

    func testRoundTripMultipleChunks() throws {
        let t = makeTable(count: 50, deleteEvery: 9)
        let url = dir.appendingPathComponent("features.bin")
        try FeatureFile.write(t, to: url, chunkSize: 16)
        let r = try FeatureFile.read(from: url)
        XCTAssertEqual(r.status, .intact)
        XCTAssertEqual(r.table, t)
        XCTAssertEqual(r.rowsToRebuild, 50..<50)
        XCTAssertEqual(r.header.recordCount, 50)
        XCTAssertEqual(r.header.dimension, 12)
        XCTAssertEqual(r.header.chunkSize, 16)
        XCTAssertEqual(r.header.featureVersion, MosaicCoreInfo.featureVersion)
        XCTAssertEqual(r.header.tombstoneCount, t.tombstoneCount)
        XCTAssertEqual(try bytes(url).count, FeatureFileFormat.fileSize(recordCount: 50, dimension: 12, chunkSize: 16))
        XCTAssertEqual(try FeatureFile.readHeader(from: url), r.header)
        // 与 FeatureMatrix(SoA) 对接：逐行一致，可直接交给内核。
        for i in [0, 15, 16, 49] { XCTAssertEqual(r.table.matrix.row(i), t.matrix.row(i)) }
        XCTAssertEqual(try ScalarSIMDKernel().topK(queries: t.matrix.subset(3), candidates: r.table.matrix, k: 1).indices(forQuery: 0), [3])
    }

    func testRoundTripChunkBoundariesAndEmpty() throws {
        for n in [0, 1, 15, 16, 17, 32] {
            let t = makeTable(count: n, seed: UInt64(n))
            let b = try FeatureFile.encode(t, chunkSize: 16)
            let r = try b.withUnsafeBytes { try FeatureFile.decode($0) }
            XCTAssertEqual(r.table, t, "n=\(n)")
            XCTAssertEqual(r.status, .intact)
        }
    }

    func testEncodingIsDeterministicAndLittleEndian() throws {
        let t = makeTable(count: 3)
        let a = try FeatureFile.encode(t), b = try FeatureFile.encode(t)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Array(a[0..<8]), FeatureFileFormat.magic)
        XCTAssertEqual(a[8], 1); XCTAssertEqual(a[9], 0)          // formatVersion = 1 (LE)
        XCTAssertEqual(a[20], 3)                                  // recordCount
        // 第一个特征值：维度 0、记录 0
        let v = Float(bitPattern: UInt32(a[64]) | UInt32(a[65]) << 8 | UInt32(a[66]) << 16 | UInt32(a[67]) << 24)
        XCTAssertEqual(v, t.matrix.value(dimension: 0, index: 0))
    }

    // MARK: 版本与头部错误（→ 丢弃重建）

    func testFeatureVersionMismatch() throws {
        let url = dir.appendingPathComponent("features.bin")
        try FeatureFile.write(makeTable(count: 5), to: url, featureVersion: 99)
        XCTAssertThrowsError(try FeatureFile.read(from: url)) { e in
            XCTAssertEqual(e as? FeatureFileError, .featureVersionMismatch(found: 99, expected: MosaicCoreInfo.featureVersion))
            XCTAssertEqual((e as? FeatureFileError)?.recommendedRecovery, .discardAndRebuild)
        }
        // 即便宽松模式也不能"保留前缀"：特征定义变了，旧值无意义。
        XCTAssertThrowsError(try FeatureFile.read(from: url, recovery: .keepValidPrefix))
        XCTAssertNoThrow(try FeatureFile.read(from: url, expectedFeatureVersion: 99))
    }

    func testUnsupportedFormatVersion() throws {
        var b = try FeatureFile.encode(makeTable(count: 5))
        patchHeader(&b) { $0[8] = 2 }
        XCTAssertThrowsError(try b.withUnsafeBytes { try FeatureFile.decode($0) }) { e in
            XCTAssertEqual(e as? FeatureFileError, .unsupportedFormatVersion(found: 2, supported: 1))
        }
    }

    func testHeaderCorruptionAndBadMagic() throws {
        var b = try FeatureFile.encode(makeTable(count: 5))
        b[20] ^= 0xFF   // 改记录数但不重算 CRC
        XCTAssertThrowsError(try b.withUnsafeBytes { try FeatureFile.decode($0) }) { e in
            guard case .headerChecksumMismatch = e as? FeatureFileError else { return XCTFail("\(e)") }
            XCTAssertEqual((e as? FeatureFileError)?.recommendedRecovery, .discardAndRebuild)
        }
        var m = try FeatureFile.encode(makeTable(count: 5))
        m[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try m.withUnsafeBytes { try FeatureFile.decode($0) }) { XCTAssertEqual($0 as? FeatureFileError, .badMagic) }
        let short = [UInt8](repeating: 0, count: 10)
        XCTAssertThrowsError(try short.withUnsafeBytes { try FeatureFile.decode($0) }) {
            XCTAssertEqual($0 as? FeatureFileError, .tooShortForHeader(size: 10))
        }
        XCTAssertThrowsError(try FeatureFile.read(from: dir.appendingPathComponent("nope.bin"))) {
            XCTAssertEqual($0 as? FeatureFileError, .fileNotFound)
        }
    }

    func testIncompatibleColorSpaceOrDimension() throws {
        let b = try FeatureFile.encode(makeTable(count: 4), colorSpace: .cielab)
        XCTAssertThrowsError(try b.withUnsafeBytes { try FeatureFile.decode($0) }) { e in
            guard case .incompatibleLayout = e as? FeatureFileError else { return XCTFail("\(e)") }
        }
        XCTAssertNoThrow(try b.withUnsafeBytes { try FeatureFile.decode($0, expectedColorSpace: .cielab) })
        XCTAssertThrowsError(try b.withUnsafeBytes { try FeatureFile.decode($0, expectedDimension: 9, expectedColorSpace: .cielab) })
    }

    // MARK: 截断 / 校验失败（→ 保留可用前缀）

    func testTruncationKeepsValidPrefix() throws {
        let t = makeTable(count: 50)
        let url = dir.appendingPathComponent("features.bin")
        try FeatureFile.write(t, to: url, chunkSize: 16)
        let full = try bytes(url)
        try put(Array(full.dropLast(10)), url)

        XCTAssertThrowsError(try FeatureFile.read(from: url, recovery: .discardAndRebuild)) { e in
            XCTAssertEqual(e as? FeatureFileError, .truncated(expectedBytes: full.count, actualBytes: full.count - 10))
            XCTAssertEqual((e as? FeatureFileError)?.recommendedRecovery, .keepValidPrefix)
        }
        let r = try FeatureFile.read(from: url, recovery: .keepValidPrefix)
        XCTAssertEqual(r.table.count, 48)   // 3 个完整块
        XCTAssertEqual(r.rowsToRebuild, 48..<50)
        XCTAssertEqual(r.status, .recoveredPrefix(reason: .truncated(expectedBytes: full.count, actualBytes: full.count - 10),
                                                  declaredRecordCount: 50))
        for i in 0..<48 { XCTAssertEqual(r.table.record(i), t.record(i)) }

        // 截到只剩头部：前缀为 0 行，全部重算。
        try put(Array(full.prefix(64)), url)
        let r0 = try FeatureFile.read(from: url)
        XCTAssertEqual(r0.table.count, 0)
        XCTAssertEqual(r0.rowsToRebuild, 0..<50)
    }

    func testChunkChecksumFailureKeepsPrefixBeforeBadChunk() throws {
        let t = makeTable(count: 50)
        var b = try FeatureFile.encode(t, chunkSize: 16)
        let chunkBytes = 16 * FeatureFileFormat.bytesPerRecord(dimension: 12) + 4
        b[64 + chunkBytes + 100] ^= 0x01   // 第 1 块内的一位翻转
        XCTAssertThrowsError(try b.withUnsafeBytes { try FeatureFile.decode($0, recovery: .discardAndRebuild) }) {
            XCTAssertEqual($0 as? FeatureFileError, .chunkChecksumMismatch(chunk: 1))
        }
        let r = try b.withUnsafeBytes { try FeatureFile.decode($0) }
        XCTAssertEqual(r.table.count, 16)
        XCTAssertEqual(r.rowsToRebuild, 16..<50)
        for i in 0..<16 { XCTAssertEqual(r.table.record(i), t.record(i)) }

        // 块 CRC 字段本身损坏也能识别。
        var c = try FeatureFile.encode(t, chunkSize: 16)
        c[64 + chunkBytes - 1] ^= 0x80
        XCTAssertEqual(try c.withUnsafeBytes { try FeatureFile.decode($0) }.table.count, 0)
    }

    func testTrailingBytes() throws {
        let t = makeTable(count: 10)
        let b = try FeatureFile.encode(t) + [1, 2, 3]
        XCTAssertThrowsError(try b.withUnsafeBytes { try FeatureFile.decode($0, recovery: .discardAndRebuild) }) {
            XCTAssertEqual($0 as? FeatureFileError, .trailingBytes(count: 3))
        }
        let r = try b.withUnsafeBytes { try FeatureFile.decode($0) }
        XCTAssertEqual(r.table, t)
        XCTAssertTrue(r.rowsToRebuild.isEmpty)
    }

    // MARK: 原子写入

    func testAtomicWriteReplacesAndLeavesNoTempFiles() throws {
        let url = dir.appendingPathComponent("features.bin")
        try FeatureFile.write(makeTable(count: 10, seed: 1), to: url)
        let t2 = makeTable(count: 20, seed: 2)
        try FeatureFile.write(t2, to: url)
        XCTAssertEqual(try FeatureFile.read(from: url).table, t2)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["features.bin"])
    }

    func testFailedWriteKeepsOldFile() throws {
        let url = dir.appendingPathComponent("features.bin")
        let t = makeTable(count: 10)
        try FeatureFile.write(t, to: url)
        // 目标所在目录不存在 → 临时文件都建不了，抛 io，旧文件不受影响。
        let bad = dir.appendingPathComponent("missing/features.bin")
        XCTAssertThrowsError(try FeatureFile.write(t, to: bad)) { e in
            guard case .io = e as? FeatureFileError else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(try FeatureFile.read(from: url).table, t)
    }

    // MARK: 大文件

    func testLargeFile50kRecords() throws {
        let n = 50_000
        let t = makeTable(count: n, seed: 42, deleteEvery: 97)
        let url = dir.appendingPathComponent("features.bin")
        let t0 = DispatchTime.now().uptimeNanoseconds
        try FeatureFile.write(t, to: url)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let r = try FeatureFile.read(from: url)
        let t2 = DispatchTime.now().uptimeNanoseconds
        let size = try bytes(url).count
        XCTAssertEqual(size, FeatureFileFormat.fileSize(recordCount: n, dimension: 12, chunkSize: FeatureFileFormat.defaultChunkSize))
        XCTAssertEqual(r.status, .intact)
        XCTAssertEqual(r.table, t)
        print(String(format: "[bench] features.bin %d records = %.2f MB; write %.1f ms, mmap read+verify %.1f ms",
                     n, Double(size) / 1_048_576, Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6))
    }

    // MARK: tombstone / 压缩

    func testTombstoneAndCompaction() throws {
        var t = makeTable(count: 20)
        XCTAssertFalse(t.needsCompaction)
        for i in [0, 3, 4, 10, 19] { t.markDeleted(i) }
        XCTAssertEqual(t.tombstoneCount, 5)
        XCTAssertEqual(t.holeRatio, 0.25)
        XCTAssertTrue(t.needsCompaction)
        XCTAssertEqual(t.liveMask.setCount, 15)
        let (c, map) = t.compacted()
        XCTAssertEqual(c.count, 15)
        XCTAssertEqual(c.tombstoneCount, 0)
        XCTAssertNil(map[0]); XCTAssertEqual(map[1], 0); XCTAssertEqual(map[5], 2); XCTAssertNil(map[19])
        for (old, new) in map.enumerated() {
            if let new { XCTAssertEqual(c.record(new), t.record(old)) }
        }
        // 4/20 = 20% 不触发（方案：> 20%）
        var u = makeTable(count: 20)
        for i in 0..<4 { u.markDeleted(i) }
        XCTAssertFalse(u.needsCompaction)
    }

    func testAssignerSkipsTombstones() throws {
        var t = makeTable(count: 300, seed: 9)
        for i in stride(from: 0, to: 300, by: 2) { t.markDeleted(i) }
        let grid = try MosaicGrid(columns: 10, rows: 8)
        let cells = FeatureMatrix(vectors: syntheticVectors(count: grid.cellCount, seed: 10))
        let a = try GreedyAssigner().assign(grid: grid, cellFeatures: cells, table: t)
        XCTAssertTrue(a.tiles.allSatisfy { $0 % 2 == 1 })
        XCTAssertEqual(a.statistics.availableCandidates, 150)
        XCTAssertThrowsError(try FeatureTable(matrix: t.matrix, lightnessVariance: [1], aspectRatio: t.aspectRatio, flags: t.flags))
    }
}
