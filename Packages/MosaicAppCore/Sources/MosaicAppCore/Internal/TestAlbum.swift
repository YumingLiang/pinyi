import MosaicCore

/// 「马赛克测试」相簿工具（技术方案 §11.5 第 9 点、决定 13）——**只在 `INTERNAL_TOOLS` 构建中由 App 层接入**。
///
/// 用途：在内测机相册里建「马赛克测试」相簿并写入合成图片，用于 1 万 / 5 万张扫描实测；测完一键删除。
/// ⚠️ 决定 13 仍待 AndyL 拍板：`ownerApproved` 为 false 时 UI 只显示说明、不提供"生成"按钮（删除始终可用，
/// 以便清理）。拍板同意后把 `ownerApproved` 改为 true 即可，无需改其他代码。
public enum TestAlbumPolicy {
    /// 决定 13 是否已获 AndyL 同意。
    public static let ownerApproved = false
    /// 相簿名（用户相册里可见；内部工具，不进文案表）。
    public static let albumTitle = "马赛克测试"
    /// 可选张数档（1 万验收线、5 万不闪退）。
    public static let countOptions = [1_000, 10_000, 50_000]
    /// 每次 `performChanges` 写入的张数（太大单次事务耗时长、内存高）。
    public static let batchSize = 50
    /// 合成图边长（像素）。真实照片远大于此；扫描请求 128px 缩略图，足够覆盖特征提取路径。
    public static let imageSize = 512
}

/// 生成计划：把 `count` 张切成批次。
public struct TestAlbumPlan: Sendable, Hashable {
    public let count: Int
    public let batchSize: Int

    public init(count: Int, batchSize: Int = TestAlbumPolicy.batchSize) {
        self.count = max(0, count)
        self.batchSize = max(1, batchSize)
    }

    public var batches: [Range<Int>] {
        stride(from: 0, to: count, by: batchSize).map { $0..<min(count, $0 + batchSize) }
    }
}

/// 写入进度 / 状态（内部页显示）。
public struct TestAlbumProgress: Sendable, Hashable {
    public enum Phase: Sendable, Hashable { case idle, writing, deleting, done, cancelled, failed(String) }
    public var phase: Phase = .idle
    public var written = 0
    public var total = 0
    public init() {}
    public var fraction: Double { total == 0 ? 0 : Double(written) / Double(total) }
}

/// 合成测试图（确定性：同一 index 永远得到同一张图）。
///
/// 每张图是 2×2 四块不同颜色 + 轻微对角渐变：保证 12 维特征分布广、亮度方差非零（不全是纯色图），
/// 并且颜色由 index 经黄金比例旋转得到，相邻 index 颜色差异大。
public enum SyntheticImage {
    public static func make(index: Int, size: Int = TestAlbumPolicy.imageSize) -> PixelBuffer {
        let s = max(2, size)
        let half = s / 2
        let colors = (0..<4).map { quadrant(index: index, q: $0) }
        var bytes = [UInt8](repeating: 255, count: s * s * 4)
        for y in 0..<s {
            for x in 0..<s {
                let q = (y < half ? 0 : 2) + (x < half ? 0 : 1)
                let c = colors[q]
                // 对角渐变 ±12，避免整块纯色
                let g = Int((Double(x + y) / Double(2 * s - 2) - 0.5) * 24)
                let o = (y * s + x) * 4
                bytes[o] = clamp(Int(c.0) + g)
                bytes[o + 1] = clamp(Int(c.1) + g)
                bytes[o + 2] = clamp(Int(c.2) + g)
            }
        }
        return try! PixelBuffer(width: s, height: s, bytes: bytes)
    }

    static func quadrant(index: Int, q: Int) -> (UInt8, UInt8, UInt8) {
        // 黄金比例色相旋转 + 每象限偏移；饱和度 / 亮度随 index 缓慢变化
        let golden = 0.618033988749895
        var h = (Double(index) * golden + Double(q) * 0.13).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        let sat = 0.35 + 0.6 * Double((index / 7 + q) % 5) / 4
        // 亮度主要随 index 变（四象限只差 ±0.05），整图平均亮度才铺得开
        let val = min(1, 0.12 + 0.8 * Double((index / 3) % 7) / 6 + 0.05 * Double(q % 2))
        return hsv(h, sat, val)
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (UInt8, UInt8, UInt8) {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return (UInt8((r * 255).rounded()), UInt8((g * 255).rounded()), UInt8((b * 255).rounded()))
    }

    static func clamp(_ v: Int) -> UInt8 { UInt8(min(255, max(0, v))) }
}
