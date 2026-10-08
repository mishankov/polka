import Foundation
import XCTest

@testable import PolkaApp

final class InstalledAppsTests: XCTestCase {
  @MainActor func testCatalogRefreshDetectsInstallationRemovalAndMetadataChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = InstalledApps()
    func app(_ name: String, background: Bool = false) throws -> URL {
      let url = root.appendingPathComponent(name + ".app")
      try FileManager.default.createDirectory(
        at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      let info: [String: Any] = [
        "CFBundlePackageType": "APPL", "CFBundleExecutable": "Synthetic", "CFBundleName": name,
        "CFBundleIdentifier": "app.polka.fixture." + name, "LSBackgroundOnly": background,
      ]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
        to: url.appendingPathComponent("Contents/Info.plist"))
      let executable = url.appendingPathComponent("Contents/MacOS/Synthetic")
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
      return url
    }
    let first = try app("First")
    _ = try app("Background", background: true)
    try await catalog.refresh(roots: [root.path], extraPaths: [])
    XCTAssertEqual(catalog.apps.map(\.name), ["First"])
    XCTAssertEqual(catalog.apps[0].kind, .mac)
    let id = catalog.apps[0].id
    let second = try app("Second")
    try FileManager.default.removeItem(at: first)
    try await catalog.refresh(roots: [root.path], extraPaths: [])
    XCTAssertEqual(catalog.apps.map(\.name), ["Second"])
    XCTAssertNotEqual(catalog.apps[0].id, id)
    try FileManager.default.removeItem(
      at: second.appendingPathComponent("Contents/MacOS/Synthetic"))
    try await catalog.refresh(roots: [root.path], extraPaths: [])
    XCTAssertTrue(catalog.apps.isEmpty)
  }
  @MainActor func testLaunchValidationRejectsNestedExecutableAndReplacedSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Bad.app")
    try FileManager.default.createDirectory(
      at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleExecutable": "../outside"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
      to: bundle.appendingPathComponent("Contents/Info.plist"))
    XCTAssertThrowsError(try InstalledApps.validate(bundle.path))
    let alias = root.appendingPathComponent("Alias.app")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundle)
    XCTAssertThrowsError(try InstalledApps.validate(alias.path))
  }
}
