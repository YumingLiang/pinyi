/// CRC-32（IEEE 802.3，反射多项式 0xEDB88320，初值/终值异或 0xFFFFFFFF），自实现、无依赖。
/// 与 zlib `crc32()` 结果一致；"123456789" → 0xCBF43926。
public struct CRC32: Sendable {
    /// 256 项查找表。
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    /// 创建累加器。
    public init() {}

    /// 追加数据。
    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var c = state
        CRC32.table.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        state = c
    }

    /// 追加字节数组。
    public mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        var c = state
        CRC32.table.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        state = c
    }

    /// 当前校验值。
    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    /// 一次性计算。
    public static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = CRC32()
        c.update(bytes)
        return c.value
    }

    /// 一次性计算（字节数组）。
    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c = CRC32()
        c.update(bytes)
        return c.value
    }
}
