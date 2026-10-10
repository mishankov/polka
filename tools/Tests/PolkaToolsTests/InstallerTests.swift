import CryptoKit
import Foundation
import XCTest

@testable import PolkaTools

/// Actual installer, checksum, staging and rollback; only OS/network commands
/// are substituted by the independently launched Swift fixture executable.
final class InstallerTests: XCTestCase {
  private final class Fixture {
    let root: URL, applications: URL, downloads: URL, bundle: URL, log: URL
    var environment: [String: String]
    var target: URL { applications.appendingPathComponent("Polka.app") }
    init(_ options: [String: String] = [:]) throws {
      root = try Files.temporary("polka-installer")
      applications = root.appendingPathComponent("Applications with spaces")
      downloads = root.appendingPathComponent("downloads")
      bundle = root.appendingPathComponent("bundle")
      log = root.appendingPathComponent("calls.jsonl")
      let bin = root.appendingPathComponent("bin")
      for directory in [bin, applications, downloads, bundle] { try Files.mkdir(directory) }
      let archive = Data("Release ZIP fixture".utf8)
      try archive.write(to: root.appendingPathComponent("archive.zip"))
      let checksum = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
      try TestSupport.write(
        checksum + "  polka-0.5.0-arm64.zip\n", to: root.appendingPathComponent("checksums.txt"))
      try TestSupport.write("new", to: bundle.appendingPathComponent("version"))
      try TestSupport.write("quarantined", to: bundle.appendingPathComponent("quarantine"))
      try Data().write(to: log)
      for command in [
        "uname", "sw_vers", "pgrep", "curl", "zipinfo", "ditto", "plutil", "codesign", "xattr",
        "mv", "open", "sudo",
      ] {
        try FileManager.default.createSymbolicLink(
          at: bin.appendingPathComponent(command), withDestinationURL: TestSupport.fixture)
      }
      environment = ProcessInfo.processInfo.environment
      environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
      environment["TMPDIR"] = downloads.path
      environment["INSTALL_TEST_ROOT"] = root.path
      environment["INSTALL_TEST_LOG"] = log.path
      environment.merge(options) { _, new in new }
    }
    func run(_ args: [String] = []) throws -> Command.Result {
      try Command.execute(
        "/bin/bash",
        [
          TestSupport.root.appendingPathComponent("scripts/install.sh").path, "--install-dir",
          applications.path,
        ] + args, environment: environment)
    }
    func calls() throws -> [[String: Any]] {
      try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
      }
    }
    func existing() throws {
      try Files.mkdir(target)
      try TestSupport.write("old", to: target.appendingPathComponent("version"))
    }
    func clean() throws {
      func writable(_ path: URL) throws {
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        for child in try FileManager.default.contentsOfDirectory(
          at: path, includingPropertiesForKeys: nil)
        { try writable(child) }
      }
      try writable(root)
      try FileManager.default.removeItem(at: root)
    }
  }
  private func failure(
    _ options: [String: String], message: String = "", file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let fixture = try Fixture(options)
    defer { try? fixture.clean() }
    try fixture.existing()
    let result = try fixture.run()
    XCTAssertNotEqual(result.status, 0, file: file, line: line)
    if !message.isEmpty {
      XCTAssertTrue(result.error.contains(message), result.error, file: file, line: line)
    }
    XCTAssertEqual(
      try String(contentsOf: fixture.target.appendingPathComponent("version"), encoding: .utf8),
      "old", file: file, line: line)
    XCTAssertEqual(
      try TestSupport.children(fixture.applications), ["Polka.app"], file: file, line: line)
    XCTAssertEqual(try TestSupport.children(fixture.downloads), [], file: file, line: line)
    XCTAssertFalse(
      try fixture.calls().contains { $0["command"] as? String == "open" }, file: file, line: line)
  }
  func testVerifiedReleaseRemovesQuarantineAndLaunches() throws {
    let fixture = try Fixture()
    defer { try? fixture.clean() }
    let result = try fixture.run()
    XCTAssertEqual(result.status, 0, result.error)
    XCTAssertEqual(
      try String(contentsOf: fixture.target.appendingPathComponent("version"), encoding: .utf8),
      "new")
    XCTAssertEqual(try TestSupport.children(fixture.target), ["version"])
    XCTAssertEqual(try TestSupport.children(fixture.downloads), [])
    XCTAssertEqual(try TestSupport.children(fixture.applications), ["Polka.app"])
    let calls = try fixture.calls()
    let downloads = calls.filter { $0["command"] as? String == "curl" }.dropFirst().compactMap {
      ($0["args"] as? [String])?.last
    }
    XCTAssertEqual(
      downloads,
      [
        "https://github.com/mishankov/polka/releases/download/v0.5.0/polka-0.5.0-arm64.zip",
        "https://github.com/mishankov/polka/releases/download/v0.5.0/checksums.txt",
      ])
    XCTAssertEqual(calls.filter { $0["command"] as? String == "codesign" }.count, 2)
    let xattr = calls.first { $0["command"] as? String == "xattr" }?["args"] as? [String] ?? []
    XCTAssertEqual(Array(xattr.prefix(2)), ["-dr", "com.apple.quarantine"])
    XCTAssertTrue(xattr.last?.hasPrefix(fixture.applications.path + "/.polka-install.") == true)
    XCTAssertEqual(
      calls.first { $0["command"] as? String == "open" }?["args"] as? [String],
      [fixture.target.path])
    XCTAssertFalse(calls.contains { $0["command"] as? String == "sudo" })
  }
  func testExistingAppReplacementWithoutLaunch() throws {
    let fixture = try Fixture()
    defer { try? fixture.clean() }
    try fixture.existing()
    let result = try fixture.run(["--no-launch"])
    XCTAssertEqual(result.status, 0, result.error)
    XCTAssertEqual(
      try String(contentsOf: fixture.target.appendingPathComponent("version"), encoding: .utf8),
      "new")
    XCTAssertEqual(try TestSupport.children(fixture.applications), ["Polka.app"])
    XCTAssertFalse(try fixture.calls().contains { $0["command"] as? String == "open" })
  }
  func testReadOnlyReleaseFilesCanBePreparedWithoutSudo() throws {
    let fixture = try Fixture()
    defer { try? fixture.clean() }
    try fixture.existing()
    for name in ["version", "quarantine"] {
      try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent(name))
    }
    let contents = fixture.bundle.appendingPathComponent("Contents")
    let executable = contents.appendingPathComponent("MacOS/Polka")
    let license = contents.appendingPathComponent("Resources/licenses/swift-system/LICENSE.txt")
    try Files.mkdir(executable.deletingLastPathComponent())
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    try TestSupport.write("License fixture", to: license)
    let info = [
      "CFBundleIdentifier": "app.polka.desktop", "CFBundleExecutable": "Polka",
      "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.5.0",
      "CFBundleVersion": "0.5.0",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    try Command.run("/usr/bin/codesign", ["--force", "--sign", "-", fixture.bundle.path])
    for path in [fixture.bundle, license, executable] {
      try Command.run(
        "/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;0;PolkaInstallerTests;", path.path])
    }
    try Command.run(
      "/usr/bin/xattr", ["-w", "app.polka.installer-test", "preserved", license.path])
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: license.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: executable.path)
    // Exercise actual macOS permission checks and code signatures, rather than the stand-ins.
    for command in ["xattr", "codesign"] {
      let link = fixture.root.appendingPathComponent("bin/" + command)
      try FileManager.default.removeItem(at: link)
      try FileManager.default.createSymbolicLink(
        at: link, withDestinationURL: URL(fileURLWithPath: "/usr/bin/" + command))
    }
    let result = try fixture.run(["--no-launch"])
    XCTAssertEqual(result.status, 0, result.error)
    guard result.status == 0 else { return }
    let installedLicense = fixture.target.appendingPathComponent(
      "Contents/Resources/licenses/swift-system/LICENSE.txt")
    let installedExecutable = fixture.target.appendingPathComponent("Contents/MacOS/Polka")
    for path in [fixture.target, installedLicense, installedExecutable] {
      let attributes = try Command.capture("/usr/bin/xattr", [path.path])
      XCTAssertFalse(attributes.contains("com.apple.quarantine"), attributes)
    }
    XCTAssertEqual(
      try Command.capture(
        "/usr/bin/xattr", ["-p", "app.polka.installer-test", installedLicense.path]
      )
      .trimmingCharacters(in: .whitespacesAndNewlines), "preserved")
    XCTAssertEqual(try Data(contentsOf: installedLicense), try Data(contentsOf: license))
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: installedExecutable.path)[.posixPermissions]
        as? Int,
      0o755)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: license.path)[.posixPermissions] as? Int,
      0o444)
    XCTAssertFalse(try fixture.calls().contains { $0["command"] as? String == "sudo" })
    XCTAssertEqual(try TestSupport.children(fixture.applications), ["Polka.app"])
    XCTAssertEqual(try TestSupport.children(fixture.downloads), [])
  }
  func testUnsupportedPlatform() throws {
    try failure(["PLATFORM": "Linux"], message: "requires macOS")
  }
  func testIntelOrRosetta() throws {
    try failure(["ARCH": "x86_64"], message: "requires Apple silicon")
  }
  func testOlderMacOS() throws { try failure(["OS_VERSION": "26.1"], message: "requires macOS 27") }
  func testRunningApp() throws { try failure(["RUNNING": "true"], message: "Quit Polka") }
  func testWrongReleaseHost() throws {
    try failure(
      ["RELEASE_URL": "https://example.com/releases/tag/v0.5.0"], message: "resolve the latest")
  }
  func testUnsafeReleaseTag() throws {
    try failure(
      ["RELEASE_URL": "https://github.com/mishankov/polka/releases/tag/v0.5.0%2Fbad"],
      message: "Unsupported release tag")
  }
  func testNetworkFailure() throws { try failure(["DOWNLOAD_FAILURE": "true"]) }
  func testZIPTraversal() throws {
    try failure(["ZIP_ENTRIES": "Polka.app/../../outside"], message: "Unsafe path")
  }
  func testUnexpectedZIPRoot() throws {
    try failure(["ZIP_ENTRIES": "Other.app/Contents/Info.plist"], message: "Unexpected path")
  }
  func testWrongAppIdentity() throws {
    try failure(["BUNDLE_ID": "app.other"], message: "Unexpected app identity")
  }
  func testWrongAppVersion() throws {
    try failure(["BUNDLE_VERSION": "0.4.0"], message: "does not match")
  }
  func testInvalidSignature() throws { try failure(["SIGNATURE_FAILURE": "true"]) }
  func testInvalidStagedSignature() throws { try failure(["STAGED_SIGNATURE_FAILURE": "true"]) }
  func testFailedStagingCopy() throws { try failure(["COPY_FAILURE": "true"]) }
  func testFailedQuarantineRemoval() throws { try failure(["QUARANTINE_FAILURE": "true"]) }
  func testFailedReplacementRollback() throws { try failure(["MOVE_FAILURE": "true"]) }
  private func checksumFailure(_ mode: String) throws {
    let fixture = try Fixture()
    defer { try? fixture.clean() }
    let path = fixture.root.appendingPathComponent("checksums.txt")
    let original = try String(contentsOf: path, encoding: .utf8)
    try TestSupport.write(
      mode == "wrong"
        ? String(repeating: "0", count: 64) + "  polka-0.5.0-arm64.zip\n"
        : mode == "missing" ? "" : original + original, to: path)
    let result = try fixture.run()
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.error.contains("checksum"), result.error)
    XCTAssertEqual(try TestSupport.children(fixture.applications), [])
    XCTAssertFalse(try fixture.calls().contains { $0["command"] as? String == "ditto" })
  }
  func testWrongChecksumBeforeExtraction() throws { try checksumFailure("wrong") }
  func testMissingChecksumBeforeExtraction() throws { try checksumFailure("missing") }
  func testDuplicateChecksumBeforeExtraction() throws { try checksumFailure("duplicate") }
  func testLaunchFailureKeepsInstalledAppAvailable() throws {
    let fixture = try Fixture(["LAUNCH_FAILURE": "true"])
    defer { try? fixture.clean() }
    let result = try fixture.run()
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.error.contains("is installed, but could not be opened"))
    XCTAssertEqual(
      try String(contentsOf: fixture.target.appendingPathComponent("version"), encoding: .utf8),
      "new")
    XCTAssertEqual(try TestSupport.children(fixture.applications), ["Polka.app"])
    XCTAssertEqual(try TestSupport.children(fixture.downloads), [])
  }
  func testProtectedInstallationRequestsAuthorizationOnlyWhenNeeded() throws {
    let fixture = try Fixture()
    defer { try? fixture.clean() }
    try fixture.existing()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: fixture.target.path)
    let result = try fixture.run(["--no-launch"])
    XCTAssertEqual(result.status, 0, result.error)
    let sudo = try fixture.calls().filter { $0["command"] as? String == "sudo" }.compactMap {
      $0["args"] as? [String]
    }
    XCTAssertEqual(sudo.first, ["-v"])
    XCTAssertTrue(sudo.contains { $0.first == "xattr" })
    XCTAssertTrue(sudo.contains { $0.first == "mv" })
    XCTAssertEqual(
      try String(contentsOf: fixture.target.appendingPathComponent("version"), encoding: .utf8),
      "new")
  }
  func testIncompletePipedInstallerNeverStartsInstallation() throws {
    let fixture = try Fixture()
    defer { try? fixture.clean() }
    let source = try String(
      contentsOf: TestSupport.root.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
    let marker = try XCTUnwrap(source.range(of: "  printf 'Installing in %s"))
    let result = try Command.execute(
      "/bin/bash", environment: fixture.environment, input: Data(source[..<marker.lowerBound].utf8))
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(try fixture.calls().isEmpty)
    XCTAssertEqual(try TestSupport.children(fixture.applications), [])
  }
}
