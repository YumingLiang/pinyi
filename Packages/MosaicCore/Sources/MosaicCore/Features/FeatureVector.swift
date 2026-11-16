/// 每张素材 / 每个目标格子的颜色特征：2×2 子块的颜色均值，共 12 维 Float32
/// （技术方案 §2.1）。
///
/// 分量排列（块优先）：`[TL.L, TL.a, TL.b, TR.L, TR.a, TR.b, BL.L, BL.a, BL.b, BR.L, BR.a, BR.b]`，
/// 块顺序为左上、右上、左下、右下（行优先）。
/// 内部用 `SIMD16<Float>` 存储（第 12–15 道恒为 0），便于向量化且是值类型。
public struct FeatureVector: Hashable, Sendable {
    /// 特征维度（12）。
    public static let dimension = 12
    /// 子块数量（2×2 = 4）。
    public static let blockCount = 4

    /// 原始存储；第 12–15 道恒为 0。
    public private(set) var storage: SIMD16<Float>

    /// 全零特征。
    public init() {
        storage = .zero
    }

    /// 由 12 个分量构造。
    /// - Precondition: `components.count == 12`。
    public init(_ components: [Float]) {
        precondition(components.count == FeatureVector.dimension, "FeatureVector needs exactly 12 components")
        var s = SIMD16<Float>.zero
        for i in 0..<FeatureVector.dimension { s[i] = components[i] }
        storage = s
    }

    /// 由 4 个子块颜色（顺序 TL, TR, BL, BR）构造。
    public init(blocks: [SIMD3<Float>]) {
        precondition(blocks.count == FeatureVector.blockCount, "FeatureVector needs exactly 4 blocks")
        var s = SIMD16<Float>.zero
        for (i, c) in blocks.enumerated() {
            s[i * 3] = c.x
            s[i * 3 + 1] = c.y
            s[i * 3 + 2] = c.z
        }
        storage = s
    }

    /// 四个子块颜色都相同的特征（纯色）。
    public init(uniform color: SIMD3<Float>) {
        self.init(blocks: [color, color, color, color])
    }

    /// 读写第 `i` 个分量（0..<12）。
    public subscript(i: Int) -> Float {
        get {
            precondition(i >= 0 && i < FeatureVector.dimension)
            return storage[i]
        }
        set {
            precondition(i >= 0 && i < FeatureVector.dimension)
            storage[i] = newValue
        }
    }

    /// 12 个分量组成的数组。
    public var components: [Float] {
        (0..<FeatureVector.dimension).map { storage[$0] }
    }

    /// 第 `index` 个子块的颜色 `(L, a, b)`。
    public func block(_ index: Int) -> SIMD3<Float> {
        precondition(index >= 0 && index < FeatureVector.blockCount)
        return SIMD3(storage[index * 3], storage[index * 3 + 1], storage[index * 3 + 2])
    }

    /// 平均色：4 个子块均值的均值（子块面积相等时即整体均值），用于粗筛与 UI 展示。
    public var meanColor: SIMD3<Float> {
        (block(0) + block(1) + block(2) + block(3)) / 4
    }

    /// 与另一特征的平方欧氏距离（12 维）。
    public func squaredDistance(to other: FeatureVector) -> Float {
        let d = storage - other.storage
        return (d * d).sum()
    }
}

/// 特征记录标志位（对应 `features.bin` 定长记录中的 flags，技术方案 §2.3）。
public struct FeatureFlags: OptionSet, Hashable, Sendable {
    /// 原始位。
    public let rawValue: UInt32
    /// 构造。
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// 已删除（tombstone），匹配时应通过掩码排除。
    public static let deleted = FeatureFlags(rawValue: 1 << 0)
    /// 低细节（亮度方差很小，接近纯色图），供上层做"纯色图过度使用"惩罚。
    public static let lowDetail = FeatureFlags(rawValue: 1 << 1)
}

/// 一张图（或一个目标格子）的完整特征记录。
public struct FeatureRecord: Hashable, Sendable {
    /// 12 维颜色特征。
    public var vector: FeatureVector
    /// 取样区域内逐像素亮度的方差（亮度归一化到约 0…1），技术方案 §2.1 附加标量。
    public var lightnessVariance: Float
    /// 原图宽高比（宽 / 高），中心裁剪前的值，供后续选择裁剪方式。
    public var aspectRatio: Float
    /// 标志位。
    public var flags: FeatureFlags

    /// 构造记录。
    public init(vector: FeatureVector, lightnessVariance: Float = 0, aspectRatio: Float = 1, flags: FeatureFlags = []) {
        self.vector = vector
        self.lightnessVariance = lightnessVariance
        self.aspectRatio = aspectRatio
        self.flags = flags
    }
}
