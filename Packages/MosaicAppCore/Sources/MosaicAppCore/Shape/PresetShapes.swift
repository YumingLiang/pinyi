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
    /// 花朵：5 片圆形花瓣（一片朝上）+ 花心，左右对称。
    static func flower() -> ShapePath {
        var b = ShapePathBuilder()
        let petalR = 21.0, dist = 29.0
        for k in 0..<5 {
            let angle = (-90 + 72 * Double(k)) * Double.pi / 180
            b.circle(50 + dist * cos(angle), 50 + dist * sin(angle), petalR)
        }
        b.circle(50, 50, 22)
        return b.build()
    }
}
