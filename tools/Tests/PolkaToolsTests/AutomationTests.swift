import Foundation
import XCTest

@testable import PolkaTools

final class AutomationTests: XCTestCase {
  func testBuildSystemOverrideIsExplicitAndRetainedAfterRemovingSigningSecrets() {
    let context = ToolContext(environment: [
      "POLKA_SWIFT_BUILD_SYSTEM": "native", "POLKA_SIGNING_PASSWORD": "private",
    ])
    XCTAssertEqual(context.swiftBuildArguments, ["--build-system", "native"])
    let publicContext = ToolContext(environment: SigningTool.publicEnvironment(context.environment))
    XCTAssertEqual(publicContext.swiftBuildArguments, context.swiftBuildArguments)
    XCTAssertNil(publicContext.environment["POLKA_SIGNING_PASSWORD"])
    XCTAssertTrue(ToolContext(environment: [:]).swiftBuildArguments.isEmpty)
  }
  func testBuildParallelismReachesAppCommandsWithoutExposingSigningSecrets() {
    let context = ToolContext(environment: [
      "POLKA_SWIFT_BUILD_SYSTEM": "native", "POLKA_SWIFT_BUILD_JOBS": "3",
      "POLKA_SIGNING_PASSWORD": "private",
    ])
    XCTAssertEqual(context.swiftBuildArguments, ["--build-system", "native", "--jobs", "3"])
    let publicContext = ToolContext(environment: SigningTool.publicEnvironment(context.environment))
    XCTAssertEqual(publicContext.swiftBuildArguments, context.swiftBuildArguments)
    for value in ["0", "-1", "invalid"] {
      XCTAssertTrue(
        ToolContext(environment: ["POLKA_SWIFT_BUILD_JOBS": value]).swiftBuildArguments.isEmpty)
    }
  }
  func testBootstrapSharesDebugToolingButRetainsAppBuildRequest() throws {
    let temporary = try Files.temporary("polka-bootstrap")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let swift = temporary.appendingPathComponent("swift")
    try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: swift)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: swift.path)
    let bootstrap = TestSupport.root.appendingPathComponent("polka").path
    for configuration in ["debug", "release"] {
      var environment = ProcessInfo.processInfo.environment
      for key in ["POLKA_TOOLS_CONFIGURATION", "POLKA_SWIFT_BUILD_JOBS"] {
        environment.removeValue(forKey: key)
      }
      environment["PATH"] = temporary.path + ":" + (environment["PATH"] ?? "")
      // The app engine never changes the engine used to bootstrap the shared CLI cache.
      environment["POLKA_SWIFT_BUILD_SYSTEM"] = "native"
      if configuration == "debug" {
        environment["POLKA_TOOLS_CONFIGURATION"] = configuration
        environment["POLKA_SWIFT_BUILD_JOBS"] = "3"
      }
      let output = try Command.capture(bootstrap, ["build", "--release"], environment: environment)
      let expected =
        ["run"] + (configuration == "debug" ? ["--jobs", "3"] : [])
        + [
          "--package-path", TestSupport.root.appendingPathComponent("tools").path,
          "--configuration", configuration, "polka-tool", "build", "--release",
        ]
      XCTAssertEqual(output.split(separator: "\n").map(String.init), expected)
    }
  }
  func testCommandOptionsAndInvalidCombinations() throws {
    let value = try ToolRequest(["verify", "--no-desktop", "--release"])
    XCTAssertEqual(value.flags, ["no-desktop", "release"])
    XCTAssertTrue(
      try ToolRequest(["verify", "--no-desktop", "--no-tools"]).flags.contains("no-tools"))
    for arguments in [
      ["unknown"], ["dev", "--publish"], ["test", "wrong"], ["test", "all", "app"],
      ["build", "--debug", "--release"], ["build", "--official", "--development-signing"],
      ["verify", "--no-desktop", "--external-drops"], ["package", "--dir", "--desktop"],
      ["desktop", "unknown"], ["coverage", "unexpected"],
    ] {
      XCTAssertThrowsError(try ToolRequest(arguments), "\(arguments)")
    }
    for command in ["core", "settings", "all", "updates", "files"] {
      XCTAssertEqual(
        try ToolRequest(["desktop", command, "--prebuilt", "--release"]).positionals, [command])
    }
  }
  func testNativeMetadataAndBothPackageManifests() throws {
    let metadata = try PolkaMetadata.load(root: TestSupport.root)
    XCTAssertEqual(metadata.name, "polka")
    XCTAssertEqual(metadata.build.appId, "app.polka.desktop")
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
    XCTAssertTrue(build.contains("needs: [verify, tooling, package]"))
    XCTAssertTrue(build.contains("name: Verify and package macOS arm64"))
    XCTAssertTrue(build.contains("./polka package --desktop"))
    XCTAssertTrue(release.contains("./polka release-prepare"))
    XCTAssertTrue(release.contains("needs: [prepare, verify, tooling, updates, build]"))
    XCTAssertTrue(release.contains("ref: ${{ needs.prepare.outputs.commit }}"))
    XCTAssertTrue(release.contains("./polka verify --no-desktop"))
    XCTAssertTrue(release.contains("./polka release --desktop"))
  }
}
