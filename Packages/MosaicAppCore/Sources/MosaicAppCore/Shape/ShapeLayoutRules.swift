import MosaicCore

/// 文字轮廓（App 层 CoreText 实现，设计 §1）。`path` 已归一化；`widthEm` / `heightEm` 是排版后外接框的实际大小（单位 em），
/// 用来校验「每个字 ≥ 24 格」（需求 1c）。
public struct TextOutline: Sendable, Equatable {
    public var path: ShapePath
    public var widthEm: Double
    public var heightEm: Double

    /// 单个字形在归一化轮廓里的位置（0…1，和 `path` 同一套外接框）。
    public var glyphs: [TextGlyphBox]

    public init(path: ShapePath, widthEm: Double, heightEm: Double, glyphs: [TextGlyphBox] = []) {
        self.path = path
        self.widthEm = widthEm
        self.heightEm = heightEm
        self.glyphs = glyphs
    }
}

/// 一个字形的真实外接框，不是整行均分。
public struct TextGlyphBox: Sendable, Equatable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 把 1–2 行文字排成轮廓（App 层 `CoreTextOutline` 实现：系统粗体、多行居中、行距 1.15 em）。
/// 取不到轮廓返回 `nil`。
public protocol TextOutlineProviding: Sendable {
    func outline(lines: [String]) -> TextOutline?
}

/// 形状网格与掩码（设计 §2、§3）。
///
/// - 预设形状：长边 = 所选密度档的格数（粗 40 / 中 80 / 细 120），短边按外接框比例（含 1 格边距）。
/// - **文字固定细档（120 格）**：文字入口不接受密度参数（需求 1c；架构师 S2 接口 4）。
/// - 合成目标图 = 列 × 16、行 × 16 像素；`Layout.grid` 对这张图算出的网格与这里的网格相同，
///   所以生成时直接把掩码作为 `activeCells` 传给 `MosaicPipeline`。
public enum ShapeLayoutRules {
    /// 预设形状四周边距（格）。设计 v0.1.1 §2：预设和文字都是 1 格（0.5 格时最宽处的边格覆盖正好 32/64 会被点亮，形状贴图边）。
    public static let presetMarginCells = 1.0
    /// 文字四周边距（格）。
    public static let textMarginCells = 1.0
    /// 文字模式的固定密度：细档 120。
    public static let textDensity: Density = .fine
    /// 合成目标图每格像素数。
    public static let targetPixelsPerCell = 16
    /// 文字每 em 的格数验收线（需求 1c：每字 ≥ 24 格）。
    public static let minimumCellsPerEm = 24.0
    /// 一行大约 4.3 em 时刚好用满细档内框。短行也用这个比例，不再放大到铺满 120 格。
    public static let textReferenceWidthEm = 4.3
    /// 118 / 4.3 ≈ 27.4。四字一行大约 27–28 格，一到三字也停在这个量级，不是大约 30 的另一种放大。
    public static var nominalTextCellsPerEm: Double {
        (Double(textDensity.columns) - 2 * textMarginCells) / textReferenceWidthEm
    }

    /// 网格 + 掩码。
    public struct ShapeGrid: Sendable, Equatable {
        /// 与合成目标图对应的网格划分（`Layout.grid(width: 列 × 16, height: 行 × 16, density:)`）。
        public let layout: GridLayout
        /// 形状掩码（尺寸 = `layout.grid`）。
        public let mask: CellMask
        /// 生成所用密度（文字模式恒为 `.fine`）。
        public let density: Density
        /// 光栅化细节（覆盖率、外接框位置）。
        public let raster: PathRasterizer.Result
    }

    // MARK: - 预设形状

    /// 预设形状在给定密度下的网格与掩码。
    /// - Throws: 未登记的形状抛 `MosaicError.invalidConfiguration`。
    public static func preset(_ id: ShapePresetID, density: Density) throws -> ShapeGrid {
        guard let path = PresetShapes.path(for: id) else {
            throw MosaicError.invalidConfiguration("unknown shape preset \(id.rawValue)")
        }
        return try shapeGrid(path: path, density: density, margin: presetMarginCells)
    }

    /// 任意路径按预设规则（可选密度、1 格边距）出网格与掩码。
    public static func preset(path: ShapePath, density: Density) throws -> ShapeGrid {
        try shapeGrid(path: path, density: density, margin: presetMarginCells)
    }

    // MARK: - 文字（固定细档，无密度参数）

    /// 文字轮廓的网格与掩码：固定细档 120、1 格边距。**没有密度参数**。
    public static func text(_ outline: TextOutline) throws -> ShapeGrid {
        let layout = try grid(aspect: outline.path.aspect, density: textDensity, margin: textMarginCells)
        let cells = nominalTextCellsPerEm
        let fitW = outline.widthEm * cells
        let fitH = outline.heightEm * cells
        let raster = try PathRasterizer.rasterize(outline.path, columns: layout.columns, rows: layout.rows,
                                                  marginCells: textMarginCells, fitWidth: fitW, fitHeight: fitH)
        return ShapeGrid(layout: layout, mask: raster.mask, density: textDensity, raster: raster)
    }

    /// 实际光栅缩放，单位是格 / em。
    /// design/shape-mosaic-v0.1.md:39：`min(fitW / widthEm, fitH / heightEm)`，边距已含在 fit 里。
    /// 不能只取 `fitWidth / widthEm`：高度更紧时那条名义值会偏大。
    public static func cellsPerEm(fitWidth: Double, widthEm: Double, fitHeight: Double, heightEm: Double) -> Double {
        let byWidth = widthEm > 0 ? fitWidth / widthEm : .infinity
        let byHeight = heightEm > 0 ? fitHeight / heightEm : .infinity
        return min(byWidth, byHeight)
    }

    /// 文字轮廓在固定细档下每 em 实际占多少格。读光栅结果的宽和高，再取 min。
    public static func cellsPerEm(_ outline: TextOutline) throws -> Double {
        let g = try text(outline)
        return cellsPerEm(fitWidth: g.raster.fitWidth, widthEm: outline.widthEm,
                          fitHeight: g.raster.fitHeight, heightEm: outline.heightEm)
    }

    /// design/shape-mosaic-v0.1.md:56–57 与 qa/shape-mosaic-test-checklist.md:27：
    /// 验收是这个 `cellsPerEm` ≥ 24。不是每个汉字墨水曲线的宽或高 ≥ 24。
    public static func meetsMinimumCellsPerEm(_ outline: TextOutline) throws -> Bool {
        try cellsPerEm(outline) >= minimumCellsPerEm
    }

    /// 每个字形在固定细档网格里的外接框，单位是格。用字形自己的曲线边界，不用整行宽度除以字数。
    public static func glyphCellBoxes(_ outline: TextOutline) throws -> [GlyphCellBox] {
        let grid = try text(outline)
        return outline.glyphs.map { glyph in
            GlyphCellBox(text: glyph.text,
                         x: grid.raster.fitX + glyph.x * grid.raster.fitWidth,
                         y: grid.raster.fitY + glyph.y * grid.raster.fitHeight,
                         width: glyph.width * grid.raster.fitWidth,
                         height: glyph.height * grid.raster.fitHeight)
        }
    }

    public struct GlyphCellBox: Sendable, Equatable {
        public var text: String
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    // MARK: - 网格

    /// 按外接框宽高比（含边距）定网格：长边 = 密度格数，短边 = ceil(长边内框 ÷ 比例 + 2 × 边距)，再交给 `Layout.grid` 校验。
    public static func grid(aspect: Double, density: Density, margin: Double) throws -> GridLayout {
        guard aspect > 0, aspect.isFinite else { throw MosaicError.invalidGrid("shape aspect must be > 0") }
        let n = density.columns
        let innerLong = Double(n) - 2 * margin
        let ratio = aspect >= 1 ? aspect : 1 / aspect
        let short = min(n, max(1, Int((innerLong / ratio + 2 * margin - 1e-9).rounded(.up))))
        let columns = aspect >= 1 ? n : short
        let rows = aspect >= 1 ? short : n
        let px = targetPixelsPerCell
        let layout = try Layout.grid(width: columns * px, height: rows * px, density: density)
        guard layout.columns == columns, layout.rows == rows else {
            throw MosaicError.invalidGrid("shape grid \(columns)×\(rows) disagrees with Layout.grid")
        }
        return layout
    }

    private static func shapeGrid(path: ShapePath, density: Density, margin: Double) throws -> ShapeGrid {
        let layout = try grid(aspect: path.aspect, density: density, margin: margin)
        let raster = try PathRasterizer.rasterize(path, columns: layout.columns, rows: layout.rows, marginCells: margin)
        return ShapeGrid(layout: layout, mask: raster.mask, density: density, raster: raster)
    }
}

/// 文字输入规则（需求 1b、1c；设计 §3）。
/// - 只允许汉字（Unicode Script = Han）、A–Z、a–z、0–9；其余（emoji、标点、空格）丢弃并提示 `shape.text.unsupported`。
/// - 计数：汉字 1，字母数字 0.5；每行 ≤ 4；最多 2 行；全空不可下一步。
public enum ShapeTextRules {
    public static let maxLines = 2
    public static let maxUnitsPerLine = 4.0

    /// 过滤结果。
    public struct Filtered: Sendable, Equatable {
        public let text: String
        /// 是否丢掉了不支持的字符（UI 提示 `shape.text.unsupported`）。
        public let droppedUnsupported: Bool
    }

    /// 校验结果。
    public enum Validation: Sendable, Equatable {
        case ok
        /// 全部为空：「下一步」不可点。
        case empty
        /// 行数超过 2。
        case tooManyLines
        /// 第 `line` 行（0 起）超过 4 个汉字的量。
        case lineTooLong(line: Int)
    }

    /// 按「字」（Character）过滤：一个字必须恰好是一个受支持的 Unicode 标量（因此「1️⃣」这类组合 emoji 整个丢掉）。
    public static func filter(_ s: String) -> Filtered {
        var out = ""
        var dropped = false
        for ch in s {
            let scalars = ch.unicodeScalars
            if scalars.count == 1, let u = scalars.first, isSupported(u) {
                out.append(ch)
            } else {
                dropped = true
            }
        }
        return Filtered(text: out, droppedUnsupported: dropped)
    }

    /// 单个标量是否受支持。
    public static func isSupported(_ u: Unicode.Scalar) -> Bool {
        isAlphanumericASCII(u) || isHan(u)
    }

    /// 一行的「字数」（汉字 1，字母数字 0.5）。
    public static func units(_ line: String) -> Double {
        var n = 0.0
        for ch in line {
            guard ch.unicodeScalars.count == 1, let u = ch.unicodeScalars.first else { continue }
            if isHan(u) { n += 1 } else if isAlphanumericASCII(u) { n += 0.5 }
        }
        return n
    }

    /// 校验已过滤的各行（空行在计数前去掉）。
    public static func validate(lines: [String]) -> Validation {
        let nonEmpty = lines.filter { !$0.isEmpty }
        if nonEmpty.isEmpty { return .empty }
        if nonEmpty.count > maxLines { return .tooManyLines }
        for (i, l) in nonEmpty.enumerated() where units(l) > maxUnitsPerLine { return .lineTooLong(line: i) }
        return .ok
    }

    /// 再输入一个字后这一行是否仍在上限内（UI 用来拦住继续输入）。
    public static func canAppend(_ ch: Character, to line: String) -> Bool {
        guard filter(String(ch)).text == String(ch) else { return false }
        return units(line + String(ch)) <= maxUnitsPerLine
    }

    private static func isAlphanumericASCII(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }

    /// Unicode Script = Han 的码位（Unicode 15.1 Scripts.txt 中 Han 的区段）。
    private static let hanRanges: [ClosedRange<UInt32>] = [
        0x2E80...0x2E99, 0x2E9B...0x2EF3, 0x2F00...0x2FD5, 0x3005...0x3005, 0x3007...0x3007,
        0x3021...0x3029, 0x3038...0x303B, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFA6D,
        0xFA70...0xFAD9, 0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0x2F800...0x2FA1F, 0x30000...0x323AF,
    ]

    private static func isHan(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return hanRanges.contains { $0.contains(v) }
    }
}
