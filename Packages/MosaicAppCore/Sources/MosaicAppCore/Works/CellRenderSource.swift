import Foundation
import MosaicCore

/// 一格的内容来源（works-missing-fill 的 `CellRenderSource`）。
///
/// 有 `fc` 就填这个颜色，不读旧预览，也不把调用方另外传来的裁切小图当作这一格的像素。
/// 没有 `fc` 时，空格子仍可由调用方的兜底小图填上；普通格子取照片。
/// 形状外不在这里决定：形状条带的背景优先于 `fc`、兜底图和照片。
public enum CellRenderSource: Equatable, Sendable {
    case photo(id: String, crop: CropRect)
    case fill(CellColor)
    case blank

    public var fillColor: CellColor? {
        if case .fill(let color) = self { return color }
        return nil
    }
}

/// 预览和再导出共用的一格绘制决定。形状条带仍是形状外的权威。
public enum CellPaint: Equatable, Sendable {
    case shapeBackground(ShapeBackground)
    case fill(CellColor)
    /// 调用方已有这一格的兜底小图。只在没有 `fc`、也不是形状外时出现。
    case fallback
    case photo(id: String, crop: CropRect)
    case blank
}

extension MosaicLayout {
    /// 第 `index` 格（行优先）的内容来源。下标越界按空白。不看形状掩码。
    public func renderSource(at index: Int) -> CellRenderSource {
        guard cellAssignments.indices.contains(index) else { return .blank }
        let cell = cellAssignments[index]
        if let fill = cell.fill { return .fill(fill) }
        if cell.localIdentifier.isEmpty { return .blank }
        return .photo(id: cell.localIdentifier, crop: cell.crop)
    }

    /// 形状外背景优先。形状内 `fc` 优先于兜底图和照片。没有 `fc` 时，有兜底图用兜底图，否则取照片或留白。
    public func cellPaint(at index: Int, outsideBackground: ShapeBackground?, hasFallback: Bool) -> CellPaint {
        if let outsideBackground { return .shapeBackground(outsideBackground) }
        switch renderSource(at: index) {
        case .fill(let color):
            return .fill(color)
        case .photo(let id, let crop):
            return hasFallback ? .fallback : .photo(id: id, crop: crop)
        case .blank:
            return hasFallback ? .fallback : .blank
        }
    }
}
