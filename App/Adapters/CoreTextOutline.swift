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
        let placements = lines.map { Self.placement(of: Self.line(for: $0, font: font)) }
        return TextOutlineAssembler.assemble(lines: placements)
    }

    /// 设计点名 `UIFont.systemFont(ofSize:weight:)`。字号查询留在主线程：新 SDK 上 UIFont 可能标了 MainActor，
    /// 协议方法本身不能改成 async。已经在主线程就直接取，避免 `main.sync` 把自己卡死。
    private static func systemHeavyFont(size: CGFloat) -> CTFont {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIFont.systemFont(ofSize: size, weight: .heavy) as CTFont
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                UIFont.systemFont(ofSize: size, weight: .heavy) as CTFont
            }
        }
    }

    private static func line(for text: String, font: CTFont) -> CTLine {
        let cf = text as CFString
        let length = CFStringGetLength(cf)
        let mutable = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(mutable, CFRange(location: 0, length: 0), cf)
        CFAttributedStringSetAttribute(mutable, CFRange(location: 0, length: length), kCTFontAttributeName, font)
        return CTLineCreateWithAttributedString(mutable)
    }

    private static func placement(of line: CTLine) -> TextLinePlacement {
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
            glyphIDs.withUnsafeMutableBufferPointer { ids in
                positions.withUnsafeMutableBufferPointer { points in
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), ids.baseAddress!)
                    CTRunGetPositions(run, CFRange(location: 0, length: 0), points.baseAddress!)
                }
            }
            let units = CGFloat(CTFontGetUnitsPerEm(runFont))
            let scale = units > 0 ? CTFontGetSize(runFont) / units : 1
            for index in 0..<count {
                var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                  tx: positions[index].x, ty: positions[index].y)
                guard let path = CTFontCreatePathForGlyph(runFont, glyphIDs[index], &transform) else { continue }
                let elements = shapeElements(of: path)
                guard !elements.isEmpty else { continue }
                // 位置已经乘进路径，原点保持在这一行的排版原点。
                glyphs.append(TextGlyphPlacement(elements: elements, originX: 0, originY: 0))
            }
        }
        return TextLinePlacement(glyphs: glyphs, advance: Double(advance))
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
        let attributes = CTRunGetAttributes(run) as NSDictionary
        return attributes[kCTFontAttributeName] as? CTFont
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
