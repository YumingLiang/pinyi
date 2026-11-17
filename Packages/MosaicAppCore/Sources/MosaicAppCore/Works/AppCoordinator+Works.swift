import Foundation
import MosaicCore

extension AppCoordinator {
    /// 结果页现状（「存到我的作品」/ 导出成功自动存用）：只有停在结果页时才有布局。
    public var workResultContext: WorkResultContext {
        var layout: MosaicLayout?
        if case .result = state.flow.generation.phase, let product {
            layout = MosaicLayout(product: product, overlayAlpha: state.flow.settings.overlayAlpha)
        }
        return WorkResultContext(layout: layout, target: target, overlayAlpha: state.flow.settings.overlayAlpha,
                                 tier: state.exportTier.rawValue, resultRevision: state.resultRevision)
    }

    /// 「我的作品」补格用的素材快照（4b）：全部照片（受限访问时即已允许的照片）。索引还没加载完时抛
    /// `WorkRematchError.indexUnavailable`，作品不改写，下次打开再补。
    public func worksRematchSnapshot() async throws -> IndexSnapshot {
        guard state.indexLoaded else { throw WorkRematchError.indexUnavailable }
        return try await index.snapshot(for: .allPhotos)
    }
}
