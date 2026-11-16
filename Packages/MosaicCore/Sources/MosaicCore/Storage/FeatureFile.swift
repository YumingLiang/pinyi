import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `features.bin` 二进制格式（技术方案 v0.2 §2.3，细节见 CHANGES.md「features.bin 格式 v1」）。
///
/// 全部小端。布局：
/// ```
/// [Header 64 B]
/// [Chunk 0][Chunk 1]...            每块最多 chunkSize 条记录，块内 SoA：
///   dim × r × Float32               特征第 d 维的 r 个值依次排列
///   r × Float32                     亮度方差
///   r × Float32                     宽高比
///   r × UInt32                      flags（含 tombstone）
///   UInt32                          本块 CRC32（覆盖本块以上全部字节）
/// ```
/// 分块是为了"保留可用前缀"：截断或某块校验失败时，前面完好的块仍可用，
/// 行号保持不变，调用方只需对 `validRecordCount` 之后的行重算。
public enum FeatureFileFormat {
    /// 文件魔数 `"PMFEAT\0\0"`。
    public static let magic: [UInt8] = Array("PMFEAT".utf8) + [0, 0]
    /// 当前容器格式版本（布局变化时 +1）。
    public static let formatVersion: UInt16 = 1
    /// 头部长度（字节）。
    public static let headerSize = 64
    /// 默认每块记录数。
    public static let defaultChunkSize = 4096

    /// 每条记录在块内占用的字节数（不含块 CRC）。
    public static func bytesPerRecord(dimension: Int) -> Int { (dimension + 3) * 4 }

    /// 指定记录数时整个文件的字节数。
    public static func fileSize(recordCount: Int, dimension: Int, chunkSize: Int) -> Int {
        guard recordCount > 0 else { return headerSize }
        let chunks = (recordCount + chunkSize - 1) / chunkSize
        return headerSize + recordCount * bytesPerRecord(dimension: dimension) + chunks * 4
    }
}

/// `features.bin` 头部。
public struct FeatureFileHeader: Sendable, Equatable {
    /// 容器格式版本。
    public var formatVersion: UInt16
    /// 特征定义版本（`MosaicCoreInfo.featureVersion`），不一致时方案要求全部特征重算（§2.5）。
    public var featureVersion: UInt32
    /// 特征维度（当前固定 12）。
    public var dimension: Int
    /// 记录数（含 tombstone）。
    public var recordCount: Int
    /// 每块记录数。
    public var chunkSize: Int
    /// 写入时的颜色空间。
    public var colorSpace: FeatureColorSpace
    /// 写入时 tombstone 行数（冗余字段，便于不读正文就判断是否需要压缩）。
    public var tombstoneCount: Int
}

/// 读取 `features.bin` 时的错误。每种都对应明确的恢复动作（见 `recommendedRecovery`）。
public enum FeatureFileError: Error, Equatable, Sendable {
    /// 文件不存在。
    case fileNotFound
    /// 文件比头部还短。
    case tooShortForHeader(size: Int)
    /// 魔数不对（不是本 App 的特征文件）。
    case badMagic
    /// 头部 CRC 不符。
    case headerChecksumMismatch(expected: UInt32, actual: UInt32)
    /// 容器格式版本不支持。
    case unsupportedFormatVersion(found: UInt16, supported: UInt16)
    /// 特征定义版本不一致。
    case featureVersionMismatch(found: UInt32, expected: UInt32)
    /// 维度或颜色空间与期望不符。
    case incompatibleLayout(String)
    /// 文件被截断：按头部应有 `expectedBytes`，实际 `actualBytes`。
    case truncated(expectedBytes: Int, actualBytes: Int)
    /// 第 `chunk` 块（从 0 起）CRC 不符。
    case chunkChecksumMismatch(chunk: Int)
    /// 文件尾部有多余字节。
    case trailingBytes(count: Int)
    /// 读写 I/O 失败。
    case io(String)

    /// 推荐的恢复动作。
    public var recommendedRecovery: FeatureFileRecovery {
        switch self {
        case .truncated, .chunkChecksumMismatch, .trailingBytes:
            return .keepValidPrefix
        case .fileNotFound, .tooShortForHeader, .badMagic, .headerChecksumMismatch,
             .unsupportedFormatVersion, .featureVersionMismatch, .incompatibleLayout, .io:
            return .discardAndRebuild
        }
    }
}

/// 损坏恢复策略。
public enum FeatureFileRecovery: Sendable, Equatable {
    /// 丢弃整个文件，按方案 §2.5 全量 diff 重建（特征可由 64px 图集重算，不必访问 PhotoKit）。
    case discardAndRebuild
    /// 保留通过校验的前缀块，仅重算其后的行。
    case keepValidPrefix
}

/// 读取结果。
public struct FeatureFileReadResult: Sendable, Equatable {
    /// 读取状态。
    public enum Status: Sendable, Equatable {
        /// 完整、全部校验通过。
        case intact
        /// 文件局部损坏，只保留了前 `table.count` 行；`reason` 为原因，`declaredRecordCount` 为头部记录数。
        case recoveredPrefix(reason: FeatureFileError, declaredRecordCount: Int)
    }
    /// 头部。
    public var header: FeatureFileHeader
    /// 特征表（恢复时只含有效前缀）。
    public var table: FeatureTable
    /// 状态。
    public var status: Status

    /// 需要重算的行号区间（完好时为空）。
    public var rowsToRebuild: Range<Int> {
        switch status {
        case .intact: return table.count..<table.count
        case .recoveredPrefix(_, let declared): return table.count..<max(table.count, declared)
        }
    }
}

/// `features.bin` 读写。
public enum FeatureFile {
    // MARK: 写

    /// 编码为字节（不落盘）。
    public static func encode(_ table: FeatureTable, colorSpace: FeatureColorSpace = .oklab,
                              featureVersion: UInt32 = MosaicCoreInfo.featureVersion,
                              chunkSize: Int = FeatureFileFormat.defaultChunkSize) throws -> [UInt8] {
        guard chunkSize > 0 else { throw MosaicError.invalidConfiguration("chunkSize 必须 > 0") }
        let n = table.count
        let dim = table.matrix.dimension
        guard n <= Int(UInt32.max), dim <= Int(UInt16.max) else {
            throw MosaicError.invalidConfiguration("记录数或维度超出格式上限")
        }
        var out = [UInt8]()
        out.reserveCapacity(FeatureFileFormat.fileSize(recordCount: n, dimension: dim, chunkSize: chunkSize))

        // Header
        out += FeatureFileFormat.magic                              // 0..<8
        out.appendLE(FeatureFileFormat.formatVersion)                // 8
        out.appendLE(UInt16(FeatureFileFormat.headerSize))          // 10
        out.appendLE(featureVersion)                                // 12
        out.appendLE(UInt32(dim))                                   // 16
        out.appendLE(UInt32(n))                                     // 20
        out.appendLE(UInt32(chunkSize))                             // 24
        out.append(colorSpace == .oklab ? 0 : 1)                    // 28
        out += [0, 0, 0]                                            // 29..<32 保留
        out.appendLE(UInt32(table.tombstoneCount))                  // 32
        out += [UInt8](repeating: 0, count: 56 - out.count)         // 36..<56 保留
        out.appendLE(CRC32.checksum(out))                           // 56 头部 CRC（0..<56）
        out += [0, 0, 0, 0]                                         // 60..<64 保留

        // Chunks
        let storage = table.matrix.storage
        var start = 0
        while start < n {
            let end = min(n, start + chunkSize)
            let chunkBegin = out.count
            for d in 0..<dim {
                let base = d * n
                for i in start..<end { out.appendLE(storage[base + i].bitPattern) }
            }
            for i in start..<end { out.appendLE(table.lightnessVariance[i].bitPattern) }
            for i in start..<end { out.appendLE(table.aspectRatio[i].bitPattern) }
            for i in start..<end { out.appendLE(table.flags[i].rawValue) }
            let crc = out.withUnsafeBytes { CRC32.checksum(UnsafeRawBufferPointer(rebasing: $0[chunkBegin...])) }
            out.appendLE(crc)
            start = end
        }
        return out
    }

    /// 原子写入：同目录临时文件 → fsync → `rename(2)` 覆盖。任何一步失败都不会留下半个目标文件。
    public static func write(_ table: FeatureTable, to url: URL, colorSpace: FeatureColorSpace = .oklab,
                             featureVersion: UInt32 = MosaicCoreInfo.featureVersion,
                             chunkSize: Int = FeatureFileFormat.defaultChunkSize) throws {
        let bytes = try encode(table, colorSpace: colorSpace, featureVersion: featureVersion, chunkSize: chunkSize)
        try atomicWrite(bytes, to: url)
    }

    /// 原子写入任意字节（测试与压缩重写共用）。
    static func atomicWrite(_ bytes: [UInt8], to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw FeatureFileError.io("open 临时文件失败 errno=\(errno)") }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        let written: Bool = bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let r = posixWrite(fd, raw.baseAddress! + off, raw.count - off)
                if r < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                off += r
            }
            return true
        }
        guard written, fsync(fd) == 0 else {
            close(fd)
            throw FeatureFileError.io("写临时文件失败 errno=\(errno)")
        }
        guard close(fd) == 0 else { throw FeatureFileError.io("close 失败 errno=\(errno)") }
        guard rename(tmp.path, url.path) == 0 else { throw FeatureFileError.io("rename 失败 errno=\(errno)") }
        ok = true
        // 尽力 fsync 目录，保证 rename 持久化；失败不影响正确性。
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
    }

    // MARK: 读

    /// 从磁盘读取（mmap：`Data(contentsOf:options: .alwaysMapped)`）。
    /// - Parameters:
    ///   - recovery: `.discardAndRebuild` = 严格模式，任何损坏都抛错；`.keepValidPrefix` = 截断/块校验失败时返回有效前缀。
    ///     头部损坏、版本不匹配等无论哪种策略都抛错（必须重建）。
    ///   - expectedDimension / expectedColorSpace: 与当前引擎不一致时抛 `incompatibleLayout`。
    public static func read(from url: URL, recovery: FeatureFileRecovery = .keepValidPrefix,
                            expectedFeatureVersion: UInt32 = MosaicCoreInfo.featureVersion,
                            expectedDimension: Int = FeatureVector.dimension,
                            expectedColorSpace: FeatureColorSpace = .oklab) throws -> FeatureFileReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FeatureFileError.fileNotFound }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw FeatureFileError.io("\(error)")
        }
        return try data.withUnsafeBytes { raw in
            try decode(raw, recovery: recovery, expectedFeatureVersion: expectedFeatureVersion,
                       expectedDimension: expectedDimension, expectedColorSpace: expectedColorSpace)
        }
    }

    /// 只读头部（不校验正文），用于启动时快速判断版本/是否需要压缩。
    public static func readHeader(from url: URL) throws -> FeatureFileHeader {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FeatureFileError.fileNotFound }
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw FeatureFileError.io("\(error)") }
        return try data.withUnsafeBytes { try parseHeader($0) }
    }

    /// 从内存字节解码（与 `read` 相同的校验与恢复逻辑）。
    public static func decode(_ raw: UnsafeRawBufferPointer, recovery: FeatureFileRecovery = .keepValidPrefix,
                              expectedFeatureVersion: UInt32 = MosaicCoreInfo.featureVersion,
                              expectedDimension: Int = FeatureVector.dimension,
                              expectedColorSpace: FeatureColorSpace = .oklab) throws -> FeatureFileReadResult {
        let header = try parseHeader(raw)
        guard header.featureVersion == expectedFeatureVersion else {
            throw FeatureFileError.featureVersionMismatch(found: header.featureVersion, expected: expectedFeatureVersion)
        }
        guard header.dimension == expectedDimension else {
            throw FeatureFileError.incompatibleLayout("维度 \(header.dimension) ≠ 期望 \(expectedDimension)")
        }
        guard header.colorSpace == expectedColorSpace else {
            throw FeatureFileError.incompatibleLayout("颜色空间 \(header.colorSpace) ≠ 期望 \(expectedColorSpace)")
        }

        let n = header.recordCount, dim = header.dimension, cs = header.chunkSize
        let expectedBytes = FeatureFileFormat.fileSize(recordCount: n, dimension: dim, chunkSize: cs)
        let bpr = FeatureFileFormat.bytesPerRecord(dimension: dim)

        // 先逐块校验，确定有效前缀长度。
        var validRecords = 0
        var failure: FeatureFileError?
        var offset = FeatureFileFormat.headerSize
        var chunkIndex = 0
        while validRecords < n {
            let r = min(cs, n - validRecords)
            let len = r * bpr
            guard offset + len + 4 <= raw.count else {
                failure = .truncated(expectedBytes: expectedBytes, actualBytes: raw.count)
                break
            }
            let crc = CRC32.checksum(UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + len)]))
            let stored = raw.loadUnaligned(fromByteOffset: offset + len, as: UInt32.self).littleEndian
            guard crc == stored else {
                failure = .chunkChecksumMismatch(chunk: chunkIndex)
                break
            }
            validRecords += r
            offset += len + 4
            chunkIndex += 1
        }
        if failure == nil, raw.count > expectedBytes {
            failure = .trailingBytes(count: raw.count - expectedBytes)
        }
        if let failure, recovery == .discardAndRebuild { throw failure }

        // 解码有效前缀：块内 SoA → 全局 SoA（一次拷贝，5 万条约 3 MB，<几 ms）。
        let m = validRecords
        var soa = [Float](repeating: 0, count: dim * m)
        var variance = [Float](repeating: 0, count: m)
        var aspect = [Float](repeating: 0, count: m)
        var flags = [FeatureFlags](repeating: [], count: m)
        offset = FeatureFileFormat.headerSize
        var start = 0
        while start < m {
            let r = min(cs, m - start)
            var p = offset
            for d in 0..<dim {
                let base = d * m + start
                for i in 0..<r {
                    soa[base + i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: p, as: UInt32.self).littleEndian)
                    p += 4
                }
            }
            for i in 0..<r {
                variance[start + i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: p, as: UInt32.self).littleEndian); p += 4
            }
            for i in 0..<r {
                aspect[start + i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: p, as: UInt32.self).littleEndian); p += 4
            }
            for i in 0..<r {
                flags[start + i] = FeatureFlags(rawValue: raw.loadUnaligned(fromByteOffset: p, as: UInt32.self).littleEndian); p += 4
            }
            offset = p + 4
            start += r
        }
        let matrix = try FeatureMatrix(dimension: dim, count: m, soa: soa)
        let table = FeatureTable(uncheckedMatrix: matrix, lightnessVariance: variance, aspectRatio: aspect, flags: flags)
        let status: FeatureFileReadResult.Status = failure.map { .recoveredPrefix(reason: $0, declaredRecordCount: n) } ?? .intact
        return FeatureFileReadResult(header: header, table: table, status: status)
    }

    static func parseHeader(_ raw: UnsafeRawBufferPointer) throws -> FeatureFileHeader {
        guard raw.count >= FeatureFileFormat.headerSize else { throw FeatureFileError.tooShortForHeader(size: raw.count) }
        guard Array(raw[0..<8]) == FeatureFileFormat.magic else { throw FeatureFileError.badMagic }
        func u16(_ o: Int) -> UInt16 { raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian }
        func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian }
        let stored = u32(56)
        let actual = CRC32.checksum(UnsafeRawBufferPointer(rebasing: raw[0..<56]))
        guard stored == actual else { throw FeatureFileError.headerChecksumMismatch(expected: stored, actual: actual) }
        let version = u16(8)
        guard version == FeatureFileFormat.formatVersion else {
            throw FeatureFileError.unsupportedFormatVersion(found: version, supported: FeatureFileFormat.formatVersion)
        }
        guard Int(u16(10)) == FeatureFileFormat.headerSize else {
            throw FeatureFileError.incompatibleLayout("头部长度 \(u16(10))")
        }
        let chunk = Int(u32(24))
        guard chunk > 0 else { throw FeatureFileError.incompatibleLayout("chunkSize = 0") }
        let csByte = raw[28]
        guard csByte <= 1 else { throw FeatureFileError.incompatibleLayout("未知颜色空间 \(csByte)") }
        return FeatureFileHeader(formatVersion: version, featureVersion: u32(12), dimension: Int(u32(16)),
                                 recordCount: Int(u32(20)), chunkSize: chunk,
                                 colorSpace: csByte == 0 ? .oklab : .cielab, tombstoneCount: Int(u32(32)))
    }
}

/// libc `write(2)`（避开与 `FeatureFile.write` 的重名）。
@inline(__always)
private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(fd, buf, n)
    #elseif canImport(Musl)
    return Musl.write(fd, buf, n)
    #else
    return Darwin.write(fd, buf, n)
    #endif
}

extension Array where Element == UInt8 {
    @inline(__always)
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
