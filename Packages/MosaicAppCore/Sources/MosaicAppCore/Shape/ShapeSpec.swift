import Foundation
import MosaicCore

// 形状 / 文字拼图的参数（设计 shape-mosaic-v0.1 §1、§7；架构师 S2 接口 3）。
// 现在就做成 Codable，字段名与作品 manifest v2 的 `shape` 对象一致：
//   { "source": { "preset": "heart" } 或 { "text": ["生日快乐", "宝贝"] }, "color": "auto", "background": "white" }
// P0 不存 `outline`。S2 不写 manifest（`paletteStops`、`mask` 由 S5 写进作品）。
// S3 只把下面的 `ShapeManifest` 当作契约做往返，不把它写成作品文件。

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

/// 设计 §7 的 `shape` 对象。字段与 `ShapeSpec` 对齐，并带 bits-v1 掩码。
///
/// S5 才把整份 manifest 写进作品。S3 不调用它写盘：缺 `source` / `color` 的记录不是这份契约，解码直接失败。
public struct ShapeManifest: Codable, Sendable, Equatable {
    public var spec: ShapeSpec
    public var mask: CellMask
    /// 设计里的 OKLab 色标。没有就不写出。P0 不存 `outline`。
    public var paletteStops: [[Double]]?

    public init(spec: ShapeSpec, mask: CellMask, paletteStops: [[Double]]? = nil) {
        self.spec = spec
        self.mask = mask
        self.paletteStops = paletteStops
    }

    private enum CodingKeys: String, CodingKey { case source, color, background, paletteStops, mask }
    private enum MaskKeys: String, CodingKey { case columns, rows, encoding, data }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(spec.source, forKey: .source)
        try c.encode(spec.palette, forKey: .color)
        try c.encode(spec.background, forKey: .background)
        if let paletteStops { try c.encode(paletteStops, forKey: .paletteStops) }
        var maskC = c.nestedContainer(keyedBy: MaskKeys.self, forKey: .mask)
        try maskC.encode(mask.columns, forKey: .columns)
        try maskC.encode(mask.rows, forKey: .rows)
        try maskC.encode("bits-v1", forKey: .encoding)
        try maskC.encode(Data(mask.bitsV1Bytes).base64EncodedString(), forKey: .data)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let source = try c.decode(ShapeSource.self, forKey: .source)
        let palette = try c.decode(ShapePalette.self, forKey: .color)
        let background = try c.decode(ShapeBackground.self, forKey: .background)
        spec = ShapeSpec(source: source, palette: palette, background: background)
        paletteStops = try c.decodeIfPresent([[Double]].self, forKey: .paletteStops)
        let maskC = try c.nestedContainer(keyedBy: MaskKeys.self, forKey: .mask)
        let columns = try maskC.decode(Int.self, forKey: .columns)
        let rows = try maskC.decode(Int.self, forKey: .rows)
        let encoding = try maskC.decode(String.self, forKey: .encoding)
        guard encoding == "bits-v1" else {
            throw DecodingError.dataCorruptedError(forKey: .encoding, in: maskC,
                                                   debugDescription: "unknown mask encoding \(encoding)")
        }
        guard let bytes = Data(base64Encoded: try maskC.decode(String.self, forKey: .data)) else {
            throw DecodingError.dataCorruptedError(forKey: .data, in: maskC, debugDescription: "mask data is not base64")
        }
        do {
            mask = try CellMask(columns: columns, rows: rows, bitsV1: [UInt8](bytes))
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .data, in: maskC, debugDescription: "bits-v1 mask rejected")
        }
    }
}

/// 预览和导出用的运行时掩码与背景。不是 manifest，不参与 Codable，也不能当成 formatVersion 2 写盘。
public struct ShapeFrame: Sendable, Equatable {
    public var background: ShapeBackground
    public var mask: CellMask

    public init(background: ShapeBackground, mask: CellMask) {
        self.background = background
        self.mask = mask
    }
}
