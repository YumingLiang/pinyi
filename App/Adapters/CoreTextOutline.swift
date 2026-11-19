import Foundation
import MosaicAppCore

#if canImport(CoreText) && canImport(UIKit)
import CoreText
import UIKit

/// 用系统字体把 1–2 行文字变成 `TextOutline`（设计 §1）。
///
/// - 字体：`UIFont.systemFont(ofSize: 100, weight: .heavy)`。不写字体名，中文由系统回退到苹方。
/// - 每行一个 `CTLine`（不用 CTFramesetter 的行距）。逐 glyph `CTFontCreatePathForGlyph`，回退字体用该 run 自己的 CTFont。
/// - 多行居中、行距 1.15 em、y 向下、归一化都在 `TextOutlineAssembler`（纯 Swift，Linux 已测）。
/// - 取不到任何轮廓返回 `nil`。
struct CoreTextOutline: TextOutlineProviding {
    func outline(lines: [String]) -> TextOutline? {
        let size = CGFloat(TextOutlineAssembler.fontSizePoints)
        let font = Self.systemHeavyFont(size: size)
        let placements = lines.map { Self.placement(of: Self.line(for: $0, font: font), text: $0) }
        return TextOutlineAssembler.assemble(lines: placements)
    }

    /// 设计点名 `UIFont.systemFont(ofSize:weight:)`。取字体留在主线程。
    /// `MainActor.assumeIsolated` 的返回值必须是 Sendable，而 Xcode 26.6 的 `CTFont` 不是，
    /// 所以不能把 `CTFont` 当这个闭包的返回值（PR #26，run 44218303801）。
    private static func systemHeavyFont(size: CGFloat) -> CTFont {
        final class Holder: @unchecked Sendable {
            var font: CTFont?
        }
        let holder = Holder()
        let fill = {
            holder.font = UIFont.systemFont(ofSize: size, weight: .heavy) as CTFont
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(fill)
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated(fill) }
        }
        guard let font = holder.font else { preconditionFailure("system heavy font") }
        return font
    }

    private static func line(for text: String, font: CTFont) -> CTLine {
        let cf = text as CFString
        let length = CFStringGetLength(cf)
        let mutable = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(mutable, CFRange(location: 0, length: 0), cf)
        CFAttributedStringSetAttribute(mutable, CFRange(location: 0, length: length), kCTFontAttributeName, font)
        return CTLineCreateWithAttributedString(mutable)
    }

    private static func placement(of line: CTLine, text: String) -> TextLinePlacement {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        var glyphs: [TextGlyphPlacement] = []
        for run in runs(of: line) {
            guard let runFont = font(of: run) else { continue }
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphIDs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var stringIndices = [CFIndex](repeating: 0, count: count)
            glyphIDs.withUnsafeMutableBufferPointer { ids in
                positions.withUnsafeMutableBufferPointer { points in
                    stringIndices.withUnsafeMutableBufferPointer { indices in
                        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), ids.baseAddress!)
                        CTRunGetPositions(run, CFRange(location: 0, length: 0), points.baseAddress!)
                        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), indices.baseAddress!)
                    }
                }
            }
            for index in 0..<count {
                // 路径已经按字号从字体单位变成点，再乘 size/unitsPerEm 会把曲线缩到约 1/10。
                // 3805a68 上满月快乐因此只有约 2 格，而 cellsPerEm 仍是名义值 27.44。这里只平移到字形原点。
                var transform = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                guard let path = CTFontCreatePathForGlyph(runFont, glyphIDs[index], &transform) else { continue }
                let elements = shapeElements(of: path)
                guard !elements.isEmpty else { continue }
                // 位置已经乘进路径，原点保持在这一行的排版原点。
                glyphs.append(TextGlyphPlacement(elements: elements, originX: 0, originY: 0,
                                                  text: label(in: text, utf16Index: stringIndices[index])))
            }
        }
        return TextLinePlacement(glyphs: glyphs, advance: Double(advance))
    }

    private static func label(in text: String, utf16Index: CFIndex) -> String {
        let ns = text as NSString
        guard utf16Index >= 0, utf16Index < ns.length else { return "" }
        let range = ns.rangeOfComposedCharacterSequence(at: utf16Index)
        guard range.location != NSNotFound, range.length > 0 else { return "" }
        return ns.substring(with: range)
    }

    private static func runs(of line: CTLine) -> [CTRun] {
        let array = CTLineGetGlyphRuns(line)
        let count = CFArrayGetCount(array)
        var out: [CTRun] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            out.append(Unmanaged<CTRun>.fromOpaque(pointer).takeUnretainedValue())
        }
        return out
    }

    private static func font(of run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run)
        let key = Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
        guard let raw = CFDictionaryGetValue(attributes, key) else { return nil }
        // CFDictionaryGetValue 给的是 UnsafeRawPointer。CFGetTypeID 要类实例，直接传入会在警告即错误下失败。
        let typed = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(typed) == CTFontGetTypeID() else { return nil }
        return Unmanaged<CTFont>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func shapeElements(of path: CGPath) -> [ShapePath.Element] {
        var out: [ShapePath.Element] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                out.append(.move(point(element.points[0])))
            case .addLineToPoint:
                out.append(.line(point(element.points[0])))
            case .addQuadCurveToPoint:
                out.append(.quad(point(element.points[0]), point(element.points[1])))
            case .addCurveToPoint:
                out.append(.cubic(point(element.points[0]), point(element.points[1]), point(element.points[2])))
            case .closeSubpath:
                out.append(.close)
            @unknown default:
                break
            }
        }
        return out
    }

    private static func point(_ p: CGPoint) -> ShapePoint {
        ShapePoint(Double(p.x), Double(p.y))
    }
}
#endif
