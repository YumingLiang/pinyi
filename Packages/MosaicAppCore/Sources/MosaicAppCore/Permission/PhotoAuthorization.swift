/// 相册读取授权状态（与 `PHAuthorizationStatus` 一一对应，平台层做映射；本包不 import Photos）。
public enum PhotoAuthorization: String, Sendable, Hashable, CaseIterable, Codable {
    case notDetermined, restricted, denied, authorized, limited

    /// 素材访问范围；`nil` = 不能读取素材。
    public var access: SourceAccess? {
        switch self {
        case .authorized: return .full
        case .limited: return .limited
        case .notDetermined, .restricted, .denied: return nil
        }
    }
}

/// 可读取的素材范围（决定 8：来源首项标题随之变化）。
public enum SourceAccess: String, Sendable, Hashable, Codable {
    case full, limited
}

/// 权限提示页（文案 §3）。`.restricted` 与 `.denied` 共用同一套（决定 7）。
public enum PermissionPrompt: String, Sendable, Hashable, CaseIterable {
    case undetermined, limited, denied

    public static func forStatus(_ s: PhotoAuthorization) -> PermissionPrompt? {
        switch s {
        case .notDetermined: return .undetermined
        case .limited: return .limited
        case .denied, .restricted: return .denied
        case .authorized: return nil
        }
    }

    public var titleKey: L10nKey {
        switch self {
        case .undetermined: return .permissionUndeterminedTitle
        case .limited: return .limitedTitle
        case .denied: return .permissionDeniedTitle
        }
    }
    public var bodyKey: L10nKey {
        switch self {
        case .undetermined: return .permissionUndeterminedBody
        case .limited: return .limitedBody
        case .denied: return .permissionDeniedBody
        }
    }
    public var primaryKey: L10nKey {
        switch self {
        case .undetermined: return .permissionUndeterminedPrimary
        case .limited: return .limitedPrimary
        case .denied: return .permissionDeniedPrimary
        }
    }
    public var secondaryKey: L10nKey {
        switch self {
        case .undetermined: return .permissionUndeterminedSecondary
        case .limited: return .limitedSecondary
        case .denied: return .permissionDeniedSecondary
        }
    }
    /// 文字链接（只有受限页有：跳系统设置改为完全访问）。
    public var linkKey: L10nKey? { self == .limited ? .limitedAllowAllLink : nil }
}

/// 权限页上的用户操作。
public enum PermissionAction: Sendable, Hashable {
    case primary, secondary, link
}

/// 权限页操作要求平台层执行的副作用。
public enum PermissionEffect: Sendable, Hashable {
    /// 调 `PHPhotoLibrary.requestAuthorization(for: .readWrite)`。
    case requestAuthorization
    /// 打开 `UIApplication.openSettingsURLString`。
    case openSettings
    /// 调 `PHPhotoLibrary.shared().presentLimitedLibraryPicker(from:)`。
    case presentLimitedPicker
    /// 回到首启说明页（「先看看说明」）。
    case showOnboarding
    /// 以给定范围继续主流程。
    case proceed(SourceAccess)
    /// 关闭提示、停在首页（「以后再说」）。
    case dismiss
}

/// 权限页逻辑（文案 §3、决定 1 / 7）。纯函数，平台层只负责执行副作用。
public enum PermissionLogic {
    public static func effect(for action: PermissionAction, on prompt: PermissionPrompt) -> PermissionEffect {
        switch (prompt, action) {
        case (.undetermined, .primary): return .requestAuthorization
        case (.undetermined, .secondary): return .showOnboarding
        case (.limited, .primary): return .presentLimitedPicker
        case (.limited, .secondary): return .proceed(.limited)
        case (.limited, .link): return .openSettings
        case (.denied, .primary): return .openSettings
        case (.denied, .secondary): return .dismiss
        case (.undetermined, .link), (.denied, .link): return .dismiss   // 这两页没有链接
        }
    }
}

/// 首启说明页（文案 §1，3 屏）。
public struct OnboardingFlow: Sendable, Hashable {
    public static let pageCount = 3
    public private(set) var page: Int = 0

    public init(page: Int = 0) { self.page = min(max(page, 0), Self.pageCount - 1) }

    public var isLastPage: Bool { page == Self.pageCount - 1 }

    public var titleKey: L10nKey { [.onboarding1Title, .onboarding2Title, .onboarding3Title][page] }
    public var bodyKey: L10nKey { [.onboarding1Body, .onboarding2Body, .onboarding3Body][page] }

    /// 按钮：前两屏「下一步」；第 3 屏若接下来会弹系统权限框则「允许访问照片」，否则「开始使用」。
    public func buttonKey(authorization: PhotoAuthorization) -> L10nKey {
        switch page {
        case 0: return .onboarding1Next
        case 1: return .onboarding2Next
        default: return authorization == .notDetermined ? .onboarding3Allow : .onboarding3Start
        }
    }

    /// 点按钮：前两屏翻页（返回 nil）；最后一屏返回要执行的副作用。
    public mutating func advance(authorization: PhotoAuthorization) -> PermissionEffect? {
        if !isLastPage { page += 1; return nil }
        switch authorization {
        case .notDetermined: return .requestAuthorization
        case .authorized: return .proceed(.full)
        case .limited, .denied, .restricted: return nil   // 交给 AppRoute 显示对应权限页
        }
    }

    /// 左右滑动。
    public mutating func swipe(to newPage: Int) { page = min(max(newPage, 0), Self.pageCount - 1) }
}

/// 启动 / 回到前台时应显示的顶层页面。
public enum AppRoute: Sendable, Hashable {
    case onboarding
    case permission(PermissionPrompt)
    case main(SourceAccess)

    /// - Parameters:
    ///   - hasCompletedOnboarding: 是否看完过首启说明。
    ///   - limitedAcknowledged: 受限状态下用户是否已点过「用已选的照片继续」（之后不再每次拦截，来源页常驻「增加可用照片」）。
    public static func resolve(authorization: PhotoAuthorization, hasCompletedOnboarding: Bool,
                               limitedAcknowledged: Bool) -> AppRoute {
        if !hasCompletedOnboarding { return .onboarding }
        switch authorization {
        case .authorized: return .main(.full)
        case .limited: return limitedAcknowledged ? .main(.limited) : .permission(.limited)
        case .notDetermined: return .permission(.undetermined)
        case .denied, .restricted: return .permission(.denied)
        }
    }
}
