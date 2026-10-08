import Foundation
import XCTest

@testable import PolkaTools

final class AutomationTests: XCTestCase {
  func testCommandOptionsAndInvalidCombinations() throws {
    let value = try ToolRequest(["verify", "--no-desktop", "--release"])
    XCTAssertEqual(value.flags, ["no-desktop", "release"])
    for arguments in [
      ["unknown"], ["dev", "--publish"], ["test", "wrong"], ["test", "all", "app"],
      ["build", "--debug", "--release"], ["build", "--official", "--development-signing"],
      ["verify", "--no-desktop", "--external-drops"], ["package", "--dir", "--desktop"],
      ["desktop", "unknown"], ["coverage", "unexpected"],
    ] {
      XCTAssertThrowsError(try ToolRequest(arguments), "\(arguments)")
    }
    for command in ["core", "all", "updates", "files"] {
      XCTAssertEqual(
        try ToolRequest(["desktop", command, "--prebuilt", "--release"]).positionals, [command])
    }
  }
  func testNativeMetadataAndBothPackageManifests() throws {
    let metadata = try PolkaMetadata.load(root: TestSupport.root)
    XCTAssertEqual(metadata.name, "polka")
    XCTAssertEqual(metadata.build.appId, "app.everything.desktop")
    XCTAssertNoThrow(try ReleaseVersion.parse(metadata.version))
    XCTAssertNoThrow(try JSONEncoder().encode(metadata))
  }
  func testCIUsesSwiftVerificationAndRetainsReleaseGates() throws {
    let action = try String(
      contentsOf: TestSupport.root.appendingPathComponent(
        ".github/actions/prepare-macos/action.yml"), encoding: .utf8)
    let build = try String(
      contentsOf: TestSupport.root.appendingPathComponent(".github/workflows/build.yml"),
      encoding: .utf8)
    let release = try String(
      contentsOf: TestSupport.root.appendingPathComponent(".github/workflows/release.yml"),
      encoding: .utf8)
    for text in [action, build, release] {
      for old in ["setup-node", "npm ", ".node-version", "node-version", "scripts/release/"] {
        XCTAssertFalse(text.contains(old), old)
      }
    }
    XCTAssertTrue(action.contains("swift package --package-path native-app resolve"))
    XCTAssertTrue(action.contains("swift package --package-path tools resolve"))
    XCTAssertTrue(build.contains("needs: [verify, package, updates]"))
    XCTAssertTrue(build.contains("name: Verify and package macOS arm64"))
    XCTAssertTrue(build.contains("./polka package --prebuilt --desktop"))
    XCTAssertTrue(release.contains("./polka release-prepare"))
    XCTAssertTrue(release.contains("needs: [prepare, verify, build]"))
    XCTAssertTrue(release.contains("ref: ${{ needs.prepare.outputs.commit }}"))
    XCTAssertTrue(release.contains("./polka verify --no-desktop"))
    XCTAssertTrue(release.contains("./polka release --desktop"))
  }
}
