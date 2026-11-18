import SwiftUI
import MosaicAppCore

/// 设置页。内部工具（性能测试等）只在 `INTERNAL_TOOLS` 构建里编译（决定 18 + 架构师 2026-11-16）。
struct SettingsPageView: View {
    @EnvironmentObject var model: AppModel
    @State private var showInternalFromAbout = false

    var body: some View {
        List {
            #if INTERNAL_TOOLS
            if model.buildFlags.showsPerformanceEntryInSettings {
                NavigationLink { InternalToolsView() } label: { Text(L10nKey.settingsPerformance) }
            }
            #endif
            NavigationLink { AboutView(onUnlock: { showInternalFromAbout = true }) } label: { Text(L10nKey.settingsAbout) }
        }
        .navigationTitle(Text(L10nKey.settingsTitle))
        #if INTERNAL_TOOLS
        .navigationDestination(isPresented: $showInternalFromAbout) { InternalToolsView() }
        #endif
    }
}

struct AboutView: View {
    let onUnlock: () -> Void
    @State private var taps = HiddenEntryTapCounter()

    var body: some View {
        VStack(spacing: 12) {
            Text(L10nKey.aboutTitle).font(.title3.bold())
            Text(L10nKey.aboutBody).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(verbatim: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                .font(.footnote).monospacedDigit()
                .onTapGesture {
                    // Release 不含性能页，连点入口也不生效（见 BuildFlags.allowsHiddenPerformanceEntry）。
                    #if INTERNAL_TOOLS
                    if taps.tap(at: MonotonicClock.system.now()) { onUnlock() }
                    #endif
                }
        }
        .padding(32)
    }
}
