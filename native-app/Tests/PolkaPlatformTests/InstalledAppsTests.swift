import Foundation
import PolkaCore
import XCTest

@testable import PolkaApp

final class InstalledAppsTests: XCTestCase {
  private func localizedApp(
    at root: URL, name: String, strings: [String: [String: Any]] = [:],
    table: [String: [String: Any]] = [:]
  ) throws -> URL {
    let url = root.appendingPathComponent(name + ".app")
    let resources = url.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundlePackageType": "APPL", "CFBundleExecutable": "Synthetic",
      "CFBundleName": name, "CFBundleDisplayName": name, "CFBundleDevelopmentRegion": "en",
      "CFBundleIdentifier": "app.polka.fixture." + UUID().uuidString,
    ]
    func write(_ values: Any, to path: URL) throws {
      try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        .write(to: path)
    }
    try write(info, to: url.appendingPathComponent("Contents/Info.plist"))
    let executable = url.appendingPathComponent("Contents/MacOS/Synthetic")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    for (language, values) in strings {
      let directory = resources.appendingPathComponent(language + ".lproj")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try write(values, to: directory.appendingPathComponent("InfoPlist.strings"))
    }
    if !table.isEmpty {
      try write(table, to: resources.appendingPathComponent("InfoPlist.loctable"))
    }
    return url
  }

  @MainActor func testCatalogUsesRussianNamesAndKeepsEnglishSearchAliases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    // Modern macOS apps can keep all translations in a loctable without .lproj directories.
    _ = try localizedApp(
      at: root, name: "Calculator",
      table: [
        "ru": ["CFBundleDisplayName": "Калькулятор"],
        "en": ["CFBundleDisplayName": "Calculator"],
        "LocProvenance": ["ru": 1],
      ])
    _ = try localizedApp(
      at: root, name: "Calendar",
      strings: [
        "ru": ["CFBundleDisplayName": "Календарь"],
        "en": ["CFBundleDisplayName": "Calendar"],
      ])
    let catalog = InstalledApps()
    try await catalog.refresh(
      roots: [root.path], extraPaths: [], preferredLanguages: ["ru-RU", "en"])
    XCTAssertEqual(Set(catalog.apps.map(\.name)), ["Календарь", "Калькулятор"])
    for (query, expected) in [
      ("Calendar", "Календарь"), ("Календарь", "Календарь"),
      ("Calculator", "Калькулятор"), ("Калькулятор", "Калькулятор"),
    ] {
      XCTAssertEqual(LauncherSearch.apps(catalog.apps, query: query).first?.name, expected)
    }
    try await catalog.refresh(
      roots: [root.path], extraPaths: [], preferredLanguages: ["en-US", "ru"])
    XCTAssertEqual(Set(catalog.apps.map(\.name)), ["Calendar", "Calculator"])
  }

  @MainActor func testDisplayNameMatchesRegionalLocalizationAndFallsBackFromBlankNames() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try localizedApp(
      at: root, name: "Calendar",
      table: [
        "pt_BR": ["CFBundleDisplayName": "Calendário brasileiro"],
        "pt_PT": ["CFBundleDisplayName": "Calendário português"],
        "ru": ["CFBundleDisplayName": " \n ", "CFBundleName": " Календарь "],
        "none": ["CFBundleDisplayName": "Unlocalized"],
      ])
    let info = try InstalledApps.validate(url.path)
    XCTAssertEqual(
      InstalledApps.displayName(at: url, info: info, preferredLanguages: ["pt-PT"]),
      "Calendário português")
    XCTAssertEqual(
      InstalledApps.displayName(at: url, info: info, preferredLanguages: ["ru-RU"]), "Календарь")
    XCTAssertEqual(
      InstalledApps.displayName(at: url, info: info, preferredLanguages: ["en-US"]), "Calendar")
  }

  @MainActor func testSystemCalendarAndCalculatorHaveRussianDisplayNames() throws {
    for (name, expected) in [("Calendar", "Календарь"), ("Calculator", "Калькулятор")] {
      let url = URL(fileURLWithPath: "/System/Applications/\(name).app")
      let info = try InstalledApps.validate(url.path)
      XCTAssertEqual(
        InstalledApps.displayName(at: url, info: info, preferredLanguages: ["ru-RU", "en"]),
        expected)
    }
  }

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
