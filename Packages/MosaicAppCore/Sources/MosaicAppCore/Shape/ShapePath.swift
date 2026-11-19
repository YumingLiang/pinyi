import Foundation

// 形状 / 文字拼图的矢量路径（设计 shape-mosaic-v0.1 §1）。纯数据、纯 Swift，Linux 可测。
// 预设形状由 `PresetShapes` 用代码写贝塞尔；文字轮廓由 App 层 `TextOutlineProviding`（CoreText）转成同一种 `ShapePath`。
// 之后一律走 `PathRasterizer`，路径是形状的唯一事实来源。

/// 路径上的点（归一化坐标，y 向下）。
public struct ShapePoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// `ShapePath.normalized` 的结果，外加归一化前曲线外接框的宽和高（与 `path.aspect` 同一套细分）。
public struct NormalizedShapePath: Sendable, Equatable {
    public var path: ShapePath
    public var width: Double
    public var height: Double

    public init(path: ShapePath, width: Double, height: Double) {
        self.path = path
        self.width = width
        self.height = height
    }
}

/// 归一化到 0…1 的路径（y 向下，外接框左上 = (0, 0)、右下 = (1, 1)），**非零环绕**填充。
/// `aspect` 是外接框 宽 / 高：光栅化时按它等比放进网格。
public struct ShapePath: Codable, Sendable, Equatable {
    /// 路径元素。每个 `move` 开启一个子路径；子路径在下一个 `move` 或末尾处自动闭合。
    public enum Element: Codable, Sendable, Equatable {
        case move(ShapePoint)
        case line(ShapePoint)
        case quad(ShapePoint, ShapePoint)
        case cubic(ShapePoint, ShapePoint, ShapePoint)
        case close
    }

    public var elements: [Element]
    /// 外接框 宽 / 高（> 0）。
    public var aspect: Double

    public init(elements: [Element], aspect: Double) {
        self.elements = elements
        self.aspect = aspect
    }

    /// 把任意单位的路径归一化：按**曲线实际外接框**（细分后求）平移、缩放到 0…1，并记下宽高比。
    /// 空路径或退化（宽或高为 0）返回 `nil`。
    public static func normalized(_ raw: [Element]) -> ShapePath? {
        normalizedReportingBounds(raw)?.path
    }

    /// `normalized` 的同一结果，并带回归一化前的曲线外接框宽高。
    /// 文字轮廓用它把外接框换成 em（`TextOutlineAssembler`），宽高比与 `path.aspect` 是同一套细分。
    /// 曲线细分后的外接框。控制点不计入，避免把字号估大。
    public static func curveBounds(_ raw: [Element]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        let polys = flatten(raw, transform: { $0 }, tolerance: 1e-4 * max(1, rawExtent(raw)))
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for poly in polys {
            for p in poly {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard minX.isFinite, maxX > minX, maxY > minY else { return nil }
        return (minX, minY, maxX, maxY)
    }

    public static func normalizedReportingBounds(_ raw: [Element]) -> NormalizedShapePath? {
        guard let b = curveBounds(raw) else { return nil }
        let minX = b.minX, minY = b.minY, maxX = b.maxX, maxY = b.maxY
        let w = maxX - minX, h = maxY - minY
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
        func n(_ p: ShapePoint) -> ShapePoint { ShapePoint((p.x - minX) / w, (p.y - minY) / h) }
        let elements: [Element] = raw.map { e in
            switch e {
            case .move(let p): return .move(n(p))
            case .line(let p): return .line(n(p))
            case .quad(let c, let p): return .quad(n(c), n(p))
            case .cubic(let c1, let c2, let p): return .cubic(n(c1), n(c2), n(p))
            case .close: return .close
            }
        }
        return NormalizedShapePath(path: ShapePath(elements: elements, aspect: w / h), width: w, height: h)
    }

    /// 细分成闭合多边形（每个子路径一个，首尾不重复）。`transform` 把归一化坐标映射到目标坐标（例如格子坐标），
    /// `tolerance` 是在**目标坐标**下允许的最大弦高误差。
    public func polygons(transform: (ShapePoint) -> ShapePoint, tolerance: Double) -> [[ShapePoint]] {
        ShapePath.flatten(elements, transform: transform, tolerance: tolerance)
    }

    // MARK: - 细分

    private static func rawExtent(_ raw: [Element]) -> Double {
        var m = 0.0
        for e in raw {
            switch e {
            case .move(let p), .line(let p): m = max(m, abs(p.x), abs(p.y))
            case .quad(let c, let p): m = max(m, abs(c.x), abs(c.y), abs(p.x), abs(p.y))
            case .cubic(let a, let b, let p): m = max(m, abs(a.x), abs(a.y), abs(b.x), abs(b.y), abs(p.x), abs(p.y))
            case .close: break
            }
        }
        return m
    }

    /// 贝塞尔细分段数：二阶差分上界 M，弦高误差 ≤ M / (8 n²) ≤ tolerance（三次曲线按 3/4·M 估计）。
    private static func segments(secondDiff m: Double, tolerance: Double, cubic: Bool) -> Int {
        guard m > 0, tolerance > 0 else { return 1 }
        let k = cubic ? 0.75 : 0.25
        let n = (k * m / tolerance).squareRoot().rounded(.up)
        return Int(min(512, max(1, n)))
    }

    static func flatten(_ elements: [Element], transform: (ShapePoint) -> ShapePoint, tolerance: Double) -> [[ShapePoint]] {
        var out: [[ShapePoint]] = []
        var current: [ShapePoint] = []
        var start = ShapePoint(0, 0)
        var last = ShapePoint(0, 0)
        func flush() {
            if current.count >= 2 {
                if let f = current.first, let l = current.last, f == l { current.removeLast() }
                if current.count >= 3 { out.append(current) }
            }
            current = []
        }
        func dist(_ a: ShapePoint, _ b: ShapePoint) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
        for e in elements {
            switch e {
            case .move(let p):
                flush()
                let q = transform(p)
                current = [q]
                start = q
                last = q
            case .line(let p):
                let q = transform(p)
                if current.isEmpty { current = [last] }
                current.append(q)
                last = q
            case .quad(let c, let p):
                let c1 = transform(c), p1 = transform(p)
                if current.isEmpty { current = [last] }
                let m = dist(ShapePoint(last.x - 2 * c1.x + p1.x, last.y - 2 * c1.y + p1.y), ShapePoint(0, 0))
                let n = segments(secondDiff: m, tolerance: tolerance, cubic: false)
                let p0 = last
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    current.append(ShapePoint(u * u * p0.x + 2 * u * t * c1.x + t * t * p1.x,
                                              u * u * p0.y + 2 * u * t * c1.y + t * t * p1.y))
                }
                last = p1
            case .cubic(let a, let b, let p):
                let c1 = transform(a), c2 = transform(b), p1 = transform(p)
                if current.isEmpty { current = [last] }
                let p0 = last
                let d1 = dist(ShapePoint(p0.x - 2 * c1.x + c2.x, p0.y - 2 * c1.y + c2.y), ShapePoint(0, 0))
                let d2 = dist(ShapePoint(c1.x - 2 * c2.x + p1.x, c1.y - 2 * c2.y + p1.y), ShapePoint(0, 0))
                let n = segments(secondDiff: max(d1, d2), tolerance: tolerance, cubic: true)
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
                    current.append(ShapePoint(w0 * p0.x + w1 * c1.x + w2 * c2.x + w3 * p1.x,
                                              w0 * p0.y + w1 * c1.y + w2 * c2.y + w3 * p1.y))
                }
                last = p1
            case .close:
                flush()
                last = start
            }
        }
        flush()
        return out
    }
}

/// 写预设形状用的小工具（只在本模块内用）。所有闭合子路径统一为**正向**（y 向下坐标系里鞋带面积 > 0，即视觉上顺时针），
/// 这样在非零环绕规则下多个子路径叠在一起就是并集。
struct ShapePathBuilder {
    private(set) var elements: [ShapePath.Element] = []

    /// 多边形（自动调成正向）。
    mutating func polygon(_ pts: [ShapePoint]) {
        guard pts.count >= 3 else { return }
        let ordered = Self.signedArea(pts) >= 0 ? pts : Array(pts.reversed())
        elements.append(.move(ordered[0]))
        for p in ordered.dropFirst() { elements.append(.line(p)) }
        elements.append(.close)
    }

    /// 整圆（4 段三次贝塞尔，正向）。
    mutating func circle(_ cx: Double, _ cy: Double, _ r: Double) {
        elements.append(.move(ShapePoint(cx + r, cy)))
        arc(cx, cy, r, from: 0, to: 360)
        elements.append(.close)
    }

    /// 椭圆（正向）。
    mutating func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) {
        let k = 0.5522847498
        elements.append(.move(ShapePoint(cx + rx, cy)))
        elements.append(.cubic(ShapePoint(cx + rx, cy + k * ry), ShapePoint(cx + k * rx, cy + ry), ShapePoint(cx, cy + ry)))
        elements.append(.cubic(ShapePoint(cx - k * rx, cy + ry), ShapePoint(cx - rx, cy + k * ry), ShapePoint(cx - rx, cy)))
        elements.append(.cubic(ShapePoint(cx - rx, cy - k * ry), ShapePoint(cx - k * rx, cy - ry), ShapePoint(cx, cy - ry)))
        elements.append(.cubic(ShapePoint(cx + k * rx, cy - ry), ShapePoint(cx + rx, cy - k * ry), ShapePoint(cx + rx, cy)))
        elements.append(.close)
    }

    /// 圆角矩形（正向）。
    mutating func roundedRect(x: Double, y: Double, width w: Double, height h: Double, radius: Double) {
        let r = min(radius, w / 2, h / 2)
        elements.append(.move(ShapePoint(x + r, y)))
        elements.append(.line(ShapePoint(x + w - r, y)))
        arc(x + w - r, y + r, r, from: -90, to: 0)
        elements.append(.line(ShapePoint(x + w, y + h - r)))
        arc(x + w - r, y + h - r, r, from: 0, to: 90)
        elements.append(.line(ShapePoint(x + r, y + h)))
        arc(x + r, y + h - r, r, from: 90, to: 180)
        elements.append(.line(ShapePoint(x, y + r)))
        arc(x + r, y + r, r, from: 180, to: 270)
        elements.append(.close)
    }

    /// 圆弧（角度制；y 向下时角度增大 = 视觉顺时针）。调用前当前点应在弧起点上；按 ≤ 90° 分段。
    mutating func arc(_ cx: Double, _ cy: Double, _ r: Double, from a0: Double, to a1: Double) {
        let total = a1 - a0
        let n = max(1, Int((abs(total) / 90).rounded(.up)))
        let step = total / Double(n) * Double.pi / 180
        var a = a0 * Double.pi / 180
        let k = 4.0 / 3.0 * tan(step / 4)
        for _ in 0..<n {
            let b = a + step
            let p0 = ShapePoint(cx + r * cos(a), cy + r * sin(a))
            let p3 = ShapePoint(cx + r * cos(b), cy + r * sin(b))
            let c1 = ShapePoint(p0.x - k * r * sin(a), p0.y + k * r * cos(a))
            let c2 = ShapePoint(p3.x + k * r * sin(b), p3.y - k * r * cos(b))
            elements.append(.cubic(c1, c2, p3))
            a = b
        }
    }

    mutating func move(_ x: Double, _ y: Double) { elements.append(.move(ShapePoint(x, y))) }
    mutating func line(_ x: Double, _ y: Double) { elements.append(.line(ShapePoint(x, y))) }
    mutating func cubic(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double, _ y: Double) {
        elements.append(.cubic(ShapePoint(x1, y1), ShapePoint(x2, y2), ShapePoint(x, y)))
    }
    mutating func quad(_ cx: Double, _ cy: Double, _ x: Double, _ y: Double) {
        elements.append(.quad(ShapePoint(cx, cy), ShapePoint(x, y)))
    }
    mutating func close() { elements.append(.close) }

    /// 追加另一组元素，逐点做仿射变换（旋转 / 缩放 / 平移，保持方向）。
    mutating func append(_ other: [ShapePath.Element], transform t: (ShapePoint) -> ShapePoint) {
        for e in other {
            switch e {
            case .move(let p): elements.append(.move(t(p)))
            case .line(let p): elements.append(.line(t(p)))
            case .quad(let c, let p): elements.append(.quad(t(c), t(p)))
            case .cubic(let a, let b, let p): elements.append(.cubic(t(a), t(b), t(p)))
            case .close: elements.append(.close)
            }
        }
    }

    /// 归一化成 `ShapePath`（预设形状都非空，失败即编程错误）。
    func build() -> ShapePath {
        guard let p = ShapePath.normalized(elements) else { preconditionFailure("degenerate preset shape") }
        return p
    }

    /// 鞋带面积（y 向下坐标系，正 = 视觉顺时针）。
    static func signedArea(_ pts: [ShapePoint]) -> Double {
        var s = 0.0
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }
}
