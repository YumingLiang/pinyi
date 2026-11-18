import XCTest
@testable import MosaicAppCore

final class PermissionTests: XCTestCase {
    func testStatusToPromptMapping() {
        XCTAssertEqual(PermissionPrompt.forStatus(.notDetermined), .undetermined)
        XCTAssertEqual(PermissionPrompt.forStatus(.limited), .limited)
        XCTAssertEqual(PermissionPrompt.forStatus(.denied), .denied)
        XCTAssertEqual(PermissionPrompt.forStatus(.restricted), .denied, "决定 7：restricted 与 denied 共用")
        XCTAssertNil(PermissionPrompt.forStatus(.authorized))
        XCTAssertEqual(PhotoAuthorization.authorized.access, .full)
        XCTAssertEqual(PhotoAuthorization.limited.access, .limited)
        XCTAssertNil(PhotoAuthorization.denied.access)
    }

    func testPromptKeys() {
        XCTAssertEqual(PermissionPrompt.limited.primaryKey, .limitedPrimary)
        XCTAssertEqual(PermissionPrompt.limited.linkKey, .limitedAllowAllLink)
        XCTAssertNil(PermissionPrompt.denied.linkKey)
        XCTAssertEqual(PermissionPrompt.undetermined.titleKey.rawValue, "permission.undetermined.title")
    }

    func testEffects() {
        XCTAssertEqual(PermissionLogic.effect(for: .primary, on: .undetermined), .requestAuthorization)
        XCTAssertEqual(PermissionLogic.effect(for: .secondary, on: .undetermined), .showOnboarding)
        XCTAssertEqual(PermissionLogic.effect(for: .primary, on: .limited), .presentLimitedPicker, "决定 1")
        XCTAssertEqual(PermissionLogic.effect(for: .secondary, on: .limited), .proceed(.limited))
        XCTAssertEqual(PermissionLogic.effect(for: .link, on: .limited), .openSettings)
        XCTAssertEqual(PermissionLogic.effect(for: .primary, on: .denied), .openSettings)
        XCTAssertEqual(PermissionLogic.effect(for: .secondary, on: .denied), .dismiss)
    }

    func testOnboardingPagesAndFinalButton() {
        var f = OnboardingFlow()
        XCTAssertEqual(f.titleKey, .onboarding1Title)
        XCTAssertEqual(f.buttonKey(authorization: .notDetermined), .onboarding1Next)
        XCTAssertNil(f.advance(authorization: .notDetermined))
        XCTAssertNil(f.advance(authorization: .notDetermined))
        XCTAssertTrue(f.isLastPage)
        XCTAssertEqual(f.buttonKey(authorization: .notDetermined), .onboarding3Allow)
        XCTAssertEqual(f.buttonKey(authorization: .authorized), .onboarding3Start)
        XCTAssertEqual(f.advance(authorization: .notDetermined), .requestAuthorization)
        XCTAssertEqual(f.advance(authorization: .authorized), .proceed(.full))
        XCTAssertNil(f.advance(authorization: .denied))
        f.swipe(to: 99)
        XCTAssertEqual(f.page, 2)
        f.swipe(to: -3)
        XCTAssertEqual(f.page, 0)
    }

    func testAppRoute() {
        XCTAssertEqual(AppRoute.resolve(authorization: .authorized, hasCompletedOnboarding: false, limitedAcknowledged: false), .onboarding)
        XCTAssertEqual(AppRoute.resolve(authorization: .authorized, hasCompletedOnboarding: true, limitedAcknowledged: false), .main(.full))
        XCTAssertEqual(AppRoute.resolve(authorization: .limited, hasCompletedOnboarding: true, limitedAcknowledged: false), .permission(.limited))
        XCTAssertEqual(AppRoute.resolve(authorization: .limited, hasCompletedOnboarding: true, limitedAcknowledged: true), .main(.limited))
        XCTAssertEqual(AppRoute.resolve(authorization: .notDetermined, hasCompletedOnboarding: true, limitedAcknowledged: false), .permission(.undetermined))
        XCTAssertEqual(AppRoute.resolve(authorization: .restricted, hasCompletedOnboarding: true, limitedAcknowledged: true), .permission(.denied))
    }

    func testFakeLibraryRequestAuthorizationFlow() async {
        let lib = FakePhotoLibrary()
        lib.state.update { $0.auth = .notDetermined; $0.authAfterRequest = .limited }
        XCTAssertEqual(PermissionPrompt.forStatus(lib.authorizationStatus()), .undetermined)
        let s = await lib.requestAuthorization()
        XCTAssertEqual(AppRoute.resolve(authorization: s, hasCompletedOnboarding: true, limitedAcknowledged: false), .permission(.limited))
    }
}
