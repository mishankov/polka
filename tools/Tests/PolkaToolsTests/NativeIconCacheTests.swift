import Foundation
import XCTest

@testable import PolkaTools

final class NativeIconCacheTests: XCTestCase {
  func testInputsDeploymentAndToolchainInvalidateReuse() throws {
    let root = try Files.temporary("polka-icon-cache-tests")
    defer { try? FileManager.default.removeItem(at: root) }
    let asset = root.appendingPathComponent("art.svg")
    try Data("original icon".utf8).write(to: asset)
    func key(_ target: String = "27.0", _ toolchain: String = "xcode-27") throws -> String {
      try NativeIconCache.key(source: root, minimumSystemVersion: target, toolchain: toolchain)
    }
    let original = try key()
    XCTAssertEqual(try key(), original)
    let copied = try Files.temporary("polka-icon-copy-tests")
    defer { try? FileManager.default.removeItem(at: copied) }
    let snapshot = copied.appendingPathComponent("Icon.icon")
    try FileManager.default.copyItem(at: root, to: snapshot)
    XCTAssertEqual(
      try NativeIconCache.key(
        source: snapshot, minimumSystemVersion: "27.0", toolchain: "xcode-27"), original)
    XCTAssertNotEqual(try key("28.0"), original)
    XCTAssertNotEqual(try key("27.0", "xcode-28"), original)
    try Data("modified icon".utf8).write(to: asset)
    XCTAssertNotEqual(try key(), original)
    try Data("original icon".utf8).write(to: asset)
    try FileManager.default.moveItem(at: asset, to: root.appendingPathComponent("renamed.svg"))
    XCTAssertNotEqual(try key(), original)
  }

  func testCachedOutputsAreIsolatedByKeyAndProcessLifetime() {
    let cache = NativeIconCache()
    let outputs = ["Assets.car": Data([1, 2, 3]), "Icon.icns": Data([4, 5, 6])]
    XCTAssertNil(cache.value(for: "icon"))
    cache.store(outputs, for: "icon")
    XCTAssertEqual(cache.value(for: "icon"), outputs)
    XCTAssertNil(cache.value(for: "changed-icon"))
    XCTAssertNil(NativeIconCache().value(for: "icon"))
  }

  func testDiskCacheReusesCompleteOutputsAcrossInstancesAndKeepsKeysSeparate() throws {
    let directory = try Files.temporary("polka-icon-disk-cache-tests")
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputs = ["Assets.car": Data([1, 2, 3]), "Icon.icns": Data([4, 5, 6])]
    NativeIconCache().store(outputs, for: "icon", directory: directory)
    XCTAssertEqual(NativeIconCache().value(for: "icon", directory: directory), outputs)
    XCTAssertNil(NativeIconCache().value(for: "changed-icon", directory: directory))
    try FileManager.default.copyItem(
      at: directory.appendingPathComponent("icon.json"),
      to: directory.appendingPathComponent("changed-icon.json"))
    XCTAssertNil(NativeIconCache().value(for: "changed-icon", directory: directory))
  }

  func testInvalidDiskEntriesAreMissesAndCanBeReplaced() throws {
    let directory = try Files.temporary("polka-icon-invalid-cache-tests")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("icon.json")
    let outputs = ["Assets.car": Data([1, 2, 3]), "Icon.icns": Data([4, 5, 6])]
    for invalid in [
      Data("{truncated".utf8),
      try JSONSerialization.data(withJSONObject: ["key": "icon", "files": [:]]),
      try JSONSerialization.data(withJSONObject: [
        "key": "icon", "files": ["Assets.car": Data([1]).base64EncodedString()],
      ]),
      try JSONSerialization.data(withJSONObject: [
        "key": "icon", "files": ["Assets.car": "", "Icon.icns": ""],
      ]),
    ] {
      try invalid.write(to: file)
      XCTAssertNil(NativeIconCache().value(for: "icon", directory: directory))
      NativeIconCache().store(outputs, for: "icon", directory: directory)
      XCTAssertEqual(NativeIconCache().value(for: "icon", directory: directory), outputs)
    }
  }

  func testUnavailableDiskCacheDoesNotDiscardCompiledOutputs() throws {
    let directory = try Files.temporary("polka-icon-unavailable-cache-tests")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file")
    try Data([1]).write(to: file)
    let cache = NativeIconCache()
    let outputs = ["Assets.car": Data([1]), "Icon.icns": Data([2])]
    cache.store(outputs, for: "icon", directory: file)
    XCTAssertEqual(cache.value(for: "icon"), outputs)
    XCTAssertNil(NativeIconCache().value(for: "icon", directory: file))
    cache.store(["Assets.car": Data([1])], for: "incomplete", directory: directory)
    XCTAssertNil(cache.value(for: "incomplete", directory: directory))
  }
}
