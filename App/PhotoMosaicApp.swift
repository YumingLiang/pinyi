import SwiftUI
import MosaicCore
import MosaicAccelerate
import MosaicAppCore

/// App 入口。页面与适配器见 App/Views、App/Adapters；逻辑在 Packages/MosaicAppCore（Linux 可测）。
@main
struct PhotoMosaicApp: App {
    @StateObject private var model = AppModel(buildFlags: BuildFlags(showsPerformanceEntryInSettings: PhotoMosaicApp.perfPageInSettings))

    /// 决定 18：内部 / TestFlight 构建（编译条件 `PERF_PAGE`）在设置页显示「性能测试」。
    static var perfPageInSettings: Bool {
        #if PERF_PAGE
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
