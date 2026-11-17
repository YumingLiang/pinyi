import Foundation
@testable import MosaicAppCore
import MosaicCore

/// 形状测试的小工具。
enum ShapeTestSupport {
    /// 4 连通的前景连通块数。
    static func foregroundComponents(_ m: CellMask) -> Int {
        components(m, foreground: true).count
    }

    /// 不接触网格边界的背景连通块（= 形状内部的孔）的格数列表。
    static func interiorHoles(_ m: CellMask) -> [Int] {
        components(m, foreground: false).filter { !$0.touchesBorder }.map(\.size)
    }

    struct Component { var size: Int; var touchesBorder: Bool }

    static func components(_ m: CellMask, foreground: Bool) -> [Component] {
        var seen = [Bool](repeating: false, count: m.cellCount)
        var out: [Component] = []
        for start in 0..<m.cellCount where !seen[start] && m.isActive(start) == foreground {
            var stack = [start]
            seen[start] = true
            var comp = Component(size: 0, touchesBorder: false)
            while let i = stack.popLast() {
                comp.size += 1
                let c = i % m.columns, r = i / m.columns
                if c == 0 || r == 0 || c == m.columns - 1 || r == m.rows - 1 { comp.touchesBorder = true }
                for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nc = c + dc, nr = r + dr
                    guard nc >= 0, nc < m.columns, nr >= 0, nr < m.rows else { continue }
                    let j = nr * m.columns + nc
                    if !seen[j] && m.isActive(j) == foreground {
                        seen[j] = true
                        stack.append(j)
                    }
                }
            }
            out.append(comp)
        }
        return out
    }

    /// 左右镜像后不一致的格子数（只数形状内格子并集）。
    static func mirrorXMismatch(_ m: CellMask) -> Int {
        var n = 0
        for r in 0..<m.rows {
            for c in 0..<m.columns where m.isActive(column: c, row: r) != m.isActive(column: m.columns - 1 - c, row: r) { n += 1 }
        }
        return n
    }

    /// 上下镜像后不一致的格子数。
    static func mirrorYMismatch(_ m: CellMask) -> Int {
        var n = 0
        for r in 0..<m.rows {
            for c in 0..<m.columns where m.isActive(column: c, row: r) != m.isActive(column: c, row: m.rows - 1 - r) { n += 1 }
        }
        return n
    }

    /// 形状内格数占「路径外接框所占格数」的比例。
    static func fillRatio(_ g: ShapeLayoutRules.ShapeGrid) -> Double {
        Double(g.mask.activeCount) / (g.raster.fitWidth * g.raster.fitHeight)
    }

    /// 测试用路径：正方形、圆。
    static var square: ShapePath {
        var b = ShapePathBuilder()
        b.polygon([ShapePoint(0, 0), ShapePoint(1, 0), ShapePoint(1, 1), ShapePoint(0, 1)])
        return b.build()
    }

    static var circle: ShapePath {
        var b = ShapePathBuilder()
        b.circle(0, 0, 1)
        return b.build()
    }

    /// 带孔的「回」字形（外框正向、内框反向）。
    static var ringSquare: ShapePath {
        var b = ShapePathBuilder()
        b.polygon([ShapePoint(0, 0), ShapePoint(10, 0), ShapePoint(10, 10), ShapePoint(0, 10)])
        // 反向内框（手写，不经 polygon 自动调向）。
        b.move(3, 3); b.line(3, 7); b.line(7, 7); b.line(7, 3); b.close()
        return b.build()
    }

    /// 合成照片颜色：围绕某个色相角（度）的一簇。
    static func cluster(hueDegrees: Double, chroma: Float, count: Int, seed: UInt64) -> [OKLab] {
        var x = seed &+ 0x9E37_79B9_7F4A_7C15
        func next() -> Float {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return Float(x % 10_000) / 10_000
        }
        return (0..<count).map { _ in
            let h = (hueDegrees + Double(next() - 0.5) * 16) * Double.pi / 180
            let c = chroma * (0.8 + 0.4 * next())
            let l = 0.35 + 0.4 * next()
            return OKLab(L: l, a: c * Float(cos(h)), b: c * Float(sin(h)))
        }
    }

    static func hueDegrees(_ c: OKLab) -> Double {
        var h = atan2(Double(c.b), Double(c.a)) * 180 / Double.pi
        if h < 0 { h += 360 }
        return h
    }

    static func hueGap(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
