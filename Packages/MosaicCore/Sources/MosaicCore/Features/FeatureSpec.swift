/// 特征口径（评审 S4）：素材与目标格必须用同一口径提取，否则距离无意义。
/// 写入 `features.bin` 头部；`MosaicPipeline.generate(table:)` 会校验与取样器一致。
public struct FeatureSpec: Hashable, Sendable, CustomStringConvertible {
    /// 颜色空间。
    public var colorSpace: FeatureColorSpace
    /// 子块平均方式。
    public var averaging: FeatureExtractor.Averaging
    /// 特征定义版本（`MosaicCoreInfo.featureVersion`）。
    public var featureVersion: UInt32

    /// 构造。
    public init(colorSpace: FeatureColorSpace = .oklab, averaging: FeatureExtractor.Averaging = .linearLight,
                featureVersion: UInt32 = MosaicCoreInfo.featureVersion) {
        self.colorSpace = colorSpace
        self.averaging = averaging
        self.featureVersion = featureVersion
    }

    /// 当前默认口径：OKLab + 线性光平均 + 当前特征版本。
    public static let current = FeatureSpec()

    /// 文本描述。
    public var description: String { "\(colorSpace.rawValue)/\(averaging)/v\(featureVersion)" }
}

extension FeatureExtractor {
    /// 本提取器的口径。
    public var spec: FeatureSpec { FeatureSpec(colorSpace: colorSpace, averaging: averaging) }
}
