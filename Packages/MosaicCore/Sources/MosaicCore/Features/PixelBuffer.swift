/// 平台无关的 8 位四通道像素缓冲区（技术方案 §11.1 `PixelBuffer`）。
///
/// PhotoKit / CGImage → `PixelBuffer` 的转换放在 iOS 专属包中；本类型只描述内存布局。
/// Alpha 通道被忽略（按不透明处理）；若来源是预乘 Alpha 且含透明像素，需在平台层先合成到背景上。
public struct PixelBuffer: Sendable {
    /// 通道排列。
    public enum Layout: Sendable, Hashable {
        /// R, G, B, A（每像素 4 字节）。
        case rgba8
        /// B, G, R, A（iOS 上 `kCGImageAlphaPremultipliedFirst | byteOrder32Little` 的常见布局）。
        case bgra8
    }

    /// 宽度（像素）。
    public let width: Int
    /// 高度（像素）。
    public let height: Int
    /// 每行字节数（≥ width × 4，允许行尾填充）。
    public let bytesPerRow: Int
    /// 通道排列。
    public let layout: Layout
    /// 原始字节。
    public let bytes: [UInt8]

    /// 创建像素缓冲区。
    ///
    /// - Parameters:
    ///   - width: 宽度，必须 > 0。
    ///   - height: 高度，必须 > 0。
    ///   - bytesPerRow: 每行字节数，默认紧密排列 `width × 4`。
    ///   - layout: 通道排列，默认 `.rgba8`。
    ///   - bytes: 像素数据，长度至少 `bytesPerRow × (height − 1) + width × 4`。
    /// - Throws: `MosaicError.invalidPixelBuffer` 参数不合法时。
    public init(width: Int, height: Int, bytesPerRow: Int? = nil, layout: Layout = .rgba8, bytes: [UInt8]) throws {
        guard width > 0, height > 0 else {
            throw MosaicError.invalidPixelBuffer("width/height must be > 0 (got \(width)×\(height))")
        }
        let stride = bytesPerRow ?? width * 4
        guard stride >= width * 4 else {
            throw MosaicError.invalidPixelBuffer("bytesPerRow \(stride) < width×4 (\(width * 4))")
        }
        let required = stride * (height - 1) + width * 4
        guard bytes.count >= required else {
            throw MosaicError.invalidPixelBuffer("bytes.count \(bytes.count) < required \(required)")
        }
        self.width = width
        self.height = height
        self.bytesPerRow = stride
        self.layout = layout
        self.bytes = bytes
    }

    /// 便捷构造：整张图填充同一 sRGB 颜色（主要用于测试与合成数据）。
    public static func solid(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            bytes[i * 4] = red
            bytes[i * 4 + 1] = green
            bytes[i * 4 + 2] = blue
        }
        return try PixelBuffer(width: width, height: height, bytes: bytes)
    }

    /// 整张图的区域。
    public var fullRegion: PixelRegion {
        PixelRegion(x: 0, y: 0, width: width, height: height)
    }

    /// 居中正方形裁剪区域（边长 = min(宽, 高)），技术方案 §2.1「中心正方形裁剪」。
    public var centerSquare: PixelRegion {
        let side = min(width, height)
        return PixelRegion(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
    }

    /// 读取 (x, y) 处像素的 sRGB 8 位分量（不做越界检查以外的处理）。
    @inlinable
    public func rgb(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel out of bounds")
        let o = y * bytesPerRow + x * 4
        switch layout {
        case .rgba8: return (bytes[o], bytes[o + 1], bytes[o + 2])
        case .bgra8: return (bytes[o + 2], bytes[o + 1], bytes[o])
        }
    }
}

/// 像素坐标系下的矩形区域（原点左上，x 向右，y 向下）。
public struct PixelRegion: Hashable, Sendable {
    /// 左上角 x。
    public var x: Int
    /// 左上角 y。
    public var y: Int
    /// 宽度。
    public var width: Int
    /// 高度。
    public var height: Int

    /// 构造区域。
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 区域是否非空且完全位于给定缓冲区内。
    public func isValid(in buffer: PixelBuffer) -> Bool {
        width > 0 && height > 0 && x >= 0 && y >= 0 && x + width <= buffer.width && y + height <= buffer.height
    }
}
