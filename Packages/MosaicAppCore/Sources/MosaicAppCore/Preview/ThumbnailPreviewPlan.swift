import MosaicCore

/// 缩略图预览的取图计划（评审 d6fa750 MF-6）。
///
/// 旧实现逐格串行 `await thumbnail` 并把所有取到的图留在 `[id: CGImage]` 缓存里：细档 10,800 格、约 1 万张不同素材时
/// 缓存最坏约 0.7 GB。新做法：
/// 1. 按素材分组 `[assetID: [cell]]`（按首次出现的格子顺序，可复现）；
/// 2. 以 `maxConcurrent`（8–16）有界并发取图，**每取到一张就画完它的所有格子并丢弃**，同时在内存里的缩略图 ≤ 一个窗口；
/// 3. 每画完 `progressEvery` 张回调一次，平台层借此推中间图。
public struct ThumbnailPreviewPlan: Sendable, Hashable {
    public struct Group: Sendable, Hashable {
        public let assetID: String
        /// 使用这张素材的格子（升序）。
        public let cells: [Int]
    }

    public let groups: [Group]
    public let maxConcurrent: Int

    /// - Parameter cellAssetIDs: 每格对应的 localIdentifier（`GenerationProduct.cellAssetIDs`），nil 的格子跳过。
    public init(cellAssetIDs: [String?], maxConcurrent: Int = 12) {
        var order: [String] = []
        var cellsByID: [String: [Int]] = [:]
        for (cell, id) in cellAssetIDs.enumerated() {
            guard let id else { continue }
            if cellsByID[id] == nil { order.append(id) }
            cellsByID[id, default: []].append(cell)
        }
        groups = order.map { Group(assetID: $0, cells: cellsByID[$0] ?? []) }
        self.maxConcurrent = min(max(maxConcurrent, 8), 16)
    }

    public var cellCount: Int { groups.reduce(0) { $0 + $1.cells.count } }

    /// 执行：分窗口（每窗 `maxConcurrent` 张）并发取图，窗口内按计划顺序逐张 `draw`，画完即释放。
    /// `draw` 在调用方的隔离域里同步执行（例如 MainActor 上画到 CGContext）。被取消时抛 `CancellationError`。
    /// - Returns: 画出的素材张数（取图失败 / 未下载的跳过，格子保持底色）。
    @discardableResult
    public func run(
        isolation: isolated (any Actor)? = #isolation,
        fetch: @escaping @Sendable (String) async -> ThumbnailResult,
        progressEvery: Int = 200,
        progress: (Int) -> Void = { _ in },
        draw: (Group, PixelBuffer) -> Void
    ) async throws -> Int {
        var drawn = 0
        var start = 0
        while start < groups.count {
            try Task.checkCancellation()
            let window = Array(groups[start..<min(groups.count, start + maxConcurrent)])
            let images = try await BoundedConcurrency.map(window.map(\.assetID), maxConcurrent: maxConcurrent, fetch)
            for (g, r) in zip(window, images) {
                if case .image(let pb) = r {
                    draw(g, pb)
                    drawn += 1
                    if drawn % max(1, progressEvery) == 0 { progress(drawn) }
                }
            }
            start += window.count
        }
        return drawn
    }
}
