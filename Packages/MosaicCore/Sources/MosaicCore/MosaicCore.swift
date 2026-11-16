/// MosaicCore 命名空间与版本信息。
///
/// 本模块只依赖 Swift 标准库与 Foundation/Dispatch 的跨平台子集，
/// 在 Linux 与 Apple 平台上行为一致（见技术方案 §11.1）。
public enum MosaicCoreInfo {
    /// 库版本号（语义化版本）。
    public static let version = "0.1.0"
    /// 特征格式版本。特征定义（颜色空间、子块划分、平均方式）变化时递增，
    /// 用于让缓存失效（技术方案 §2.5「特征版本」）。
    public static let featureVersion: UInt32 = 1
}

/// MosaicCore 抛出的错误。
public enum MosaicError: Error, Equatable, Sendable {
    /// 维度不一致（例如查询是 12 维而素材是 27 维）。
    case dimensionMismatch(expected: Int, actual: Int)
    /// 元素个数不一致（例如格子特征数 ≠ 网格格子数，掩码长度 ≠ 素材数）。
    case countMismatch(expected: Int, actual: Int)
    /// 没有任何可用素材（素材为空或掩码全部为 0）。
    case noCandidates
    /// 像素缓冲区参数不合法（尺寸、行字节数或数据长度）。
    case invalidPixelBuffer(String)
    /// 取样区域为空或越界。
    case invalidRegion
    /// 网格参数不合法。
    case invalidGrid(String)
    /// 配置参数不合法。
    case invalidConfiguration(String)
}
