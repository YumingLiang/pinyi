import SwiftUI
import MosaicCore
import MosaicAccelerate

/// App 入口（T1 工程骨架占位）。真正的页面（T3 权限页、T9 UI 串联等）后续卡片实现。
@main
struct PhotoMosaicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
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

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // 文案 key 来自 App/Resources/copy_v1.1.md → zh-Hans.lproj/Localizable.strings
                Text("onboarding.1.title")
                    .font(.title2)
                    .multilineTextAlignment(.center)
                Text("generate.privacy_hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("MosaicCore \(MosaicCoreInfo.version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .navigationTitle(Text("app.display_name"))
        }
    }
}
