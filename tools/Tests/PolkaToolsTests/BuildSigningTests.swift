import Foundation
import XCTest

@testable import PolkaTools

final class BuildSigningTests: XCTestCase {
  func temporary() throws -> URL { try ToolFiles.temporary("polka-tools-test-") }
  func testBuildMetadataTrustIsolationAndVersions() throws {
    let source = PolkaMetadata(version: "1.2.3")
    let environment = [
      "RELEASE_TAG": "v2.3.4", "RELEASE_REPOSITORY": "owner/polka",
      "SPARKLE_PUBLIC_KEY": Data(repeating: 7, count: 32).base64EncodedString(),
      "POLKA_SIGNING_CERT_SHA1": String(repeating: "AB", count: 20),
      "POLKA_SIGNING_KEYCHAIN": "/synthetic/signing.keychain",
    ]
    let official = try BuildTool.metadata(source: source, environment: environment, official: true)
    XCTAssertEqual(official.package.version, "2.3.4")
    XCTAssertEqual(official.appId, source.build.appId)
    XCTAssertEqual(
      official.release?.feedUrl,
      "https://github.com/owner/polka/releases/latest/download/appcast.xml")
    let plist = BuildTool.infoPlist(official, checkout: URL(fileURLWithPath: "/synthetic/checkout"))
    let parsed = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
    XCTAssertEqual(parsed["CFBundleDisplayName"] as? String, "Polka")
    XCTAssertEqual(parsed["SUAutomaticallyUpdate"] as? Bool, false)
    XCTAssertEqual(parsed["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
    XCTAssertEqual(parsed["SUScheduledCheckInterval"] as? Int, 21600)
    XCTAssertFalse(plist.contains("/synthetic/checkout"))
    let development = try BuildTool.metadata(source: source, environment: [:])
    let dev = BuildTool.infoPlist(development, checkout: URL(fileURLWithPath: "/synthetic/a&b"))
    XCTAssertTrue(dev.contains("a&amp;b"))
    XCTAssertFalse(dev.contains("SUFeedURL"))
    XCTAssertEqual(development.appId, source.build.appId + ".native-development")
    var invalid = environment
    invalid.removeValue(forKey: "POLKA_SIGNING_KEYCHAIN")
    XCTAssertThrowsError(
      try BuildTool.metadata(source: source, environment: invalid, official: true))
    invalid = environment
    invalid["POLKA_SIGNING_CERT_SHA1"] = "-"
    XCTAssertThrowsError(
      try BuildTool.metadata(source: source, environment: invalid, official: true))
  }
  func testPrebuiltRequiresNativeFrameworkResourcesAndHelpers() throws {
    let root = try temporary()
    defer { try? ToolFiles.remove(root) }
    let helper = root.appendingPathComponent("clipboard-probe")
    func check() throws { try BuildTool.assertPrepared(productsPath: root, helperPaths: [helper]) }
    XCTAssertThrowsError(try check())
    try ToolFiles.write("exe", to: root.appendingPathComponent("PolkaNative"))
    XCTAssertThrowsError(try check())
    try ToolFiles.directory(root.appendingPathComponent("Sparkle.framework"))
    try ToolFiles.write("framework", to: root.appendingPathComponent("Sparkle.framework/Sparkle"))
    XCTAssertThrowsError(try check())
    let resources = root.appendingPathComponent("PolkaNative_PolkaCore.bundle/Contents/Resources")
    try ToolFiles.directory(resources)
    try ToolFiles.write("[]", to: resources.appendingPathComponent("emoji-data.json"))
    XCTAssertThrowsError(try check())
    try ToolFiles.write("helper", to: helper)
    try check()
  }
  func testRelativeFrameworkLinksAndPackageOptions() throws {
    let root = try temporary()
    defer { try? ToolFiles.remove(root) }
    let bundle = root.appendingPathComponent("Polka.app")
    let framework = bundle.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
    try ToolFiles.directory(framework.appendingPathComponent("Versions/B/Resources"))
    try ToolFiles.manager.createSymbolicLink(
      atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "B")
    try ToolFiles.manager.createSymbolicLink(
      atPath: framework.appendingPathComponent("Resources").path,
      withDestinationPath: "Versions/Current/Resources")
    try BuildTool.assertRelativeBundleLinks(bundle)
    let invalid = framework.appendingPathComponent("invalid")
    try ToolFiles.manager.createSymbolicLink(
      atPath: invalid.path, withDestinationPath: "/absolute/.build/Sparkle.framework")
    XCTAssertThrowsError(try BuildTool.assertRelativeBundleLinks(bundle))
    try ToolFiles.remove(invalid)
    try ToolFiles.manager.createSymbolicLink(
      atPath: invalid.path, withDestinationPath: "../../../../../../escape")
    XCTAssertThrowsError(try BuildTool.assertRelativeBundleLinks(bundle))
    XCTAssertTrue(PackageOptions().buildOptions.release)
    XCTAssertFalse(PackageOptions(debug: true).buildOptions.release)
    XCTAssertThrowsError(try PackageOptions(directoryOnly: true, desktop: true).validate())
  }
  func fixture(root: URL, version: Int, appID: String) throws -> URL {
    let bundle = root.appendingPathComponent("Version\(version).app")
    let contents = bundle.appendingPathComponent("Contents")
    try ToolFiles.directory(contents.appendingPathComponent("MacOS"))
    try ToolFiles.directory(contents.appendingPathComponent("Resources"))
    func info(_ executable: String, _ id: String, _ kind: String, _ path: URL) throws {
      let values = [
        "CFBundleIdentifier": id, "CFBundleExecutable": executable, "CFBundlePackageType": kind,
        "CFBundleVersion": String(version),
      ]
      try ToolFiles.write(
        PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0), to: path
      )
    }
    try info("Main", appID, "APPL", contents.appendingPathComponent("Info.plist"))
    let source = root.appendingPathComponent("version\(version).c")
    let executable = contents.appendingPathComponent("MacOS/Main")
    try ToolFiles.write(
      "#include <stdio.h>\nint main(void) { puts(\"Version \(version)\"); return 0; }\n", to: source
    )
    _ = try Command.capture("/usr/bin/xcrun", ["clang", source.path, "-o", executable.path])
    for helper in SigningTool.nativeHelpers {
      try ToolFiles.manager.copyItem(
        at: executable, to: contents.appendingPathComponent("Resources/" + helper))
    }
    let framework = contents.appendingPathComponent("Frameworks/Fixture.framework")
    let versionRoot = framework.appendingPathComponent("Versions/A")
    try ToolFiles.directory(versionRoot.appendingPathComponent("Resources"))
    let dylib = root.appendingPathComponent("framework\(version).c")
    try ToolFiles.write("int fixture_value(void) { return \(version); }\n", to: dylib)
    _ = try Command.capture(
      "/usr/bin/xcrun",
      [
        "clang", "-dynamiclib", dylib.path, "-o",
        versionRoot.appendingPathComponent("Fixture").path,
      ])
    try info(
      "Fixture", appID + ".framework", "FMWK",
      versionRoot.appendingPathComponent("Resources/Info.plist"))
    for (name, target) in [
      ("Versions/Current", "A"), ("Fixture", "Versions/Current/Fixture"),
      ("Resources", "Versions/Current/Resources"),
    ] {
      try ToolFiles.manager.createSymbolicLink(
        atPath: framework.appendingPathComponent(name).path, withDestinationPath: target)
    }
    let xpc = versionRoot.appendingPathComponent("XPCServices/Fixture.xpc/Contents")
    try ToolFiles.directory(xpc.appendingPathComponent("MacOS"))
    try ToolFiles.manager.copyItem(at: executable, to: xpc.appendingPathComponent("MacOS/Fixture"))
    try info("Fixture", appID + ".xpc", "XPC!", xpc.appendingPathComponent("Info.plist"))
    return bundle
  }
  func testDisposableSigningRetainsRequirementsAndRejectsNestedTamper() throws {
    let root = try temporary()
    defer { try? ToolFiles.remove(root) }
    let before = try Command.capture("/usr/bin/security", ["list-keychains", "-d", "user"])
    let certificate = root.appendingPathComponent("certificate")
    let fingerprint = try SigningTool.createCertificate(directory: certificate)
    XCTAssertThrowsError(try SigningTool.createCertificate(directory: certificate))
    var environment = ProcessInfo.processInfo.environment
    environment["POLKA_SIGNING_CERT_SHA1"] = fingerprint
    environment["POLKA_SIGNING_P12"] = try Data(
      contentsOf: certificate.appendingPathComponent("identity.p12")
    ).base64EncodedString()
    environment["POLKA_SIGNING_PASSWORD"] = try String(
      contentsOf: certificate.appendingPathComponent("password.txt"), encoding: .utf8)
    environment["SPARKLE_PRIVATE_KEY"] = "must-not-reach-build-children"
    let appID = "app.polka.tools-signing-test"
    let first = try fixture(root: root, version: 1, appID: appID)
    let second = try fixture(root: root, version: 2, appID: appID)
    let targets = try SigningTool.targets(bundle: first)
    XCTAssertEqual(targets.last, first)
    let framework = first.appendingPathComponent("Contents/Frameworks/Fixture.framework")
    let xpc = framework.appendingPathComponent("Versions/A/XPCServices/Fixture.xpc")
    let targetPaths = targets.map(\.path)
    XCTAssertLessThan(
      try XCTUnwrap(targetPaths.firstIndex(of: xpc.path), "Targets: \(targetPaths)"),
      try XCTUnwrap(targetPaths.firstIndex(of: framework.path), "Targets: \(targetPaths)"))
    XCTAssertFalse(targets.contains(framework.appendingPathComponent("Fixture")))
    var keychain: URL?
    try SigningTool.withKeychain(environment) { buildEnvironment in
      XCTAssertNil(buildEnvironment["SPARKLE_PRIVATE_KEY"])
      XCTAssertNil(buildEnvironment["POLKA_SIGNING_P12"])
      XCTAssertNil(buildEnvironment["POLKA_SIGNING_PASSWORD"])
      keychain = URL(fileURLWithPath: try XCTUnwrap(buildEnvironment["POLKA_SIGNING_KEYCHAIN"]))
      try SigningTool.sign(bundle: first, appId: appID, environment: buildEnvironment)
      try SigningTool.sign(bundle: second, appId: appID, environment: buildEnvironment)
    }
    XCTAssertFalse(ToolFiles.manager.fileExists(atPath: try XCTUnwrap(keychain).path))
    let old = try SigningTool.verify(bundle: first, appId: appID, fingerprint: fingerprint)
    XCTAssertEqual(
      old, try SigningTool.verify(bundle: second, appId: appID, fingerprint: fingerprint))
    XCTAssertNotEqual(
      try Data(contentsOf: first.appendingPathComponent("Contents/MacOS/Main")),
      try Data(contentsOf: second.appendingPathComponent("Contents/MacOS/Main")))
    XCTAssertThrowsError(
      try SigningTool.verify(
        bundle: second, appId: appID, fingerprint: String(repeating: "0", count: 40)))
    _ = try SigningTool.codesign(["--force", "--sign", "-", xpc.path])
    XCTAssertThrowsError(
      try SigningTool.verify(bundle: first, appId: appID, fingerprint: fingerprint))
    XCTAssertEqual(
      before, try Command.capture("/usr/bin/security", ["list-keychains", "-d", "user"]))
  }
}
