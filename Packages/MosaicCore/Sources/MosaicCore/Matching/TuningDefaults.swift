/// 打分调参常量的唯一来源（评审 ca6a4ca 拍板 (3)）。
///
/// ⚠️ **全部是暂定默认值，待真机调参**（A/B 合成测试 + TF2 真机目测）。调参只改这里
/// （`AssignmentConfiguration` 与 `FeatureExtractor` 的默认值都从这里取），不做 UI 控件。
public enum TuningDefaults {
    /// α：使用次数惩罚的相对系数，λ_eff = α × 惩罚尺度（`PenaltyScale`）。
    public static let usagePenaltyRelative: Float = 0.1
    /// β：纯色惩罚的相对系数，μ_eff = β × 同一尺度（= 0.4 α）。
    public static let lowDetailPenaltyRelative: Float = 0.04
    /// σ²_ref：亮度方差参考值（σ_L = 0.02，L 归一到 0…1）。打分的 flatness 与 `.lowDetail` 标志共用。
    public static let lowDetailVarianceReference: Float = 0.0004
    /// 惩罚尺度最后兜底：候选与目标距离全为 0 时使用（见 `PenaltyScale`）。
    public static let degeneratePenaltyScale: Float = 1e-3
}
