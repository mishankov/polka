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
}
