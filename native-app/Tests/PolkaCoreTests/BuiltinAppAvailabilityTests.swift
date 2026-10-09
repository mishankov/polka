import Foundation
import PolkaCore
import XCTest

final class BuiltinAppAvailabilityTests: XCTestCase {
  func testDefaultsIndependentChoicesAndInstalledApps() {
    var availability = BuiltinAppAvailability()
    let mac = NativeLauncherApp(id: "builtin:clipboard", name: "Installed", kind: .mac)
    let future = NativeLauncherApp(id: "builtin:future", name: "Future", kind: .builtin)
    XCTAssertEqual(availability.catalog(LauncherSearch.builtinApps).count, 4)
    availability.overrides["builtin:clipboard"] = false
    XCTAssertFalse(availability.allows(destination: "clipboard"))
    XCTAssertTrue(availability.allows(destination: "snippets"))
    XCTAssertTrue(availability.allows(destination: "apps"))
    XCTAssertTrue(availability.allows(destination: "settings"))
    XCTAssertEqual(availability.catalog([mac, future]), [mac, future])
    XCTAssertFalse(
      availability.catalog(LauncherSearch.builtinApps).contains { $0.id == "builtin:clipboard" })
  }
  func testSettingsSurviveRestartAndKeepUnknownIDsForUpgrades() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = ["builtin:clipboard": false, "builtin:snippets": true, "builtin:future": false]
    let store = try SettingsStore(root: root)
    try store.set(key: BuiltinAppAvailability.settingsKey, value: saved)
    store.close()
    let reopened = try SettingsStore(root: root)
    let availability = BuiltinAppAvailability(
      overrides: try XCTUnwrap(
        reopened.get(key: BuiltinAppAvailability.settingsKey) as? [String: Bool]))
    XCTAssertEqual(availability.overrides, saved)
    XCTAssertFalse(availability.allows(destination: "future"))
    XCTAssertTrue(availability.allows(destination: "newly-introduced"))
  }
}
