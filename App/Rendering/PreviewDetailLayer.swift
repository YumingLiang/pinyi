import CoreGraphics
import Foundation
import os
import SwiftUI
import UIKit
import MosaicCore
import MosaicAppCore

/// 结果页预览清晰层（feat/preview-detail-layer，架构师 21:02 方案）。纯逻辑在 MosaicAppCore `DetailLayer.swift`（Linux 单测）。
///
/// - 底图（`AppModel.resultImage`）不动。本层只给「可见格子 + 外扩 1 圈」各放一张 256 / 512 / 1024 px 的方图，
///   由 `PreviewDetailTilesView` 放进 `ZoomableContainer` 的内容里（scaleEffect 之内）。
/// - 取图 = 导出的 hq 请求（`fastFormat = false`、`fastResize = false`、`centerCropToSquare = true`，不联网），
///   取不到退回 `.scanDisplay`（128 px）；还取不到就不放这一格，底图照常显示，不提示。
///   照片一律经 `PhotoKitThumbnails` → `PhotoFetch.images(withLocalIdentifiers:)`，隐藏照片取不到。
/// - 最多 6 个请求在飞；可见集合变化时，不再需要的请求立即取消（Task 取消 → `cancelImageRequest`）。
/// - 缓存：`NSCache` 按字节计费，上限 64 MB，键 = assetID（同一照片多格只取一次；缓存档位低于所需时重取）。
///   离开结果页、换拼法（新 resultRevision）、内存警告时清空。
/// ⚠️ 盲写（Linux 上无法编译 SwiftUI / UIKit / PhotoKit，只做 `swiftc -parse`）。
@MainActor
final class PreviewDetailLayer: ObservableObject {
    struct Tile: Identifiable {
        let id: Int          // 格子下标（行优先）
        let column: Int
        let row: Int
        let image: CGImage
    }

    private final class CachedTile {
        let image: CGImage
        /// nil = 退回的 128 px `.scanDisplay`：先顶上显示，但不算「已有足够档位」，下次更新还会再试 hq。
        let tier: DetailTier?
        init(image: CGImage, tier: DetailTier?) { self.image = image; self.tier = tier }
    }

    /// 当前要显示的格子图（只含已取到的）。
    @Published private(set) var tiles: [Tile] = []

    private let thumbnails: PhotoKitThumbnails
    private let perf: PerfRecorder?
    private let policy: DetailLayerPolicy
    private var state: DetailLayerState
    private let cache = NSCache<NSString, CachedTile>()

    // 当前作品
    private var cellAssetIDs: [String?] = []
    private var columns = 0
    private var rows = 0
    private var baseCellPixels = 64

    // 当前缩放
    private var zoom = ZoomState()
    private var displayScale: Double = 3

    // 当前可见集合
    private var plan: DetailLoadPlan?
    private var cellsByAsset: [String: [Int]] = [:]
    private var queue: [String] = []
    private var inFlight: [String: (tier: DetailTier, task: Task<Void, Never>)] = [:]
    private var settleTask: Task<Void, Never>?
    private var updateStart: Double = 0
    private var fetchedThisUpdate = 0

    private var memoryWarning: NSObjectProtocol?
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "pinyi", category: "preview-detail")

    init(thumbnails: PhotoKitThumbnails, perf: PerfRecorder?, policy: DetailLayerPolicy = .standard) {
        self.thumbnails = thumbnails
        self.perf = perf
        self.policy = policy
        self.state = DetailLayerState(policy: policy)
        cache.totalCostLimit = policy.cacheByteLimit
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
    }
    // 不写 deinit 移除观察者：本对象随 AppModel 活到进程结束；回调里是 weak self。

    // MARK: 输入

    /// 新结果（含换拼法）：清空并换成新作品的格子映射。
    func configure(product: GenerationProduct) {
        reset()
        let layout = product.generation.layout
        cellAssetIDs = product.cellAssetIDs
        columns = layout.columns
        rows = layout.rows
        baseCellPixels = MosaicPreviewRenderer.cellPixels(for: product.generation)
    }

    /// 离开结果页 / 换作品 / 内存警告：取消请求、移除格子图、清缓存。
    func reset() {
        apply(state.reset())
    }

    /// 缩放 / 平移每次变化都调（手势每帧、结束、双击）。150 ms 内没有新变化才更新可见集合。
    func zoomChanged(_ z: ZoomState, displayScale: Double) {
        zoom = z
        if displayScale > 0 { self.displayScale = displayScale }
        apply(state.zoomChanged())
    }

    // MARK: 动作

    private func apply(_ actions: [DetailLayerState.Action]) {
        for a in actions {
            switch a {
            case .scheduleSettle(let g, let delay):
                settleTask?.cancel()
                settleTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.apply(self.state.settled(generation: g, geometry: self.geometry, baseCellPixels: self.baseCellPixels))
                }
            case .update(_, _, let tier):
                update(tier: tier)
            case .clear:
                settleTask?.cancel()
                settleTask = nil
                cancelAll()
                plan = nil
                cellsByAsset = [:]
                if !tiles.isEmpty { tiles = [] }
            case .purgeCache:
                cache.removeAllObjects()
            }
        }
    }

    private var geometry: DetailGeometry {
        DetailGeometry(zoom: zoom, displayScale: displayScale, columns: columns, rows: rows)
    }

    private func cached(_ id: String, atLeast tier: DetailTier) -> CachedTile? {
        guard let c = cache.object(forKey: id as NSString), let t = c.tier, t >= tier else { return nil }
        return c
    }

    private func update(tier: DetailTier) {
        // 显示中的图被视图持有、NSCache 释放不了：按 64 MB 预算截断（中心优先，外圈先丢），守住「峰值 ≤ 现在 + 64 MB」。
        let p = DetailLoadPlan(geometry: geometry, cellAssetIDs: cellAssetIDs, tier: tier, ring: policy.ring)
            .limited(toBytes: policy.cacheByteLimit)
        plan = p
        var byAsset: [String: [Int]] = [:]
        for item in p.items { byAsset[item.assetID] = item.cells }
        cellsByAsset = byAsset

        // 低档的在飞请求不够清楚：取消，按新档重发
        for (id, f) in inFlight where f.tier < tier {
            f.task.cancel()
            inFlight[id] = nil
        }
        let needed = p.items.map(\.assetID)
        let d = DetailRequestDiff.diff(inFlight: Set(inFlight.keys), needed: needed,
                                       cached: { self.cached($0, atLeast: tier) != nil })
        for id in d.cancel {
            inFlight[id]?.task.cancel()
            inFlight[id] = nil
        }
        queue = d.start

        // 先用缓存里的（含低一档的，暂时顶上，取到高档再换）
        var t: [Tile] = []
        for item in p.items {
            guard let c = cache.object(forKey: item.assetID as NSString) else { continue }
            for cell in item.cells {
                t.append(Tile(id: cell, column: cell % max(1, columns), row: cell / max(1, columns), image: c.image))
            }
        }
        tiles = t
        updateStart = Date().timeIntervalSince1970
        fetchedThisUpdate = 0
        Self.log.info("detail update tier=\(tier.pixels, privacy: .public) cells=\(p.cellCount, privacy: .public) assets=\(p.items.count, privacy: .public) toFetch=\(d.start.count, privacy: .public) dropped=\(p.truncatedCount, privacy: .public)")
        pump()
        finishIfIdle()
    }

    private func pump() {
        guard let tier = plan?.tier else { return }
        while inFlight.count < policy.maxConcurrentRequests, !queue.isEmpty {
            let id = queue.removeFirst()
            guard cellsByAsset[id] != nil, cached(id, atLeast: tier) == nil, inFlight[id] == nil else { continue }
            let thumbs = thumbnails
            let task = Task { [weak self] in
                var hq = ThumbnailRequest(targetPixelSize: tier.pixels)   // 同导出 hq（LiveMosaicExporter）
                hq.fastFormat = false
                hq.fastResize = false
                hq.centerCropToSquare = true
                var result = await thumbs.cancellableThumbnail(for: id, request: hq)
                var fellBack = false
                if case .image = result {} else if !Task.isCancelled {
                    result = await thumbs.cancellableThumbnail(for: id, request: .scanDisplay)
                    fellBack = true
                }
                guard !Task.isCancelled, let self else { return }
                self.received(id: id, tier: tier, result: result, fellBack: fellBack)
            }
            inFlight[id] = (tier, task)
        }
    }

    private func received(id: String, tier: DetailTier, result: ThumbnailResult, fellBack: Bool) {
        guard let f = inFlight[id], f.tier == tier else { return }   // 已被取消 / 换档
        inFlight[id] = nil
        if case .image(let pb) = result, let fresh = ImagePixels.cgImage(pb) {
            // 退回的 128 px 图不覆盖已有缓存（可能是低一档的 hq，比它清楚），只在没有任何缓存时存
            var img = fresh
            if fellBack, let existing = cache.object(forKey: id as NSString) {
                img = existing.image
            } else {
                cache.setObject(CachedTile(image: fresh, tier: fellBack ? nil : tier), forKey: id as NSString,
                                cost: pb.width * pb.height * 4)
            }
            fetchedThisUpdate += 1
            if let cells = cellsByAsset[id] {
                let set = Set(cells)
                var t = tiles.filter { !set.contains($0.id) }
                for cell in cells {
                    t.append(Tile(id: cell, column: cell % max(1, columns), row: cell / max(1, columns), image: img))
                }
                tiles = t
            }
        }
        pump()
        finishIfIdle()
    }

    private func finishIfIdle() {
        guard inFlight.isEmpty, queue.isEmpty, let p = plan, updateStart > 0 else { return }
        let seconds = Date().timeIntervalSince1970 - updateStart
        updateStart = 0
        let note = "tier \(p.tier.pixels) 格 \(p.cellCount) 照片 \(p.items.count) 新取 \(fetchedThisUpdate)"
        perf?.record(.previewDetail, seconds: seconds, items: fetchedThisUpdate, note: note)
        Self.log.info("detail done \(String(format: "%.3f", seconds), privacy: .public)s \(note, privacy: .public)")
    }

    private func cancelAll() {
        for (_, f) in inFlight { f.task.cancel() }
        inFlight = [:]
        queue = []
    }
}

/// 清晰层视图：放在 `ZoomableContainer` 的内容里（和底图同一个 scaleEffect 之内）。
/// 每格一个 `Image`，frame = 未缩放的格子尺寸、`.position` 定位。**不要**加 `.drawingGroup()` / `.compositingGroup()`
/// 等光栅化修饰符：Core Animation 放大时直接用图层的原始像素，256 px 的图放大后仍清楚。
/// 叠加 α > 0 时，在格子上再叠一层目标图（同一 cropRect，`.opacity(α)`），用格子形状做遮罩，只盖住有清晰图的格子
/// （没清晰图的地方是底图，底图里已经叠过一次）。
struct PreviewDetailTilesView: View {
    @ObservedObject var layer: PreviewDetailLayer
    let zoom: ZoomState
    let columns: Int
    let rows: Int
    /// 目标图裁剪区（`GridLayout.cropRect`）；α = 0 时传 nil。
    let overlay: CGImage?
    let overlayAlpha: Double

    var body: some View {
        let vp = zoom.viewport
        let g = DetailGeometry(viewport: vp, fittedSize: zoom.fittedSize, scale: 1, offset: .zero,
                               displayScale: 1, columns: columns, rows: rows)
        ZStack {
            ForEach(layer.tiles) { t in
                let f = g.unscaledCellFrame(column: t.column, row: t.row)
                Image(decorative: t.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: f.width, height: f.height)
                    .position(x: f.centerX, y: f.centerY)
            }
            if let overlay, overlayAlpha > 0, !layer.tiles.isEmpty {
                Image(decorative: overlay, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: zoom.fittedSize.x, height: zoom.fittedSize.y)
                    .position(x: vp.x / 2, y: vp.y / 2)
                    .opacity(overlayAlpha)
                    .mask {
                        ZStack {
                            ForEach(layer.tiles) { t in
                                let f = g.unscaledCellFrame(column: t.column, row: t.row)
                                Rectangle()
                                    .frame(width: f.width, height: f.height)
                                    .position(x: f.centerX, y: f.centerY)
                            }
                        }
                        .frame(width: vp.x, height: vp.y)
                    }
            }
        }
        .frame(width: vp.x, height: vp.y)
        .allowsHitTesting(false)
    }
}
