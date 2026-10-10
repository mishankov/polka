import PolkaCore
import XCTest

@testable import PolkaApp

final class MediaTests: XCTestCase {
  func testUnknownVisibleAndDisabledDeviceCannotShowStaleActivity() {
    XCTAssertEqual(NativeMediaPresentation.state("active", enabled: false), "disabled")
    XCTAssertEqual(NativeMediaPresentation.state("garbage", enabled: true), "unknown")
    XCTAssertTrue(NativeMediaPresentation(camera: "unknown", microphone: "disabled").visible)
    XCTAssertFalse(NativeMediaPresentation(camera: "inactive", microphone: "disabled").visible)
    XCTAssertTrue(
      NativeMediaPresentation(camera: "active", microphone: "inactive").label.contains(
        localized("Camera") + ": " + localized("in use")))
  }
  @MainActor func testDefaultTrackingAndPartialLegacyPreferences() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = try SettingsStore(root: root)
    let model = NativeUIModel()
    let first = NativeMediaMonitor(settings: settings, model: model, fixture: true)
    XCTAssertTrue(model.settings.cameraEnabled)
    XCTAssertTrue(model.settings.microphoneEnabled)
    first.stop()
    try settings.set(key: "mediaIndicatorEnabled", value: false)
    try settings.set(key: "mediaIndicatorTracking", value: ["cameraEnabled": true])
    let next = NativeMediaMonitor(settings: settings, model: model, fixture: true)
    defer {
      next.stop()
      settings.close()
    }
    XCTAssertTrue(model.settings.cameraEnabled)
    XCTAssertFalse(model.settings.microphoneEnabled)
    try next.set("camera", enabled: false)
    XCTAssertFalse(model.settings.cameraEnabled)
    XCTAssertThrowsError(try next.set("other", enabled: true))
    XCTAssertEqual(
      (try settings.get(key: "mediaIndicatorTracking") as? [String: Bool])?["cameraEnabled"], false)
  }
}
