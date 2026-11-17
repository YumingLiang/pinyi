import Foundation
import MosaicCore

extension AppCoordinator {
    /// 结果页现状（「存到我的作品」及其按钮状态、未保存提示用）：停在结果页，或「再调一调」途中（结果还留着，
    /// `isAdjustingResult`）时才有布局。后者让「再调一调」设置页发起「再拼一张」时能按同一套规则判断、保存 / 更新（验收 7a）。
    public var workResultContext: WorkResultContext {
        var layout: MosaicLayout?
        let onResult: Bool = { if case .result = state.flow.generation.phase { return true }; return false }()
        if let product, onResult || isAdjustingResult {
            layout = MosaicLayout(product: product, overlayAlpha: state.flow.settings.overlayAlpha)
        }
        return WorkResultContext(layout: layout, target: target, overlayAlpha: state.flow.settings.overlayAlpha,
                                 tier: state.exportTier.rawValue, resultRevision: state.resultRevision)
    }
}
