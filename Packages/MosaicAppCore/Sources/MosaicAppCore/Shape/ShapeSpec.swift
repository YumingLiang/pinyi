import Foundation

// 形状 / 文字拼图的参数（设计 shape-mosaic-v0.1 §1、§7；架构师 S2 接口 3）。
// 现在就做成 Codable，字段名与作品 manifest v2 的 `shape` 对象一致：
//   { "source": { "preset": "heart" } 或 { "text": ["生日快乐", "宝贝"] }, "color": "auto", "background": "white" }
// P0 不存 `outline`。S2 不写 manifest（`paletteStops`、`mask` 由 S5 写进作品）。

/// 预设形状 ID（manifest 里的字符串）。只有登记在 `PresetShapes.registry` 里的才合法。
public struct ShapePresetID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// 已登记的预设（按实现顺序）。
    public static var all: [ShapePresetID] { PresetShapes.registry.map(\.id) }
    /// 是否已登记。
    public var isKnown: Bool { PresetShapes.registry.contains { $0.id == self } }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
        guard isKnown else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown shape preset \(raw)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// 形状来源：预设或文字（1–2 行，已按 `ShapeTextRules` 过滤）。
public enum ShapeSource: Codable, Sendable, Equatable {
    case preset(ShapePresetID)
    case text(lines: [String])

    private enum CodingKeys: String, CodingKey { case preset, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hasPreset = c.contains(.preset), hasText = c.contains(.text)
        guard hasPreset != hasText else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "shape source needs exactly one of preset / text"))
        }
        if hasPreset {
            self = .preset(try c.decode(ShapePresetID.self, forKey: .preset))
        } else {
            self = .text(lines: try c.decode([String].self, forKey: .text))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preset(let id): try c.encode(id, forKey: .preset)
        case .text(let lines): try c.encode(lines, forKey: .text)
        }
    }

    /// 是否文字模式（文字模式固定细档，需求 1c）。
    public var isText: Bool {
        if case .text = self { return true }
        return false
    }
}

/// 配色：按相册取色（默认）或 4 个固定配色（需求 §2-1；manifest 字段 `color`）。
public enum ShapePalette: String, Codable, Sendable, CaseIterable {
    case auto, warmRed, pink, blue, gold
}

/// 形状外背景色（需求 §2-2）：白（默认）或黑。
public enum ShapeBackground: String, Codable, Sendable, CaseIterable {
    case white, black

    /// 8 位 sRGB。
    public var srgb8: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .white: return (255, 255, 255)
        case .black: return (0, 0, 0)
        }
    }
}

/// 一次形状拼图的完整参数。
public struct ShapeSpec: Codable, Sendable, Equatable {
    public var source: ShapeSource
    public var palette: ShapePalette
    public var background: ShapeBackground

    public init(source: ShapeSource, palette: ShapePalette = .auto, background: ShapeBackground = .white) {
        self.source = source
        self.palette = palette
        self.background = background
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case palette = "color"
        case background
    }
}
