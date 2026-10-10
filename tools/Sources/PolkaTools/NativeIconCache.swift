import CryptoKit
import Foundation

/// Reuse identical actool output while building several signed fixture bundles.
/// This cache lasts only for the current tool process; every run compiles its first icon.
final class NativeIconCache: @unchecked Sendable {
  static let shared = NativeIconCache()
  private let lock = NSLock()
  private var entries: [String: [String: Data]] = [:]

  static func key(source: URL, minimumSystemVersion: String, toolchain: String) throws -> String {
    var digest = SHA256()
    let options = [minimumSystemVersion, toolchain]
    digest.update(data: try JSONEncoder().encode(options))
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(atPath: source.path)
    else { throw ToolError("Cannot read native icon inputs: \(source.path)") }
    let names = try enumerator.allObjects.compactMap { $0 as? String }.filter {
      try source.appendingPathComponent($0).resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        != true
    }.sorted()
    for name in names {
      let bytes = try Data(contentsOf: source.appendingPathComponent(name))
      // Lengths and relative paths prevent ambiguous concatenations and include renames.
      digest.update(data: try JSONEncoder().encode([name, String(bytes.count)]))
      digest.update(data: bytes)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func value(for key: String) -> [String: Data]? {
    lock.lock()
    defer { lock.unlock() }
    return entries[key]
  }

  func store(_ files: [String: Data], for key: String) {
    lock.lock()
    defer { lock.unlock() }
    entries[key] = files
  }
}
