import Foundation
import PolkaCore
import XCTest

@testable import PolkaApp

final class DevelopmentKeychainTests: XCTestCase {
  func testUnconfiguredAndOfficialBundlesKeepDirectKeychainPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Example.app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    func bundle(_ info: [String: Any]) throws -> Bundle {
      let data = try PropertyListSerialization.data(
        fromPropertyList: info, format: .xml, options: 0)
      try data.write(to: contents.appendingPathComponent("Info.plist"))
      return try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
    }
    let official = try bundle([
      "CFBundleIdentifier": "app.polka.test-official", "CFBundleExecutable": "App",
      "PolkaDevelopmentSigningFingerprint": String(repeating: "AB", count: 20),
    ])
    XCTAssertNil(NativeDevelopmentKeychain.codec(bundle: official, allowCreate: false))
  }

  func testInvalidMetadataAndUntrustedHostCannotLaunchBroker() {
    // Even an executable capable of accessing Keychain must never be launched
    // before both metadata and the app's actual signature have been validated.
    let executable = URL(fileURLWithPath: "/usr/bin/security")
    for (fingerprint, appId) in [
      ("invalid", "app.polka.test"),
      (String(repeating: "AB", count: 20), "app.polka.test\" or true"),
      (String(repeating: "AB", count: 20), "app.polka.untrusted-host"),
    ] {
      let reader = NativeDevelopmentKeychain(
        broker: executable, fingerprint: fingerprint, appId: appId)
      XCTAssertThrowsError(try reader.password(allowCreate: true))
      reader.stop()
      XCTAssertThrowsError(try reader.password(allowCreate: false))
    }
  }
}
