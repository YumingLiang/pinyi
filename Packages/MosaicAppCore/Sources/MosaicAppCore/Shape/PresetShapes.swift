import Foundation

// 10 个自制形状（需求 1a；设计 shape-mosaic-v0.1 §1）：代码写贝塞尔，不用 SF Symbols、不放图片。
// 设计约束：最细处 ≥ 外接框短边的 7%（粗档 40 格时约 2.8 格），内部不留小于 10% 的孔。
// 所有子路径统一正向（视觉顺时针），叠在一起按非零环绕就是并集。
//
// 注册表：每个形状一条 `Entry`。要砍掉某个形状，只删它的那一行登记（和下面对应的路径函数）即可，
// 其余代码（`ShapePresetID.all`、解码校验、测试遍历）都从注册表读。

/// 预设形状注册表。
public enum PresetShapes {
    /// 一条登记。
    public struct Entry: Sendable {
        public let id: ShapePresetID
        public let path: ShapePath
    }

    /// 已登记的形状（按实现顺序：爱心、星星、圆形、生日蛋糕、花朵，然后月亮、四叶草、小房子、对话框、圆角方块）。
    public static let registry: [Entry] = [
        Entry(id: .heart, path: heart()),
        Entry(id: .star, path: star()),
        Entry(id: .circle, path: circle()),
        Entry(id: .birthdayCake, path: birthdayCake()),
        Entry(id: .flower, path: flower()),
        Entry(id: .moon, path: moon()),
        Entry(id: .fourLeafClover, path: fourLeafClover()),
        Entry(id: .house, path: house()),
        Entry(id: .speechBubble, path: speechBubble()),
        Entry(id: .roundedSquare, path: roundedSquare()),
    ]

    /// 预设形状的路径；未登记返回 `nil`。
    public static func path(for id: ShapePresetID) -> ShapePath? {
        registry.first { $0.id == id }?.path
    }
}

// MARK: - 爱心

extension ShapePresetID {
    /// 爱心
    public static let heart = ShapePresetID(rawValue: "heart")
}

extension PresetShapes {
    /// 爱心：左右对称，两个圆润的上瓣 + 下尖（100 × 95 单位）。
    static func heart() -> ShapePath {
        var b = ShapePathBuilder()
        b.move(50, 26)
        b.cubic(50, 10, 62, 0, 75, 0)
        b.cubic(90, 0, 100, 12, 100, 28)
        b.cubic(100, 55, 70, 72, 50, 95)
        b.cubic(30, 72, 0, 55, 0, 28)
        b.cubic(0, 12, 10, 0, 25, 0)
        b.cubic(38, 0, 50, 10, 50, 26)
        b.close()
        return b.build()
    }
}

// MARK: - 星星

extension ShapePresetID {
    /// 星星
    public static let star = ShapePresetID(rawValue: "star")
}

extension PresetShapes {
    /// 星星：五角星，尖朝上，内外半径比 0.45（比标准 0.382 胖一点）；五个尖用二次曲线略微磨圆，粗档下尖端不碎。
    static func star() -> ShapePath {
        var b = ShapePathBuilder()
        var pts: [ShapePoint] = []
        for k in 0..<10 {
            let angle = (-90 + 36 * Double(k)) * Double.pi / 180
            let r = k % 2 == 0 ? 50.0 : 22.5
            pts.append(ShapePoint(50 + r * cos(angle), 50 + r * sin(angle)))
        }
        // 每个外尖：从入边上距尖 5 个单位处，用二次曲线（控制点 = 尖）连到出边上同样位置。
        func toward(_ from: ShapePoint, _ to: ShapePoint, _ d: Double) -> ShapePoint {
            let dx = to.x - from.x, dy = to.y - from.y
            let len = (dx * dx + dy * dy).squareRoot()
            return ShapePoint(from.x + dx / len * d, from.y + dy / len * d)
        }
        let tip = 5.0
        b.move(pts[1].x, pts[1].y)
        for k in stride(from: 2, through: 10, by: 2) {
            let p = pts[k % 10], prev = pts[k - 1], next = pts[(k + 1) % 10]
            let a = toward(p, prev, tip), c = toward(p, next, tip)
            b.line(a.x, a.y)
            b.quad(p.x, p.y, c.x, c.y)
            b.line(next.x, next.y)
        }
        b.close()
        return b.build()
    }
}

// MARK: - 圆形

extension ShapePresetID {
    /// 圆形
    public static let circle = ShapePresetID(rawValue: "circle")
}

extension PresetShapes {
    /// 圆形。
    static func circle() -> ShapePath {
        var b = ShapePathBuilder()
        b.circle(50, 50, 50)
        return b.build()
    }
}

// MARK: - 生日蛋糕

extension ShapePresetID {
    /// 生日蛋糕
    public static let birthdayCake = ShapePresetID(rawValue: "birthdayCake")
}

extension PresetShapes {
    /// 生日蛋糕：上下两层 + 3 根蜡烛 + 火苗（火苗压在蜡烛顶上，整体连通）。
    /// 蜡烛宽 7、火苗宽 13、相邻火苗间隙 7（都约为外接框的 7% 以上），粗档也不会断开或粘连。
    static func birthdayCake() -> ShapePath {
        var b = ShapePathBuilder()
        b.roundedRect(x: 4, y: 62, width: 92, height: 34, radius: 5)   // 下层
        b.roundedRect(x: 16, y: 38, width: 68, height: 26, radius: 5)  // 上层（与下层重叠 2）
        for cx in [30.0, 50.0, 70.0] {
            b.polygon([ShapePoint(cx - 3.5, 22), ShapePoint(cx + 3.5, 22), ShapePoint(cx + 3.5, 40), ShapePoint(cx - 3.5, 40)])
            // 火苗：上尖下圆的水滴，底部压进蜡烛顶 2 个单位。
            b.move(cx, 0)
            b.cubic(cx + 3, 6, cx + 6.5, 10, cx + 6.5, 16)
            b.cubic(cx + 6.5, 21, cx + 3.5, 24, cx, 24)
            b.cubic(cx - 3.5, 24, cx - 6.5, 21, cx - 6.5, 16)
            b.cubic(cx - 6.5, 10, cx - 3, 6, cx, 0)
            b.close()
        }
        return b.build()
    }
}

// MARK: - 花朵

extension ShapePresetID {
    /// 花朵
    public static let flower = ShapePresetID(rawValue: "flower")
}

extension PresetShapes {
    /// 花朵：5 片椭圆花瓣（沿径向长 40、横向宽 26，一片朝上）+ 花心（半径 16），左右对称。
    /// 花瓣中心离花心 30（从半径 10 伸到 50），相邻花瓣在半径约 18 以外就分开、互不重叠，只靠花心连在一起，
    /// 所以花瓣之间的凹口一直凹到花心附近（外缘半径 50 → 约 18），粗档也能数出 5 片（产品 11-17）。
    static func flower() -> ShapePath {
        var petal = ShapePathBuilder()
        petal.ellipse(0, 0, 20, 13)   // 长轴沿 x（径向）
        var b = ShapePathBuilder()
        let dist = 30.0
        for k in 0..<5 {
            let angle = (-90 + 72 * Double(k)) * Double.pi / 180
            let c = cos(angle), sn = sin(angle)
            b.append(petal.elements) { p in
                let x = p.x + dist
                return ShapePoint(50 + x * c - p.y * sn, 50 + x * sn + p.y * c)
            }
        }
        b.circle(50, 50, 16)
        return b.build()
    }
}

// MARK: - 月亮

extension ShapePresetID {
    /// 月亮
    public static let moon = ShapePresetID(rawValue: "moon")
}

extension PresetShapes {
    /// 月亮：弯月，开口朝右，上下对称。外圆 C1（圆心 0,0，半径 50）去掉内圆 C2（圆心 22,0，半径 44）；
    /// 直接写成一条闭合轮廓（外弧 + 内弧），不靠反向子路径挖孔。中间最厚处 28（外接框高的 28%）。
    static func moon() -> ShapePath {
        var b = ShapePathBuilder()
        let r1 = 50.0, cx2 = 22.0, r2 = 44.0
        // 两圆交点：x = (r1² − r2² + cx2²) / (2 cx2)，y = ±√(r1² − x²)。
        let ix = (r1 * r1 - r2 * r2 + cx2 * cx2) / (2 * cx2)
        let iy = (r1 * r1 - ix * ix).squareRoot()
        let deg = 180 / Double.pi
        let a1 = atan2(iy, ix) * deg                 // 外圆上交点（下方）的角度
        let a2 = atan2(iy, ix - cx2) * deg           // 内圆上同一点的角度
        b.move(ix, iy)
        // 外弧：从下交点顺时针（角度增大）经左侧到上交点。
        b.arc(0, 0, r1, from: a1, to: 360 - a1)
        // 内弧：从上交点（内圆角度 360 − a2）逆向回到下交点（a2），走内圆左侧。
        b.arc(cx2, 0, r2, from: 360 - a2, to: a2)
        b.close()
        return b.build()
    }
}

// MARK: - 四叶草

extension ShapePresetID {
    /// 四叶草
    public static let fourLeafClover = ShapePresetID(rawValue: "fourLeafClover")
}

extension PresetShapes {
    /// 四叶草：4 片窄心形叶子（叶尖朝中心，上 / 右 / 下 / 左，各占一个 90° 扇区、彼此不重叠）
    /// + 中心圆把叶子连起来 + 向右下的叶柄（宽 8）。
    static func fourLeafClover() -> ShapePath {
        // 叶子：爱心路径，叶尖 (50, 95) 平移到原点，横向缩 0.34、纵向缩 0.47（窄叶，叶片朝上）。
        var leaf = ShapePathBuilder()
        leaf.move(50, 26)
        leaf.cubic(50, 10, 62, 0, 75, 0)
        leaf.cubic(90, 0, 100, 12, 100, 28)
        leaf.cubic(100, 55, 70, 72, 50, 95)
        leaf.cubic(30, 72, 0, 55, 0, 28)
        leaf.cubic(0, 12, 10, 0, 25, 0)
        leaf.cubic(38, 0, 50, 10, 50, 26)
        leaf.close()
        var b = ShapePathBuilder()
        let sx = 0.34, sy = 0.47
        for k in 0..<4 {
            let angle = Double(k) * Double.pi / 2
            let c = cos(angle), sn = sin(angle)
            b.append(leaf.elements) { p in
                let x = (p.x - 50) * sx, y = (p.y - 95) * sy
                return ShapePoint(x * c - y * sn, x * sn + y * c)
            }
        }
        b.circle(0, 0, 13)
        // 叶柄：从中心斜向右下（朝右下两片叶子之间）。
        let end = ShapePoint(30, 52), half = 4.0
        let len = (end.x * end.x + end.y * end.y).squareRoot()
        let nx = -end.y / len * half, ny = end.x / len * half
        b.polygon([ShapePoint(nx, ny), ShapePoint(-nx, -ny), ShapePoint(end.x - nx, end.y - ny), ShapePoint(end.x + nx, end.y + ny)])
        return b.build()
    }
}

// MARK: - 小房子

extension ShapePresetID {
    /// 小房子
    public static let house = ShapePresetID(rawValue: "house")
}

extension PresetShapes {
    /// 小房子：三角屋顶（两侧出檐）+ 方形墙体 + 右侧烟囱。不挖门窗（内部不留孔）。
    static func house() -> ShapePath {
        var b = ShapePathBuilder()
        b.polygon([ShapePoint(0, 50), ShapePoint(50, 6), ShapePoint(100, 50)])                         // 屋顶
        b.polygon([ShapePoint(14, 46), ShapePoint(86, 46), ShapePoint(86, 96), ShapePoint(14, 96)])    // 墙体（与屋顶重叠）
        b.polygon([ShapePoint(66, 10), ShapePoint(79, 10), ShapePoint(79, 38), ShapePoint(66, 38)])    // 烟囱（下端压进屋顶）
        return b.build()
    }
}

// MARK: - 对话框

extension ShapePresetID {
    /// 对话框
    public static let speechBubble = ShapePresetID(rawValue: "speechBubble")
}

extension PresetShapes {
    /// 对话框：圆角矩形气泡 + 左下方的尾巴。
    static func speechBubble() -> ShapePath {
        var b = ShapePathBuilder()
        b.roundedRect(x: 0, y: 0, width: 100, height: 70, radius: 16)
        b.polygon([ShapePoint(20, 62), ShapePoint(42, 62), ShapePoint(14, 92)])
        return b.build()
    }
}

// MARK: - 圆角方块

extension ShapePresetID {
    /// 圆角方块
    public static let roundedSquare = ShapePresetID(rawValue: "roundedSquare")
}

extension PresetShapes {
    /// 圆角方块：正方形，圆角半径 = 边长的 20%。
    static func roundedSquare() -> ShapePath {
        var b = ShapePathBuilder()
        b.roundedRect(x: 0, y: 0, width: 100, height: 100, radius: 20)
        return b.build()
    }
}
