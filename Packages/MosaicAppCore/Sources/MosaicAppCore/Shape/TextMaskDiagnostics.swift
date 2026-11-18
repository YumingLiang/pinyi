import MosaicCore

/// 文字掩码的断笔检查（设计 §2）。P0 不自动修补：连通块变多就给出说明，由调用方记日志，测试里断言。
///
/// 「字形轮廓的连通块」按填充后的外轮廓计（孔洞不算一块）：外框深度为偶数的子路径各算一块。
/// 光栅化用 8 连通前景。块数变多说明笔画被 50% 阈值断开；变少（两笔在格子上粘在一起）不算断笔。
public enum TextMaskDiagnostics {
    /// 矢量轮廓的填充连通块数。探不到轮廓内部的子路径按一块计（只多计、不少计，避免把没断的字报成断笔）。
    public static func outlineComponentCount(_ path: ShapePath) -> Int {
        let contours = path.polygons(transform: { $0 }, tolerance: 1e-4).filter { $0.count >= 3 }
        guard !contours.isEmpty else { return 0 }
        let probes = contours.map(interiorPoint)
        var count = 0
        for i in contours.indices {
            guard let probe = probes[i] else { count += 1; continue }
            var depth = 0
            for j in contours.indices where i != j && contains(contours[j], probe) { depth += 1 }
            if depth % 2 == 0 { count += 1 }
        }
        return count
    }

    /// 掩码前景的 8 连通块数（斜角相接算连着）。
    public static func rasterComponentCount(_ mask: CellMask) -> Int {
        components(mask, foreground: true, diagonal: true).count
    }

    /// 不贴网格边的背景块数（形状内部的孔，4 连通）。
    public static func interiorHoleCount(_ mask: CellMask) -> Int {
        components(mask, foreground: false, diagonal: false).filter { !$0.touchesBorder }.count
    }

    /// 光栅化块数比轮廓块数多时的说明。没有断笔返回 `nil`。
    public static func brokenStrokeNote(rasterComponents: Int, outlineComponents: Int) -> String? {
        guard rasterComponents > outlineComponents else { return nil }
        return "text mask split strokes: raster components \(rasterComponents) > outline \(outlineComponents)"
    }

    // MARK: - 轮廓内部

    /// 从最长的一条边向轮廓内侧挪一点。确认这个点真的在轮廓内；找不到就返回 nil。
    private static func interiorPoint(_ poly: [ShapePoint]) -> ShapePoint? {
        guard poly.count >= 3 else { return nil }
        var best = 0.0
        var a = poly[0], b = poly[1]
        for i in poly.indices {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            let len2 = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
            if len2 > best { best = len2; a = p; b = q }
        }
        let dx = b.x - a.x, dy = b.y - a.y
        let len = best.squareRoot()
        guard len > 0 else { return nil }
        var area = 0.0
        for i in poly.indices {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            area += p.x * q.y - q.x * p.y
        }
        // y 向下时面积为正 = 顺时针，内侧在行进方向的右侧 (-dy, dx)。
        let sign = area >= 0 ? 1.0 : -1.0
        let ix = sign * (-dy) / len
        let iy = sign * dx / len
        let mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2
        for eps in [min(1e-3, len * 0.05), len * 0.02, 1e-4] where eps > 0 {
            let toward = ShapePoint(mx + ix * eps, my + iy * eps)
            if contains(poly, toward) { return toward }
            let away = ShapePoint(mx - ix * eps, my - iy * eps)
            if contains(poly, away) { return away }
        }
        return nil
    }

    /// 非零环绕：点在多边形内。
    private static func contains(_ poly: [ShapePoint], _ p: ShapePoint) -> Bool {
        var winding = 0
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if a.y <= p.y {
                if b.y > p.y, cross(a, b, p) > 0 { winding += 1 }
            } else if b.y <= p.y, cross(a, b, p) < 0 {
                winding -= 1
            }
        }
        return winding != 0
    }

    private static func cross(_ a: ShapePoint, _ b: ShapePoint, _ p: ShapePoint) -> Double {
        (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
    }

    // MARK: - 掩码连通块

    private struct Component { var touchesBorder: Bool }

    private static func components(_ mask: CellMask, foreground: Bool, diagonal: Bool) -> [Component] {
        let steps = diagonal ? [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
                             : [(1, 0), (-1, 0), (0, 1), (0, -1)]
        var seen = [Bool](repeating: false, count: mask.cellCount)
        var out: [Component] = []
        for start in 0..<mask.cellCount where !seen[start] && mask.isActive(start) == foreground {
            var stack = [start]
            seen[start] = true
            var touches = false
            while let i = stack.popLast() {
                let c = i % mask.columns, r = i / mask.columns
                if c == 0 || r == 0 || c == mask.columns - 1 || r == mask.rows - 1 { touches = true }
                for (dc, dr) in steps {
                    let nc = c + dc, nr = r + dr
                    guard nc >= 0, nc < mask.columns, nr >= 0, nr < mask.rows else { continue }
                    let j = nr * mask.columns + nc
                    if !seen[j], mask.isActive(j) == foreground {
                        seen[j] = true
                        stack.append(j)
                    }
                }
            }
            out.append(Component(touchesBorder: touches))
        }
        return out
    }
}
