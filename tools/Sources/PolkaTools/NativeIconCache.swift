import CryptoKit
import Foundation

/// Reuse identical actool output across build, packaging and updater processes.
final class NativeIconCache: @unchecked Sendable {
  static let shared = NativeIconCache()
  private let lock = NSLock()
  private var entries: [String: [String: Data]] = [:]
  private struct Entry: Codable {
    let key: String
    let files: [String: Data]
  }

  private static func complete(_ files: [String: Data]) -> Bool {
    Set(files.keys) == Set(["Assets.car", "Icon.icns"]) && files.values.allSatisfy { !$0.isEmpty }
  }

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

  func value(for key: String, directory: URL? = nil) -> [String: Data]? {
    lock.lock()
    defer { lock.unlock() }
    if let files = entries[key] { return files }
    guard let directory,
      let bytes = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")),
      let entry = try? JSONDecoder().decode(Entry.self, from: bytes),
      entry.key == key, Self.complete(entry.files)
    else { return nil }
    entries[key] = entry.files
    return entry.files
  }

  func store(_ files: [String: Data], for key: String, directory: URL? = nil) {
    lock.lock()
    defer { lock.unlock() }
    guard Self.complete(files) else { return }
    entries[key] = files
    // An unavailable cache must not fail a successful icon compilation. Publish
    // the complete pair atomically so concurrent processes never see half a hit.
    if let directory {
      do {
        try ToolFiles.directory(directory)
        try ToolFiles.write(
          JSONEncoder().encode(Entry(key: key, files: files)),
          to: directory.appendingPathComponent(key + ".json"))
      } catch { return }
    }
  }
}
