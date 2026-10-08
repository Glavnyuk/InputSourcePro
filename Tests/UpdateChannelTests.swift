import XCTest
@testable import Input_Source_Pro

@MainActor
final class UpdateChannelTests: XCTestCase {
    func testStableInstallPersistsStableChoiceAcrossBetaUpgrade() {
        let name = "UpdateChannelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let stable = UpdateChannelSettings(defaults: defaults, isBetaBuild: false)
        XCTAssertFalse(stable.receivesBetaUpdates)
        XCTAssertEqual(stable.feedURL, "https://inputsource.pro/stable/appcast.xml")
        XCTAssertFalse(UpdateChannelSettings(defaults: defaults, isBetaBuild: true).receivesBetaUpdates)
    }

    func testBetaInstallAndExplicitChoiceSurviveRelaunch() {
        let name = "UpdateChannelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let beta = UpdateChannelSettings(defaults: defaults, isBetaBuild: true)
        XCTAssertTrue(beta.receivesBetaUpdates)
        XCTAssertEqual(beta.feedURL, "https://inputsource.pro/beta/appcast.xml")
        beta.receivesBetaUpdates = false
        XCTAssertEqual(beta.feedURL, "https://inputsource.pro/stable/appcast.xml")
        XCTAssertFalse(UpdateChannelSettings(defaults: defaults, isBetaBuild: true).receivesBetaUpdates)
        beta.receivesBetaUpdates = true
        XCTAssertTrue(UpdateChannelSettings(defaults: defaults, isBetaBuild: false).receivesBetaUpdates)
    }
}


@MainActor
final class LaunchTelemetrySettingsTests: XCTestCase {
    func testDefaultsToOffAndRemembersExplicitChoice() {
        let name = "LaunchTelemetrySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LaunchTelemetrySettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)
        settings.isEnabled = true
        XCTAssertTrue(LaunchTelemetrySettings(defaults: defaults).isEnabled)
        settings.isEnabled = false
        XCTAssertFalse(LaunchTelemetrySettings(defaults: defaults).isEnabled)
    }
}


@MainActor
final class SettingsImportConfirmationTests: XCTestCase {
    func testCancelIsDefaultAndFileNameIsVisible() {
        let alert = PreferencesVM.settingsImportConfirmation(from: URL(fileURLWithPath: "/tmp/untrusted-settings.json"))
        XCTAssertEqual(alert.buttons.count, 2)
        XCTAssertEqual(alert.buttons[0].title, "Cancel".i18n())
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].title, "Import Settings".i18n())
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertTrue(alert.informativeText.contains("untrusted-settings.json"))
    }
}
