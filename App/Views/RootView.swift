import SwiftUI
import MosaicAppCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.route {
            case .onboarding: OnboardingView()
            case .permission(let p): PermissionView(prompt: p)
            case .main: MainFlowView()
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { model.scenePhaseChanged($0) }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: Binding(get: { model.onboarding.page }, set: { model.onboarding.swipe(to: $0) })) {
                ForEach(0..<OnboardingFlow.pageCount, id: \.self) { i in
                    let page = OnboardingFlow(page: i)
                    VStack(spacing: 16) {
                        Text(page.titleKey).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(page.bodyKey).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button { model.onboardingButtonTapped() } label: {
                Text(model.onboarding.buttonKey(authorization: model.library.authorizationStatus())).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

struct PermissionView: View {
    @EnvironmentObject var model: AppModel
    let prompt: PermissionPrompt

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 56)).foregroundStyle(.tint)
            Text(prompt.titleKey).font(.title2.bold()).multilineTextAlignment(.center)
            Text(prompt.bodyKey).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button { model.permissionAction(.primary, on: prompt) } label: {
                Text(prompt.primaryKey).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Button { model.permissionAction(.secondary, on: prompt) } label: { Text(prompt.secondaryKey) }
            if let link = prompt.linkKey {
                Button { model.permissionAction(.link, on: prompt) } label: { Text(link).font(.footnote) }
            }
        }
        .padding(24)
    }
}
