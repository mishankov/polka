import Foundation
import PolkaCore
import XCTest

@testable import PolkaApp

final class ClipboardFileCacheTests: XCTestCase {
  func testEncryptedCacheQuotaIntegrityPruningAndProtectedClipboardExports() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let codec = SyntheticEncryptionCodec(key: Data(repeating: 3, count: 32))
    let device = UUID().uuidString.lowercased()
    let bundles = try (0..<3).map { index in
      try ClipboardFileBundle(
        source: ClipboardFileSource(
          device: device,
          items: [
            .init(name: "File\(index).pdf", size: 100, version: clipId(.files, String(index)))
          ]), contents: [Data(repeating: UInt8(index), count: 100)])
    }
    let capacity = try codec.encode(JSONEncoder().encode(bundles[0])).count * 2
    let cache = NativeClipboardFileCache(root: root, codec: codec, capacity: capacity)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: cache.exports)
    }
    for bundle in bundles { try cache.save(bundle) }
    XCTAssertTrue(cache.contains(bundles[2].source))
    let saved = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.fileSizeKey])
    XCTAssertLessThanOrEqual(saved.count, 2)
    XCTAssertLessThanOrEqual(
      try saved.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) },
      capacity)
    XCTAssertEqual(try cache.load(bundles[2].source), bundles[2])
    let first = try cache.materialize(bundles[2])
    let second = try cache.materialize(bundles[2])
    cache.pruneExports(protecting: first.urls)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.urls[0].path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.urls[0].path))
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: first.urls[0].path)[.posixPermissions]
        as? NSNumber)?.intValue, 0o600)
    let target = root.appendingPathComponent(bundles[2].source.key + ".enc")
    try Data("corrupted cache".utf8).write(to: target)
    XCTAssertThrowsError(try cache.load(bundles[2].source))
    cache.discard(bundles[2].source)
    XCTAssertFalse(cache.contains(bundles[2].source))
    cache.prune(keeping: [])
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty
    )
  }
}
