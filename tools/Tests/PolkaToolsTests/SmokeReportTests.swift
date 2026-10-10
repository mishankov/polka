import Foundation
import XCTest

@testable import PolkaTools

final class SmokeReportTests: XCTestCase {
  func testActualPermissionNoticeReportIsBlockedStartupNotClipboardCore() throws {
    // Captured from the real relocated AppKit permission-sheet Quit fixture.
    // Like startup, notice runs before any synthetic history is initialized.
    let bytes = Data(
      #"{"destination":"apps","failures":[],"nativeVisible":true,"ok":true,"storageStatus":"starting"}"#
        .utf8)
    let report = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    XCTAssertNoThrow(try Desktop.validateSmoke(report, phase: "notice"))
    XCTAssertNoThrow(try Desktop.validateSmoke(report, phase: "startup"))
    XCTAssertThrowsError(try Desktop.validateSmoke(report, phase: "core"))
    XCTAssertThrowsError(try Desktop.validateSmoke(report, phase: "settings"))
    var openedStorage = report
    openedStorage["storageStatus"] = "ready"
    XCTAssertThrowsError(try Desktop.validateSmoke(openedStorage, phase: "notice"))
    var hidden = report
    hidden["nativeVisible"] = false
    XCTAssertThrowsError(try Desktop.validateSmoke(hidden, phase: "notice"))
  }
  func testCoreAndScrollKeepTheirDistinctDataAndDestinationRequirements() throws {
    let core: [String: Any] = [
      "ok": true, "failures": [], "nativeVisible": true, "destination": "clipboard", "snippets": 2,
    ]
    XCTAssertNoThrow(try Desktop.validateSmoke(core, phase: "core"))
    XCTAssertNoThrow(try Desktop.validateSmoke(core, phase: "settings"))
    var missing = core
    missing["snippets"] = 0
    XCTAssertThrowsError(try Desktop.validateSmoke(missing, phase: "core"))
    XCTAssertThrowsError(try Desktop.validateSmoke(missing, phase: "settings"))
    let scroll: [String: Any] = [
      "ok": true, "failures": [], "nativeVisible": true, "destination": "apps",
    ]
    XCTAssertNoThrow(try Desktop.validateSmoke(scroll, phase: "scroll"))
    XCTAssertThrowsError(try Desktop.validateSmoke(scroll, phase: "startup"))
    XCTAssertThrowsError(try Desktop.validateSmoke(scroll, phase: "unknown"))
  }
}
