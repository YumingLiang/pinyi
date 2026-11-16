/// 扫描建索引的缩略图几何（14ac550 / `ImagePixels.opaqueSRGB(maxEdge:)`）。
///
/// PhotoKit 取回后按**长边**等比缩小到 `maxEdge`，保持宽高比，结果可以不是正方形。
/// 特征提取再对缓冲区取 `PixelBuffer.centerSquare`。若先裁成正方形再缩小，特征会与已建索引不一致。
public enum ScanThumbnailGeometry {
    /// 与 `ThumbnailRequest.scan.targetPixelSize` 相同。
    public static let targetPixelSize = 128

    /// 按长边等比缩小后的尺寸；已不超过 `maxEdge` 时原样返回。非法输入返回 0×0。
    public static func size(width: Int, height: Int, maxEdge: Int = targetPixelSize) -> (width: Int, height: Int) {
        let w = max(0, width), h = max(0, height)
        guard w > 0, h > 0 else { return (0, 0) }
        let m = max(0, maxEdge)
        if m == 0 || max(w, h) <= m { return (w, h) }
        let s = Double(m) / Double(max(w, h))
        return (max(1, Int((Double(w) * s).rounded())), max(1, Int((Double(h) * s).rounded())))
    }
}
