import Foundation
import MosaicCore

/// 图形配置里的一次选择。首页不另开文字入口：文字和预设都在这个配置里切换。
public struct ShapeChoice: Sendable, Equatable, Hashable {
    public var preset: ShapePresetID
    public var palette: ShapePalette
    public var background: ShapeBackground
    /// 当前用文字，而不是预设。预设 ID 仍留着，切回预设时还在。
    public var usesText: Bool
    /// 正在输入的两行。空行可以留着；生成前再去掉空行。
    public var textLines: [String]

    public init(preset: ShapePresetID = .heart, palette: ShapePalette = .auto, background: ShapeBackground = .white,
                usesText: Bool = false, textLines: [String] = ["", ""]) {
        self.preset = preset
        self.palette = palette
        self.background = background
        self.usesText = usesText
        self.textLines = textLines
    }

    /// 从已存的 manifest 恢复配置。文字固定细档，预设 ID 必须已登记。
    public init?(manifest: ShapeManifest) {
        switch manifest.spec.source {
        case .preset(let id):
            guard id.isKnown else { return nil }
            self.init(preset: id, palette: manifest.spec.palette, background: manifest.spec.background)
        case .text(let lines):
            guard !lines.isEmpty, lines.count <= 2, lines.allSatisfy({ !$0.isEmpty }) else { return nil }
            var rows = lines
            if rows.count == 1 { rows.append("") }
            self.init(preset: .heart, palette: manifest.spec.palette, background: manifest.spec.background,
                      usesText: true, textLines: rows)
        }
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
