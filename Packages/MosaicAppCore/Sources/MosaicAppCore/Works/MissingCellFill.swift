import Foundation
import MosaicCore

/// 原照片为什么取不到（需求 4.8 第 5e 条，架构师 11-17 意见「二」）。
public enum MissingPhotoReason: Sendable, Hashable {
    /// 照片还在，但被设成了隐藏。
    case hidden
    /// 确认已删除（完整相册权限下按 ID 连隐藏照片也查不到）。
    case deleted
    /// 拿不准（受限访问 / 无权限时查不到；或查到了却不是隐藏的，属于竞态）。一律按隐藏处理。
    case unknown
}

/// 把「只读元数据」的查询结果分成隐藏 / 删除 / 拿不准。纯函数，Linux 有测试。
/// App 侧只调一次 `PhotoFetch.missingPhotoMetadata`（唯一的 includeHiddenAssets 例外，只看能不能查到、isHidden），不请求任何图像。
public enum MissingPhotoClassifier {
    /// - Parameters:
    ///   - ids: 取不到的原照片 ID。
    ///   - found: 连隐藏照片一起查时查到的 ID → `isHidden`。
    ///   - fullAccess: 完整相册权限。只有这时「查不到」才算确认删除。
    public static func classify(_ ids: Set<String>, found: [String: Bool], fullAccess: Bool) -> [String: MissingPhotoReason] {
        var out: [String: MissingPhotoReason] = [:]
        for id in ids where !id.isEmpty {
            if let hidden = found[id] {
                out[id] = hidden ? .hidden : .unknown
            } else {
                out[id] = fullAccess ? .deleted : .unknown
            }
        }
        return out
    }
}

/// 缺图格子怎么补（查看页、导出、5d 结果页、5e 后台队列共用这一处判断）。
public enum MissingCellFill: Sendable, Hashable {
    /// 用相近照片替换（4b / 5a）。
    case candidate
    /// 用旧预览裁切放大（4b，只限确认删除的照片）。
    case previewCrop
    /// 填目标图这一格的平均色（隐藏或拿不准：旧预览里就是隐藏照片的像素，不能用）。
    case targetColor

    /// - Parameters:
    ///   - reason: 原照片缺失原因；nil（例如早就是空格子、原因已不可考）按拿不准处理。
    ///   - hasCandidate: 有没有找到合格的相近照片。
    public static func decide(reason: MissingPhotoReason?, hasCandidate: Bool) -> MissingCellFill {
        if hasCandidate { return .candidate }
        switch reason {
        case .deleted: return .previewCrop
        case .hidden, .unknown, .none: return .targetColor
        }
    }

    /// 没有目标图副本时的颜色（中性灰）。正常情况下目标图副本都在（5c 保留），这只是防御。
    public static let neutral = CellColor(r: 128, g: 128, b: 128)

    /// 目标图（作品里的副本）这一格区域的平均色。区域换算与补格算目标特征同一套（`IndexWorkRematcher.cellRegion`）。
    public static func targetColor(cell: Int, layout: MosaicLayout, target: PixelBuffer?) -> CellColor {
        guard let target,
              let r = IndexWorkRematcher.cellRegion(cell, layout: layout, targetWidth: target.width, targetHeight: target.height),
              r.width > 0, r.height > 0 else { return neutral }
        var sr = 0, sg = 0, sb = 0
        for y in r.y..<(r.y + r.height) {
            for x in r.x..<(r.x + r.width) {
                let p = target.rgb(x: x, y: y)
                sr += Int(p.r); sg += Int(p.g); sb += Int(p.b)
            }
        }
        let n = r.width * r.height
        return CellColor(r: UInt8((sr + n / 2) / n), g: UInt8((sg + n / 2) / n), b: UInt8((sb + n / 2) / n))
    }

    /// 布局里纯色格的填充图（每格一张 1×1 的纯色图）。预览重画和高清导出都把它放大填满该格，所以两边颜色一致；
    /// 不写进 `WorkFallbackImages`。
    public static func colorTiles(_ layout: MosaicLayout) -> [Int: PixelBuffer] {
        var out: [Int: PixelBuffer] = [:]
        for (i, c) in layout.cellAssignments.enumerated() {
            guard let f = c.fill else { continue }
            out[i] = try? PixelBuffer(width: 1, height: 1, bytes: [f.r, f.g, f.b, 255])
        }
        return out
    }
}
