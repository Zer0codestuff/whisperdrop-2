import XCTest
@testable import WhisperDrop

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultsPreferTurboAndTenMinuteResidency() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!)
        XCTAssertEqual(settings.model.id, "turbo")
        XCTAssertEqual(settings.residency, .tenMinutes)
        XCTAssertEqual(settings.hotkey, .fn)
    }
}
