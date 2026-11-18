#if INTERNAL_TOOLS
import SwiftUI
import UIKit
import MosaicAppCore

// MARK: - 假数据源 / 假缩略图加载器（T4；T3 的 PhotoKit 实现合入前单独跑网格用）
//
// 只在内部构建里有（Debug / Internal）。不碰相册：照片 ID 是算出来的（`fake-<序号>`），缩略图是现画的色块，
// 5 万张不建数组。App 单测（AppTests/AssetGridViewControllerTests）也用它。

/// 5 万项（可配）的假网格数据源。下标 0 = 最新，序号从大到小；每 7 张有一张「实况」。
@MainActor
final class FakeAssetGridDataSource: AssetGridDataSource {
    let album: SourceSelection
    private(set) var count: Int
    /// 下标 0 那张的序号。
    private var newestSerial: Int
    private var handler: (@MainActor (AssetGridChange) -> Void)?

    init(count: Int = 50_000, album: SourceSelection = .allPhotos) {
        self.album = album
        self.count = max(0, count)
        self.newestSerial = max(0, count) - 1
    }

    func assetID(at index: Int) -> String { "fake-\(newestSerial - index)" }

    func isLivePhoto(at index: Int) -> Bool { (newestSerial - index) % 7 == 0 }

    func index(ofAssetID assetID: String) -> Int? {
        guard assetID.hasPrefix("fake-"), let serial = Int(assetID.dropFirst(5)) else { return nil }
        let index = newestSerial - serial
        return index >= 0 && index < count ? index : nil
    }

    func setChangeHandler(_ handler: (@MainActor (AssetGridChange) -> Void)?) { self.handler = handler }

    /// 模拟新拍了 `n` 张：插到顶部。
    func insertNewest(_ n: Int) {
        guard n > 0 else { return }
        newestSerial += n
        count += n
        handler?(.incremental(removed: [], inserted: IndexSet(0..<n), changed: [], moves: []))
    }

    /// 模拟最新的 `n` 张被删除 / 设为隐藏（隐藏也表现为删除，§5.1）。
    func removeNewest(_ n: Int) {
        let n = min(n, count)
        guard n > 0 else { return }
        newestSerial -= n
        count -= n
        handler?(.incremental(removed: IndexSet(0..<n), inserted: [], changed: [], moves: []))
    }

    /// 模拟变化太大 / 没有增量信息。
    func emitReload() { handler?(.reload) }
}

/// 假缩略图加载器：先同步回一张低清（模拟 `.opportunistic`），`latency` 秒后回正式图；取消后不再回调。
/// 每 13 张有一张「本机没有」（只回 `image == nil`），用来看占位格。
@MainActor
final class FakeGridThumbnailLoader: GridThumbnailLoading {
    var latency: Double
    private var nextID: Int32 = 0
    private var inFlight = Set<Int32>()
    private(set) var caching = Set<String>()
    private(set) var requestCount = 0
    private(set) var cancelCount = 0

    init(latency: Double = 0.05) { self.latency = latency }

    func requestThumbnail(assetID: String, targetPixelSize: Int,
                          handler: @escaping @MainActor (GridThumbnail<UIImage>) -> Void) -> GridThumbnailRequestID? {
        requestCount += 1
        let serial = Self.serial(of: assetID)
        if serial % 13 == 0 {
            handler(GridThumbnail(image: nil, isDegraded: false))
            return nil
        }
        nextID &+= 1
        let token = nextID
        inFlight.insert(token)
        handler(GridThumbnail(image: Self.render(serial: serial, pixels: 8), isDegraded: true))
        let delay = UInt64(max(0, latency) * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, self.inFlight.remove(token) != nil else { return }
            handler(GridThumbnail(image: Self.render(serial: serial, pixels: targetPixelSize), isDegraded: false))
        }
        return GridThumbnailRequestID(rawValue: token)
    }

    func cancel(_ id: GridThumbnailRequestID) {
        if inFlight.remove(id.rawValue) != nil { cancelCount += 1 }
    }

    func startCaching(assetIDs: [String], targetPixelSize: Int) { caching.formUnion(assetIDs) }
    func stopCaching(assetIDs: [String], targetPixelSize: Int) { caching.subtract(assetIDs) }
    func stopCachingAll() { caching.removeAll() }

    private static func serial(of assetID: String) -> Int { Int(assetID.dropFirst(5)) ?? 0 }

    /// 按序号定色相的色块，正式图上再画序号。
    private static func render(serial: Int, pixels: Int) -> UIImage {
        let side = CGFloat(max(1, pixels))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let hue = CGFloat((serial * 37) % 360) / 360
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            guard pixels >= 64 else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: side / 6, weight: .semibold),
                .foregroundColor: UIColor.black.withAlphaComponent(0.6),
            ]
            NSString(string: "\(serial)").draw(at: CGPoint(x: side / 12, y: side / 12), withAttributes: attrs)
        }
    }
}

/// 内部工具页：用假数据源跑共用网格（滚动、预取、缓存窗口、变化动画、锚点）。文字不进文案表。
struct FakePhotoGridView: View {
    @State private var source = FakeAssetGridDataSource()
    @State private var loader = FakeGridThumbnailLoader()
    @State private var lastSelection: AssetGridSelection?
    @State private var anchor: AssetGridAnchor?
    @State private var target: AssetGridScrollTarget?

    var body: some View {
        VStack(spacing: 0) {
            AssetGridView(dataSource: source, loader: loader, selectionMode: .single, scrollTarget: target,
                          onSelect: { lastSelection = $0 }, onAnchorChange: { anchor = $0 })
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "共 \(source.count) 张 · 缓存 \(loader.caching.count) · 请求 \(loader.requestCount) · 取消 \(loader.cancelCount)")
                Text(verbatim: "锚点 \(anchor?.assetID ?? "-") \(anchor.map { String(format: "%.1f", $0.offset) } ?? "")")
                Text(verbatim: "点选 \(lastSelection?.assetID ?? "-")")
                HStack {
                    Button { source.insertNewest(3) } label: { Text(verbatim: "顶部 +3") }
                    Button { source.removeNewest(1) } label: { Text(verbatim: "删最新 1") }
                    Button { source.emitReload() } label: { Text(verbatim: "reload") }
                    Button {
                        target = AssetGridScrollTarget(index: 25_000, offset: -20, token: (target?.token ?? 0) + 1)
                    } label: { Text(verbatim: "跳到 #25000") }
                }
                .buttonStyle(.bordered)
            }
            .font(.caption.monospacedDigit())
            .padding(8)
        }
        .navigationTitle(Text(verbatim: "照片网格（假数据）"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
