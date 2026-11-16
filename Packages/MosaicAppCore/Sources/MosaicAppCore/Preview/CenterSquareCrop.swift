/// 把非正方形图居中裁成短边正方形（纯函数，Linux 可测）。
///
/// PhotoKit `.aspectFill` + `targetSize = N×N` 可能返回非正方形，例如 256×341。
/// 若再按长边缩到 N（变成 192×256）画进 N×N 的格子，会被横向拉伸，有效清晰度只有短边。
/// 正确做法：按短边居中裁方，再只在边长大于目标时等比缩小；短边不足时保持原生正方形，由绘制端放大。
public enum CenterSquareCrop {
    /// 以短边为边长、居中裁出的正方形（像素坐标，原点在左上，与 `CGImage.cropping` 一致）。
    /// 宽高差为奇数时起点向下取整（上/左比下/右少 1 px）。非法尺寸返回 `size = 0`。
    public static func rect(width: Int, height: Int) -> (x: Int, y: Int, size: Int) {
        let w = max(0, width), h = max(0, height)
        let size = min(w, h)
        guard size > 0 else { return (0, 0, 0) }
        return ((w - size) / 2, (h - size) / 2, size)
    }

    /// 裁方后的输出边长：大于 `maxEdge` 时缩小到 `maxEdge`；短边不足时保持原生边长（不放大、不非等比缩放）。
    public static func outputSide(sourceWidth: Int, sourceHeight: Int, maxEdge: Int) -> Int {
        let size = rect(width: sourceWidth, height: sourceHeight).size
        guard size > 0 else { return 0 }
        let cap = max(0, maxEdge)
        return cap == 0 ? size : min(size, cap)
    }
}
