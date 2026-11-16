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
                                 tier: nil, resultRevision: state.resultRevision)
    }
}
