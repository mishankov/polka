import Foundation
import XCTest

@testable import PolkaTools

final class BuildCacheTests: XCTestCase {
  func testFreshCheckoutRestoresOnlyContentIdenticalInputs() throws {
    let root = try Files.temporary("polka-cache-test")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("package")
    let unchanged = package.appendingPathComponent("Sources/Library/Unchanged.swift")
    let changed = package.appendingPathComponent("Sources/Library/Changed.swift")
    let removed = package.appendingPathComponent("Tests/LibraryTests/Removed.swift")
    let resource = package.appendingPathComponent("Sources/Library/data.json")
    let outside = root.appendingPathComponent("outside.swift")
    for path in [unchanged, changed, removed, resource, outside] {
      try TestSupport.write("original", to: path)
    }
    let past = Date(timeIntervalSince1970: 1_600_000_000.125)
    let checkout = past.addingTimeInterval(100)
    for path in [unchanged, changed, removed, resource] {
      try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path.path)
    }
    try FileManager.default.createSymbolicLink(
      atPath: package.appendingPathComponent("Sources/Library/Link.swift").path,
      withDestinationPath: outside.path)
    func prepare() throws {
      try Command.run(
        "swift",
        [
          TestSupport.root.appendingPathComponent("scripts/prepare-swift-cache.swift").path,
          package.path,
        ])
    }
    func modified(_ path: URL) throws -> Date {
      try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date)
    }
    let outsideTime = try modified(outside)
    try prepare()
    try TestSupport.write("modified", to: changed)  // Same size, different content.
    try FileManager.default.removeItem(at: removed)
    let added = package.appendingPathComponent("Sources/Library/Added.swift")
    try TestSupport.write("new source", to: added)
    for path in [unchanged, changed, resource, added] {
      try FileManager.default.setAttributes([.modificationDate: checkout], ofItemAtPath: path.path)
    }
    try prepare()
    for path in [unchanged, resource] {
      XCTAssertEqual(
        try modified(path).timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 0.000001)
    }
    for path in [changed, added] {
      XCTAssertEqual(try modified(path), checkout)
    }
    XCTAssertEqual(try modified(outside), outsideTime)
    let snapshot = try XCTUnwrap(
      try Files.json(package.appendingPathComponent(".build/polka-inputs-v1.json"))
        as? [String: Any])
    XCTAssertNil(snapshot["Tests/LibraryTests/Removed.swift"])
    XCTAssertNil(snapshot["Sources/Library/Link.swift"])
    XCTAssertNotNil(snapshot["Sources/Library/Added.swift"])
  }
}
