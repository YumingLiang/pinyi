/// 结果页预览位图的尺寸约定（feat/preview-sharp-quick）。
///
/// 放大后小格子发糊，主要是旧预览每格只有 8–32 px、长边约 2400，再叠加 SwiftUI
/// `.interpolation(.none)`。这里把预览每格提到 48–64 px，长边上限约 4096；格数太多时
/// 优先守住长边上限，每格可以低于 48。不参与生成匹配，只影响结果页预览绘制。
public enum PreviewImageLimits {
    /// 目标每格像素下限（长边未触顶时尽量不低于此值）。
    public static let minPreferredCellPixels = 48
    /// 每格像素上限。
    public static let maxCellPixels = 64
    /// 预览位图长边上限（像素）。
    public static let maxLongEdge = 4096

    /// 每格像素：默认取 `maxCellPixels`（64），若 `max(列, 行) × 64` 会超过 `maxLongEdge`，则降为
    /// `maxLongEdge / 长边格数`（至少 1）。因此 120 列时是 34 px，低于 48，这是守长边上限定的。
    public static func cellPixels(columns: Int, rows: Int) -> Int {
        let long = max(max(columns, rows), 1)
        return max(1, min(maxCellPixels, maxLongEdge / long))
    }

    public static func size(columns: Int, rows: Int) -> (width: Int, height: Int, cellPixels: Int) {
        let cp = cellPixels(columns: columns, rows: rows)
        return (max(columns, 0) * cp, max(rows, 0) * cp, cp)
    }

    /// 不透明 RGBA8 紧密排列的预览位图字节数。
    public static func rgbaByteCount(columns: Int, rows: Int) -> Int {
        let s = size(columns: columns, rows: rows)
        return s.width * s.height * 4
    }
}
