import Foundation

/// 一个字形已经换成「点、y 向上」的轮廓，原点在该字形的原点（`CTFontCreatePathForGlyph` 再乘上字号 / unitsPerEm）。
public struct TextGlyphPlacement: Sendable, Equatable {
    /// 路径元素。y 向上，相对于 `originX` / `originY`。
    public var elements: [ShapePath.Element]
    /// 字形原点的 x（点，相对于这一行排版原点，向右为正）。
    public var originX: Double
    /// 字形原点的 y（点，相对于这一行基线，向上为正）。
    public var originY: Double

    /// 这个字形对应的原文。一个汉字或一个英文数字。取不到时为空。
    public var text: String

    public init(elements: [ShapePath.Element], originX: Double, originY: Double, text: String = "") {
        self.elements = elements
        self.originX = originX
        self.originY = originY
        self.text = text
    }
}

/// 一行已经排好的字形。`advance` 是这一行的排版宽度（点），多行按它水平居中，不按墨水外接框居中。
public struct TextLinePlacement: Sendable, Equatable {
    public var glyphs: [TextGlyphPlacement]
    /// 行宽（点）。CoreText 用 `CTLineGetTypographicBounds` 的宽度。
    public var advance: Double

    public init(glyphs: [TextGlyphPlacement], advance: Double) {
        self.glyphs = glyphs
        self.advance = advance
    }
}

/// 把各行字形轮廓排成 `TextOutline`（设计 §1：多行居中、行距 1.15 em、y 向下、再归一化）。
///
/// CoreText 取字形（`UIFont` / `CTLine` / `CTFontCreatePathForGlyph`）在 App 层 `CoreTextOutline`。
/// 这里只做与字体无关的排版，Linux 上可以测：行距、居中、y 翻转、em 外接框和 `path.aspect` 是同一套数。
public enum TextOutlineAssembler {
    /// 设计 §1：`UIFont.systemFont(ofSize: 100, weight: .heavy)`。1 em = 100 点。
    public static let fontSizePoints: Double = 100
    /// 设计 §1：多行行距 1.15 em（基线到基线）。
    public static let lineSpacingEm: Double = 1.15

    /// 排成文字轮廓。没有任何墨水（空行、取不到字形）返回 `nil`。
    /// - Parameters:
    ///   - lines: 从上到下。空行仍占一行行距。
    ///   - fontSize: 1 em 的点数。默认 100。
    ///   - lineSpacingEm: 相邻基线的距离，单位 em。默认 1.15。
    public static func assemble(lines: [TextLinePlacement], fontSize: Double = fontSizePoints,
                                lineSpacingEm: Double = lineSpacingEm) -> TextOutline? {
        guard fontSize > 0, fontSize.isFinite, lineSpacingEm > 0, lineSpacingEm.isFinite else { return nil }
        let advances = lines.map { $0.advance.isFinite ? $0.advance : 0 }
        let maxAdvance = advances.max() ?? 0
        var raw: [ShapePath.Element] = []
        var placed: [(text: String, elements: [ShapePath.Element])] = []
        for (i, line) in lines.enumerated() {
            let dx = (maxAdvance - advances[i]) / 2
            let baseline = Double(i) * lineSpacingEm * fontSize
            for glyph in line.glyphs {
                let ox = glyph.originX.isFinite ? glyph.originX : 0
                let oy = glyph.originY.isFinite ? glyph.originY : 0
                let elements = transformed(glyph.elements) { p in
                    // y 向上的点，翻成 y 向下：这一行的基线在 baseline，点在基线之上则 y 更小。
                    ShapePoint(dx + ox + p.x, baseline - (oy + p.y))
                }
                raw.append(contentsOf: elements)
                placed.append((glyph.text, elements))
            }
        }
        guard let box = ShapePath.normalizedReportingBounds(raw),
              let bounds = ShapePath.curveBounds(raw) else { return nil }
        let spanW = bounds.maxX - bounds.minX
        let spanH = bounds.maxY - bounds.minY
        let glyphs = placed.compactMap { item -> TextGlyphBox? in
            guard let b = ShapePath.curveBounds(item.elements), spanW > 0, spanH > 0 else { return nil }
            return TextGlyphBox(text: item.text,
                                x: (b.minX - bounds.minX) / spanW,
                                y: (b.minY - bounds.minY) / spanH,
                                width: (b.maxX - b.minX) / spanW,
                                height: (b.maxY - b.minY) / spanH)
        }
        return TextOutline(path: box.path, widthEm: box.width / fontSize, heightEm: box.height / fontSize,
                           glyphs: glyphs)
    }

    private static func transformed(_ elements: [ShapePath.Element],
                                    _ f: (ShapePoint) -> ShapePoint) -> [ShapePath.Element] {
        elements.map { e in
            switch e {
            case .move(let p): return .move(f(p))
            case .line(let p): return .line(f(p))
            case .quad(let c, let p): return .quad(f(c), f(p))
            case .cubic(let a, let b, let p): return .cubic(f(a), f(b), f(p))
            case .close: return .close
            }
        }
    }
}
