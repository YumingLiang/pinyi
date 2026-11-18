import Foundation
import MosaicCore

/// 首版预设形状（设计 §1 的 10 个 ID）。文字不在这一阶段。
public struct ShapeChoice: Sendable, Equatable, Hashable {
    public var preset: ShapePresetID
    public var palette: ShapePalette
    public var background: ShapeBackground

    public init(preset: ShapePresetID = .heart, palette: ShapePalette = .auto, background: ShapeBackground = .white) {
        self.preset = preset
        self.palette = palette
        self.background = background
    }

    /// 未登记的 ID 不能选。
    public static func make(preset raw: String, palette: ShapePalette = .auto, background: ShapeBackground = .white) -> ShapeChoice? {
        let id = ShapePresetID(rawValue: raw)
        guard id.isKnown else { return nil }
        return ShapeChoice(preset: id, palette: palette, background: background)
    }
}

extension ShapePresetID {
    /// 文案 key：`shape.preset.<rawValue>`。
    public var titleKey: L10nKey { L10nKey(rawValue: "shape.preset.\(rawValue)") }
}

extension ShapePalette {
    public var titleKey: L10nKey {
        switch self {
        case .auto: return .shapePaletteAuto
        case .warmRed: return .shapePaletteWarmRed
        case .pink: return .shapePalettePink
        case .blue: return .shapePaletteBlue
        case .gold: return .shapePaletteGold
        }
    }
}

/// 由已选形状做出生成用的掩码和合成目标图。照片拼图不走这里。
public enum ShapeGenerationPlan {
    public static func grid(_ choice: ShapeChoice, density: Density) throws -> ShapeLayoutRules.ShapeGrid {
        try ShapeLayoutRules.preset(choice.preset, density: density)
    }

    public static func target(_ choice: ShapeChoice, grid: ShapeLayoutRules.ShapeGrid, photoColors: [OKLab]) throws -> PixelBuffer {
        let gradient = ShapePaletteBuilder.gradient(for: choice.palette, photoColors: photoColors)
        return try ShapeTarget.render(mask: grid.mask, gradient: gradient, background: choice.background)
    }
}
