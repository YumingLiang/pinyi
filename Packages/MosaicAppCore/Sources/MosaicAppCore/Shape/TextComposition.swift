import Foundation

/// 一次文字生成要用的轮廓。密度不在这里，生成时固定细档。
public struct PreparedTextMosaic: Sendable, Equatable {
    public var lines: [String]
    public var outline: TextOutline
    public var palette: ShapePalette
    public var background: ShapeBackground

    public init(lines: [String], outline: TextOutline, palette: ShapePalette, background: ShapeBackground) {
        self.lines = lines
        self.outline = outline
        self.palette = palette
        self.background = background
    }
}

/// 文字生成前的明确失败。不静默删字、不截断、不改成更粗的格子。
public enum TextComposeFailure: Error, Equatable {
    case empty
    case tooManyLines
    case lineTooLong(line: Int)
    case unsupported
    case noOutline
    case glyphTooSmall(text: String, width: Double, height: Double)
    /// 按固定每 em 格数放不进 120 格，拒绝缩小。
    case doesNotFit
}

/// 把调用方给出的行整理成可以排版的文字。合法换行保留成两行。
public enum TextComposition {
    /// 正式四组里的两行用真实换行拆开，不把反斜杠和 n 当成换行。
    public static func lines(from raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// 不丢字符。空、超行、超字、emoji 或不支持的字符都返回对应失败。
    public static func prepare(_ lines: [String]) throws -> [String] {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if trimmed.isEmpty { throw TextComposeFailure.empty }
        for line in trimmed {
            for ch in line {
                let filtered = ShapeTextRules.filter(String(ch))
                if filtered.droppedUnsupported || filtered.text != String(ch) {
                    throw TextComposeFailure.unsupported
                }
            }
        }
        switch ShapeTextRules.validate(lines: trimmed) {
        case .ok: return trimmed
        case .empty: throw TextComposeFailure.empty
        case .tooManyLines: throw TextComposeFailure.tooManyLines
        case .lineTooLong(let line): throw TextComposeFailure.lineTooLong(line: line)
        }
    }

    /// 光栅后的 `cellsPerEm` 必须 ≥ 24（design/shape-mosaic-v0.1.md:39、:56–57；
    /// qa/shape-mosaic-test-checklist.md:27）。逐字墨水宽高只供诊断，窄字如「月」不因此拒绝。
    /// 汉字声明了却没有曲线边界，或 `cellsPerEm` 真的不足，仍然明确失败。
    public static func requireReadableHanzi(_ outline: TextOutline) throws {
        if outline.glyphs.contains(where: { ShapeTextRules.units($0.text) >= 1 }) {
            let boxes = try ShapeLayoutRules.glyphCellBoxes(outline)
            if !boxes.contains(where: { ShapeTextRules.units($0.text) >= 1 }) {
                throw TextComposeFailure.noOutline
            }
        }
        let perEm = try ShapeLayoutRules.cellsPerEm(outline)
        if perEm < ShapeLayoutRules.minimumCellsPerEm {
            throw TextComposeFailure.glyphTooSmall(text: "", width: perEm, height: perEm)
        }
    }
}
