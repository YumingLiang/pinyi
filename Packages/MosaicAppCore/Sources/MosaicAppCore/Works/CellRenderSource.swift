import Foundation
import MosaicCore

/// 预览渲染器和导出器画一格时读什么（works-missing-fill）。
///
/// 有 `fc` 就直接填这个颜色。不读旧预览，也不把调用方另外传来的裁切小图当作这一格的像素
/// （旧预览裁切可能带着已经隐藏的照片）。没有 `fc` 时，空格子仍可由调用方的兜底小图填上
/// （受限访问下还没写回的临时补格）；普通格子取照片。
public enum CellRenderSource: Equatable, Sendable {
    case photo(id: String, crop: CropRect)
    case fill(CellColor)
    case blank

    public var fillColor: CellColor? {
        if case .fill(let color) = self { return color }
        return nil
    }
}

extension MosaicLayout {
    /// 第 `index` 格（行优先）的绘制来源。下标越界按空白。
    public func renderSource(at index: Int) -> CellRenderSource {
        guard cellAssignments.indices.contains(index) else { return .blank }
        let cell = cellAssignments[index]
        if let fill = cell.fill { return .fill(fill) }
        if cell.localIdentifier.isEmpty { return .blank }
        return .photo(id: cell.localIdentifier, crop: cell.crop)
    }
}
