import Foundation
import MosaicCore

/// 原照片为什么取不到（需求 4.8 第 5e 条，架构师 11-17 最终方案）。
public enum MissingReason: Sendable, Hashable {
    /// 查得到且 `isHidden`：照片还在，被设成了隐藏。
    case hidden
    /// 完整授权下按 ID（连隐藏照片一起）查不到：确认已删除。
    case deleted
    /// 其余（受限访问下查不到、无权限、查到却不是隐藏的竞态）：拿不准，按隐藏处理。
    case unknown
}

/// 相册授权（分类用）。
public enum LibraryAccess: Sendable, Hashable {
    case full, limited, none
}

/// 缺图分类（纯逻辑，Linux 有测试）。App 侧 `PhotoFetch.classifyMissing` 把「连隐藏照片一起按 ID 查一次」的结果
/// （查得到的 ID → isHidden）交给它；查询本身只读元数据，**不请求任何图像**。
public enum MissingPhotoClassifier {
    public static func classify(_ ids: Set<String>, found: [String: Bool], access: LibraryAccess) -> [String: MissingReason] {
        var out: [String: MissingReason] = [:]
        for id in ids where !id.isEmpty {
            if let hidden = found[id] {
                out[id] = hidden ? .hidden : .unknown
            } else {
                out[id] = access == .full ? .deleted : .unknown
            }
        }
        return out
    }

    /// 带查询的版本：`lookup` 只调一次（全部 ID 一起），返回查得到的 ID → isHidden。
    public static func classify(_ ids: Set<String>, access: LibraryAccess,
                                lookup: ([String]) -> [String: Bool]) -> [String: MissingReason] {
        let list = ids.filter { !$0.isEmpty }.sorted()
        guard !list.isEmpty else { return [:] }
        return classify(Set(list), found: lookup(list), access: access)
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
    /// 有候选 → 用候选；deleted → 旧预览裁切（4b）；hidden / unknown / 不知道 → 目标图这一格的平均色（按格计入 works.missing）。
    public static func decide(reason: MissingReason?, hasCandidate: Bool) -> MissingCellFill {
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
