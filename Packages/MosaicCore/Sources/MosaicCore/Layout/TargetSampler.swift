/// 把目标图按网格切分，计算每个格子的特征（作为匹配的查询）。
public struct TargetSampler: Sendable {
    /// 使用的特征提取器（颜色空间、平均方式须与素材特征一致）。
    public var extractor: FeatureExtractor

    /// 创建取样器。
    public init(extractor: FeatureExtractor = FeatureExtractor()) {
        self.extractor = extractor
    }

    /// 计算所有格子的特征（行优先），格子区域取自 `layout`（正方形格、短边居中裁切）。
    /// - Throws: `layout` 与缓冲区尺寸不符时抛 `MosaicError.invalidGrid`；区域非法时抛 `MosaicError.invalidRegion`。
    public func cellFeatures(of buffer: PixelBuffer, layout: GridLayout) throws -> [FeatureRecord] {
        guard layout.imageWidth == buffer.width, layout.imageHeight == buffer.height else {
            throw MosaicError.invalidGrid("layout was computed for \(layout.imageWidth)×\(layout.imageHeight), buffer is \(buffer.width)×\(buffer.height)")
        }
        return try (0..<layout.grid.cellCount).map { i in
            try extractor.extract(from: buffer, region: layout.cellPixelRegion(i))
        }
    }
}
