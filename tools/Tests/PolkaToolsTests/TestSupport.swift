import Foundation
import XCTest

@testable import PolkaTools

enum TestSupport {
  static var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }
  static var products: URL { Bundle(for: RuntimeTests.self).bundleURL.deletingLastPathComponent() }
  static var fixture: URL { products.appendingPathComponent("polka-tool-fixture") }
  static func write(_ value: String, to path: URL, executable: Bool = false) throws {
    try Files.mkdir(path.deletingLastPathComponent())
    try Data(value.utf8).write(to: path)
    if executable {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
  }
  static func children(_ path: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: path.path).sorted()
  }
}
