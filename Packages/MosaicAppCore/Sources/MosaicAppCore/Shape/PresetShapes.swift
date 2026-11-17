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
