import Foundation
import MosaicCore

// 4b「缺图补格」（hd-export-req-v0.2 F2 第 2 条；quick-start-req-v0.4 §4.8 5a / 5b；photo-picker-v0.1 §5.1）：
// 作品里原照片取不到（删除或后来被隐藏）的格子，用本机、可见的最相近照片替换。
// 架构师 11-17：和生成链路（#13）一致，补格**只匹配一次**、不做逐张清晰度探测（PR #5 已取消）；糊不糊交给查看页清晰层（#15）
// 和导出的 `ExportFillStats`。

/// 一次补格的结果。
public struct WorkRematchResult: Sendable, Equatable {
    /// 补完的布局（替换了的格子换成新照片；实在找不到的清成缺图格）。
    public var layout: MosaicLayout
    /// 换成相近照片的格子数（`works.replaced`）。
    public var replacedCells: Int
    /// 找不到替代、留白的格子数。
    public var blankCells: Int
    /// 至少有一格留白的原照片数（累计进 `WorkMeta.droppedPhotoCount`，`works.missing` 显示它）。
    public var droppedPhotos: Int
    /// 性能页 / 日志附注（不含照片 ID）。
    public var note: String

    public init(layout: MosaicLayout, replacedCells: Int, blankCells: Int, droppedPhotos: Int, note: String = "") {
        self.layout = layout
        self.replacedCells = replacedCells
        self.blankCells = blankCells
        self.droppedPhotos = droppedPhotos
        self.note = note
    }

    /// 没有补格器 / 补格出错：全部清成空格子（写回时按 `MissingCellFill.decide` 补：删除 → 旧预览裁切，隐藏 / 拿不准 → 目标色）。
    public static func allBlank(_ layout: MosaicLayout, missing: Set<String>) -> WorkRematchResult {
        let cells = layout.cellAssignments.reduce(0) { $0 + (missing.contains($1.localIdentifier) ? 1 : 0) }
        let (out, dropped) = layout.clearingAssets(missing)
        return WorkRematchResult(layout: out, replacedCells: 0, blankCells: cells, droppedPhotos: dropped, note: "未补格")
    }
}

public enum WorkRematchError: Error, Sendable, Equatable {
    /// 索引暂时不可用（还在加载 / 读失败）。调用方不写回作品，下次再试；不当成「找不到替代」留白。
    case indexUnavailable
}

/// 按索引补格（实现见 `IndexWorkRematcher`；测试可换假实现）。
/// 输入只有布局、缺失 ID、目标图副本（架构师 11-17 意见三-1）：不认识 `WorkID`、不碰作品库，写回由调用方经
/// `FileWorksStore` 的按作品串行入口做。5d 结果页 / 5e 后台队列也直接用它。
/// 约定：Task 被取消时抛 `CancellationError`，调用方不写回任何东西。
public protocol MissingCellRematching: Sendable {
    /// - Parameters:
    ///   - layout: 当前布局。
    ///   - missing: 取不到的原照片 ID（删除或后来被隐藏）；含空串时之前留白的格子也一起重新找。
    ///   - target: 目标图副本（只读，算格子的目标特征）；没有时用相邻格子照片的特征估。
    func rematch(_ layout: MosaicLayout, missing: Set<String>, target: PixelBuffer?) async throws -> WorkRematchResult
}

/// 用索引快照 + MosaicCore 距离内核补格（一次匹配，无逐张探测）。
///
/// 数据来源：
/// - **作品里存了什么**：`layout.json`（每格 localIdentifier + 裁剪、列 / 行、生成时目标图尺寸 `targetSize`、网格区域 `targetCrop`），
///   `target.jpg`（目标图副本），`preview.jpg`。**没有**存每格的目标特征，也没有存生成时的索引行号。
/// - **格子的目标特征**：有目标图副本时，把 `targetCrop` 按副本 / `targetSize` 比例换算，取该格的像素区域，用与生成**同一个**
///   `FeatureExtractor` 提特征。没有副本时，用相邻 8 格里仍在索引中的照片的特征取平均；邻居都不在就留白。
/// - **候选** = 索引快照 ∩ `PhotoFetch.visibleImages`（`existence`，不含隐藏 / 删除）− 缺失的照片。
///
/// 算法（与 `MosaicPipeline.refill` 同一内核、同一 `refillCandidateCount`、同一邻居规则；忽略单张上限）：
/// 1. 每个缺图格在「快照 − 缺失」里取 top‑k 近邻；
/// 2. 把所有格子的 top‑k 候选并起来**一次**查可见（`existingIdentifiers`，批量、只查元数据），不可见的（索引里还留着、后来被隐藏 / 删除的）剔掉；
/// 3. 逐格在可见候选里按「不在作品里也不在相邻格」→「不在相邻格」→「最近」选一张（前面补上的格子也算邻居）。
/// 4. top‑k 里一张可见的都没有（索引为空、全不可见、算不出目标特征）才清成空格子；写回时按 `MissingCellFill.decide` 补。
///    索引暂时取不到（`snapshot()` 抛错）不算：抛 `WorkRematchError.indexUnavailable`，作品不动。
/// 不请求任何图像（没有清晰度探测）。
public struct IndexWorkRematcher: MissingCellRematching {
    public var snapshot: @Sendable () async throws -> IndexSnapshot
    public var existence: any PhotoExistenceChecking
    public var pipeline: MosaicPipeline
    public var candidateCount: Int

    public init(snapshot: @escaping @Sendable () async throws -> IndexSnapshot, existence: any PhotoExistenceChecking,
                pipeline: MosaicPipeline = MosaicPipeline(),
                candidateCount: Int = MosaicPipeline.refillCandidateCount) {
        self.snapshot = snapshot
        self.existence = existence
        self.pipeline = pipeline
        self.candidateCount = max(1, candidateCount)
    }

    public func rematch(_ layout: MosaicLayout, missing: Set<String>, target: PixelBuffer?) async throws -> WorkRematchResult {
        let todoCells = layout.cellAssignments.indices.filter { missing.contains(layout.cellAssignments[$0].localIdentifier) }
        guard !todoCells.isEmpty else { return WorkRematchResult(layout: layout, replacedCells: 0, blankCells: 0, droppedPhotos: 0) }
        try Task.checkCancellation()
        let snap: IndexSnapshot
        do { snap = try await snapshot() } catch is CancellationError { throw CancellationError() } catch {
            throw WorkRematchError.indexUnavailable   // 暂时取不到（索引还没加载完等）：不写回，下次打开再补
        }
        try Task.checkCancellation()
        let table = snap.library.table
        guard table.spec == pipeline.sampler.extractor.spec, snap.availableCount > 0,
              let grid = try? MosaicGrid(columns: layout.cols, rows: layout.rows) else {
            return .allBlank(layout, missing: missing)
        }

        // 行 ↔ ID；候选掩码：快照 ∧ 有 ID ∧ 不是缺失的照片
        var rowOf: [String: Int] = [:]
        var idOf: [Int: String] = [:]
        let rowCount = min(snap.assetIDsByRow.count, table.count)
        for row in 0..<rowCount where snap.library.mask[row] {
            if let id = snap.assetIDsByRow[row] { rowOf[id] = row; idOf[row] = id }
        }
        var mask = BitMask(count: table.count)
        for (row, id) in idOf where !missing.contains(id) { mask[row] = true }

        // 目标特征
        var queries: [Int: FeatureRecord] = [:]
        for cell in todoCells {
            if let q = queryFeature(cell: cell, layout: layout, grid: grid, target: target, table: table, rowOf: rowOf, missing: missing) {
                queries[cell] = q
            }
        }
        try Task.checkCancellation()

        var ids = layout.cellAssignments.map(\.localIdentifier)
        for cell in todoCells { ids[cell] = "" }
        let pending = todoCells.filter { queries[$0] != nil }
        var candidates: [Int: [String]] = [:]
        if !pending.isEmpty, mask.setCount > 0 {
            let k = min(candidateCount, mask.setCount)
            let top = try pipeline.assigner.kernel.topK(queries: FeatureMatrix(records: pending.map { queries[$0]! }),
                                                        candidates: table.matrix, k: k, mask: mask)
            for (q, cell) in pending.enumerated() {
                candidates[cell] = top.neighbors(forQuery: q).filter { $0.distance.isFinite }.compactMap { idOf[$0.index] }
            }
        }
        // 候选只取可见的：所有格子的候选并起来查一次（索引里可能还留着后来被隐藏 / 删除的照片）
        let union = Array(Set(candidates.values.joined())).sorted()
        let visible = union.isEmpty ? Set<String>() : await existence.existingIdentifiers(among: union)
        try Task.checkCancellation()

        let neighborhood = pipeline.assigner.configuration.neighborhood
        var inWork = Set(ids).subtracting([""])
        for cell in pending {
            let cands = (candidates[cell] ?? []).filter { visible.contains($0) }
            guard !cands.isEmpty else { continue }
            let near = Set(grid.neighbors(of: cell, in: neighborhood).map { ids[$0] }).subtracting([""])
            let pick = cands.first { !inWork.contains($0) && !near.contains($0) }
                ?? cands.first { !near.contains($0) } ?? cands[0]
            ids[cell] = pick   // 后面的格子把它当邻居
            inWork.insert(pick)
        }

        var out = layout
        var replaced = 0, blank = 0
        var droppedIDs = Set<String>()
        for cell in todoCells {
            let old = layout.cellAssignments[cell].localIdentifier
            if ids[cell].isEmpty {
                blank += 1
                if !old.isEmpty { droppedIDs.insert(old) }   // 之前就留白、这次仍没补上的不重复计
                out.cellAssignments[cell] = .init(localIdentifier: "", crop: layout.cellAssignments[cell].crop)
            } else {
                replaced += 1
                out.cellAssignments[cell] = .init(localIdentifier: ids[cell])   // 新照片用整张居中正方形
            }
        }
        let note = "补格 \(replaced) · 留白 \(blank) · 候选 \(union.count) · 可见 \(visible.count) · 素材 \(snap.availableCount)"
        return WorkRematchResult(layout: out, replacedCells: replaced, blankCells: blank, droppedPhotos: droppedIDs.count, note: note)
    }

    /// 格子的目标特征：目标图副本里那一格的区域；没有副本时取相邻格（仍在索引、不是缺失的）照片特征的平均。
    func queryFeature(cell: Int, layout: MosaicLayout, grid: MosaicGrid, target: PixelBuffer?, table: FeatureTable,
                      rowOf: [String: Int], missing: Set<String>) -> FeatureRecord? {
        if let target, let region = Self.cellRegion(cell, layout: layout, targetWidth: target.width, targetHeight: target.height),
           let rec = try? pipeline.sampler.extractor.extract(from: target, region: region) {
            return rec
        }
        var sum = [Float](repeating: 0, count: FeatureVector.dimension)
        var n = 0
        for nb in grid.neighbors(of: cell, in: .eight) {
            let id = layout.cellAssignments[nb].localIdentifier
            guard !id.isEmpty, !missing.contains(id), let row = rowOf[id] else { continue }
            let v = table.record(row).vector.components
            for d in 0..<sum.count { sum[d] += v[d] }
            n += 1
        }
        guard n > 0 else { return nil }
        return FeatureRecord(vector: FeatureVector(sum.map { $0 / Float(n) }))
    }

    /// `targetCrop`（生成时目标图像素）按副本尺寸换算后，第 `cell` 格的整数像素区域（与 `GridLayout.cellPixelRegion` 同一取整规则）。
    static func cellRegion(_ cell: Int, layout: MosaicLayout, targetWidth tw: Int, targetHeight th: Int) -> PixelRegion? {
        guard layout.cols > 0, layout.rows > 0, tw > 0, th > 0, layout.targetSize.width > 0, layout.targetSize.height > 0 else { return nil }
        let sx = Double(tw) / Double(layout.targetSize.width), sy = Double(th) / Double(layout.targetSize.height)
        let c = layout.targetCrop
        let w = c.width * sx / Double(layout.cols), h = c.height * sy / Double(layout.rows)
        let col = cell % layout.cols, row = cell / layout.cols
        func span(_ start: Double, _ length: Double, _ limit: Int) -> (Int, Int) {
            var a = Int(start.rounded(.down))
            var b = Int((start + length).rounded(.down))
            a = min(max(0, a), limit - 1)
            b = min(max(a + 1, b), limit)
            return (a, b - a)
        }
        let (x, rw) = span(c.x * sx + Double(col) * w, w, tw)
        let (y, rh) = span(c.y * sy + Double(row) * h, h, th)
        return PixelRegion(x: x, y: y, width: rw, height: rh)
    }
}
