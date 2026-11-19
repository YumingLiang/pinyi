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

/// 输入框拒绝这次修改时给界面的提示。不是生成失败。
public enum TextInputNotice: Sendable, Hashable {
    case unsupported
    case lineTooLong(line: Int)
    case tooManyLines
    /// 字符合法，但轮廓排不开或不够 24 格。不缩小、不截断。
    case unreadable

    public var key: L10nKey {
        switch self {
        case .unsupported: return .shapeTextUnsupported
        case .lineTooLong: return .shapeTextTooLong
        case .tooManyLines: return .shapeTextTooManyLines
        case .unreadable: return .shapeTextUnreadable
        }
    }
}

/// 配置页两行输入。超限、emoji 整次不写入，并给出提示；不把多余的字悄悄留下。
public enum TextDraftEditor {
    public static func normalized(_ lines: [String]) -> [String] {
        var slots = lines
        if slots.count > ShapeTextRules.maxLines { slots = Array(slots.prefix(ShapeTextRules.maxLines)) }
        while slots.count < ShapeTextRules.maxLines { slots.append("") }
        return slots
    }

    /// 去掉空行后的正文。空数组表示还不能生成。
    public static func committedLines(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 改一行。真实换行只允许从第一行落到第二行。拒绝时原文不动。
    public static func apply(lines: [String], index: Int, proposed: String) -> (lines: [String], notice: TextInputNotice?) {
        let current = normalized(lines)
        guard index == 0 || index == 1 else { return (current, .tooManyLines) }
        if proposed == current[index] { return (current, nil) }
        if proposed.contains("\n") || proposed.contains("\r") {
            guard index == 0 else { return (current, .tooManyLines) }
            var split = TextComposition.lines(from: proposed)
            if split.count > ShapeTextRules.maxLines, split.last?.isEmpty == true { split.removeLast() }
            if split.count > ShapeTextRules.maxLines { return (current, .tooManyLines) }
            let first = split.first ?? ""
            let second = split.count > 1 ? split[1] : ""
            if let notice = problem(first, index: 0) ?? problem(second, index: 1) { return (current, notice) }
            return ([first, second], nil)
        }
        if let notice = problem(proposed, index: index) { return (current, notice) }
        var next = current
        next[index] = proposed
        return (next, nil)
    }

    private static func problem(_ line: String, index: Int) -> TextInputNotice? {
        if line.isEmpty { return nil }
        let filtered = ShapeTextRules.filter(line)
        if filtered.droppedUnsupported || filtered.text != line { return .unsupported }
        if ShapeTextRules.units(line) > ShapeTextRules.maxUnitsPerLine { return .lineTooLong(line: index) }
        return nil
    }
}

/// 输入控件和正文之间的边界。组合态不写入、也不当成错误拒绝。
public enum TextInputBridge {
    public struct Outcome: Equatable, Sendable {
        public var lines: [String]
        public var notice: TextInputNotice?
        /// 输入法还在组合。调用方应保持现有正文和提示，不要按 `fieldText` 更新。
        public var composing: Bool
    }

    public static func receive(lines: [String], index: Int, fieldText: String, hasMarkedText: Bool) -> Outcome {
        let current = TextDraftEditor.normalized(lines)
        if hasMarkedText {
            return Outcome(lines: current, notice: nil, composing: true)
        }
        let applied = TextDraftEditor.apply(lines: current, index: index, proposed: fieldText)
        return Outcome(lines: applied.lines, notice: applied.notice, composing: false)
    }

    /// 没有组合态时，换行不交给单行控件插入，由正文规则整次接收。
    public static func shouldInsert(replacement: String, hasMarkedText: Bool) -> Bool {
        if hasMarkedText { return true }
        return !(replacement.contains("\n") || replacement.contains("\r"))
    }

    /// 用 UTF-16 范围拼接。系统输入框的 `range` 是这个单位。
    public static func replacing(_ current: String, utf16Range: NSRange, with replacement: String) -> String {
        let ns = current as NSString
        guard utf16Range.location != NSNotFound, utf16Range.location >= 0,
              NSMaxRange(utf16Range) <= ns.length else { return current }
        return ns.replacingCharacters(in: utf16Range, with: replacement)
    }
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

    /// 汉字字形自己的外接框两边都要到 24 格。没有字形边界时不拿整行宽度冒充。
    public static func requireReadableHanzi(_ outline: TextOutline) throws {
        let boxes = try ShapeLayoutRules.glyphCellBoxes(outline)
        let hanzi = boxes.filter { ShapeTextRules.units($0.text) >= 1 }
        if hanzi.isEmpty, outline.glyphs.contains(where: { ShapeTextRules.units($0.text) >= 1 }) {
            throw TextComposeFailure.noOutline
        }
        for box in hanzi where box.width < ShapeLayoutRules.minimumCellsPerEm
            || box.height < ShapeLayoutRules.minimumCellsPerEm {
            throw TextComposeFailure.glyphTooSmall(text: box.text, width: box.width, height: box.height)
        }
        if try !ShapeLayoutRules.meetsMinimumCellsPerEm(outline) {
            throw TextComposeFailure.glyphTooSmall(text: "", width: try ShapeLayoutRules.cellsPerEm(outline), height: 0)
        }
    }
}
