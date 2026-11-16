/// 从像素计算 2×2 子块颜色特征（技术方案 §2.1）。
///
/// 默认在「线性光」里对每个子块求平均，再把均值转换到 OKLab（见 `Averaging`）。
public struct FeatureExtractor: Sendable {
    /// 子块均值的计算方式。
    public enum Averaging: Sendable, Hashable {
        /// 先在线性 sRGB 中求子块像素均值，再把均值转换到目标颜色空间（默认）。
        /// 物理上等价于"远看时这一块混合出的颜色"，且每块只需一次颜色转换。
        case linearLight
        /// 逐像素先转换到目标颜色空间，再求均值（感知空间均值）。
        case perceptual
    }

    /// 颜色空间（默认 OKLab）。
    public var colorSpace: FeatureColorSpace
    /// 平均方式（默认 `.linearLight`）。
    public var averaging: Averaging
    /// 亮度方差低于该阈值时打上 `.lowDetail` 标志（亮度已归一化到约 0…1）。
    /// 默认与打分用的 σ²_ref 同源：`TuningDefaults.lowDetailVarianceReference`。
    public var lowDetailVarianceThreshold: Float

    /// 创建提取器。
    public init(colorSpace: FeatureColorSpace = .oklab, averaging: Averaging = .linearLight, lowDetailVarianceThreshold: Float = TuningDefaults.lowDetailVarianceReference) {
        self.colorSpace = colorSpace
        self.averaging = averaging
        self.lowDetailVarianceThreshold = lowDetailVarianceThreshold
    }

    /// 计算素材图特征：默认取中心正方形区域（技术方案 §2.1）。
    ///
    /// - Parameters:
    ///   - buffer: 像素缓冲区（建议已规整到约 32×32）。
    ///   - region: 取样区域；`nil` 表示 `buffer.centerSquare`。
    /// - Returns: 特征记录；`aspectRatio` 为整个缓冲区的宽高比。
    /// - Throws: `MosaicError.invalidRegion` 区域为空或越界。
    public func extract(from buffer: PixelBuffer, region: PixelRegion? = nil) throws -> FeatureRecord {
        let r = region ?? buffer.centerSquare
        guard r.isValid(in: buffer) else { throw MosaicError.invalidRegion }

        var blocks = [SIMD3<Float>](repeating: .zero, count: 4)
        var lightnessSum: Double = 0
        var lightnessSqSum: Double = 0
        var pixelCount = 0

        // 单遍（评审 S1）：每个像素线性化一次，同时累加子块均值与亮度；亮度只算 L 分量。
        // 段长 ≥ 2 时各子块互不重叠；只有 1 像素宽/高时子块共享像素，每个像素被等权重复计入，均值与方差不变。
        let lScale = Double(colorSpace.lightnessScale)
        for by in 0..<2 {
            let ys = FeatureExtractor.span(index: by, parts: 2, length: r.height)
            for bx in 0..<2 {
                let xs = FeatureExtractor.span(index: bx, parts: 2, length: r.width)
                var acc = SIMD3<Double>.zero
                var n = 0
                for y in ys {
                    for x in xs {
                        let lin = buffer.linearSRGB(x: r.x + x, y: r.y + y)
                        let l: Double
                        switch averaging {
                        case .linearLight:
                            acc += SIMD3<Double>(Double(lin.r), Double(lin.g), Double(lin.b))
                            l = Double(colorSpace.lightness(lin)) * lScale
                        case .perceptual:
                            let c = colorSpace.convert(lin)
                            acc += SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))
                            l = Double(c.x) * lScale
                        }
                        lightnessSum += l
                        lightnessSqSum += l * l
                        pixelCount += 1
                        n += 1
                    }
                }
                let mean = acc / Double(n)
                let color: SIMD3<Float>
                switch averaging {
                case .linearLight:
                    color = colorSpace.convert(LinearRGB(r: Float(mean.x), g: Float(mean.y), b: Float(mean.z)))
                case .perceptual:
                    color = SIMD3<Float>(Float(mean.x), Float(mean.y), Float(mean.z))
                }
                blocks[by * 2 + bx] = color
            }
        }
        let meanL = lightnessSum / Double(pixelCount)
        let variance = Float(max(0, lightnessSqSum / Double(pixelCount) - meanL * meanL))

        var flags: FeatureFlags = []
        if variance < lowDetailVarianceThreshold { flags.insert(.lowDetail) }

        return FeatureRecord(
            vector: FeatureVector(blocks: blocks),
            lightnessVariance: variance,
            aspectRatio: Float(buffer.width) / Float(buffer.height),
            flags: flags
        )
    }

    /// 把长度 `length` 均分成 `parts` 段，返回第 `index` 段的像素范围。
    /// 长度不足以分段时（例如 1 像素宽），各段退化为共享同一个像素，保证每段非空。
    @usableFromInline
    static func span(index: Int, parts: Int, length: Int) -> Range<Int> {
        var start = index * length / parts
        var end = (index + 1) * length / parts
        if end <= start {
            start = min(start, length - 1)
            end = start + 1
        }
        return start..<end
    }
}
