import SwiftUI
import MosaicCore
import MosaicAccelerate
import MosaicAppCore

/// App 入口。页面与适配器见 App/Views、App/Adapters；逻辑在 Packages/MosaicAppCore（Linux 可测）。
@main
struct PhotoMosaicApp: App {
    @StateObject private var model = AppModel(buildFlags: BuildFlags(internalTools: PhotoMosaicApp.hasInternalTools))

    /// 编译条件 `INTERNAL_TOOLS`（Debug / Internal 配置）：性能计时页、导出 8000 档、「马赛克测试」相簿开关。
    /// Release 不含任何内部工具代码（CI 用二进制标记检查，见 ios.yml / fastlane/Fastfile）。
    static var hasInternalTools: Bool {
        #if INTERNAL_TOOLS
        return true
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

/// 根据平台选择距离内核：Apple 平台注入 Accelerate 版（目前委托给参考实现）。
enum KernelProvider {
    static func make() -> any DistanceKernel {
        #if canImport(Accelerate)
        return AccelerateKernel()
        #else
        return ScalarSIMDKernel()
        #endif
    }
}
