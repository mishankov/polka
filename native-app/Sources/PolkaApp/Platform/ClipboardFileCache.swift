import Foundation
import PolkaCore

/// Encrypted downloads survive restart; only an explicit paste materializes files.
final class NativeClipboardFileCache: @unchecked Sendable {
  static let maximumBytes = 128 * 1024 * 1024
  let root: URL
  let exports: URL
  private let codec: EncryptionCodec
  private let capacity: Int
  private let lock = NSRecursiveLock()
  init(root: URL, codec: EncryptionCodec, capacity: Int = NativeClipboardFileCache.maximumBytes) {
    self.root = root
    self.codec = codec
    self.capacity = capacity
    exports = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-clipboard-files-" + clipId(.files, root.path), isDirectory: true)
  }
  private func encrypted(_ source: ClipboardFileSource) -> URL {
    root.appendingPathComponent(source.key + ".enc")
  }
  func contains(_ source: ClipboardFileSource) -> Bool {
    // UI projection must never wait for a download's decrypt/write lock.
    return FileManager.default.fileExists(atPath: encrypted(source).path)
  }
  func load(_ source: ClipboardFileSource) throws -> ClipboardFileBundle? {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try readEncryptedFile(encrypted(source), maximumBytes: 48 * 1024 * 1024) else {
      return nil
    }
    let bundle = try decodeClipboardJSON(ClipboardFileBundle.self, from: codec.decode(data))
    try bundle.validate()
    guard bundle.source == source else { throw CocoaError(.fileReadCorruptFile) }
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: encrypted(source).path)
    return bundle
  }
  func save(_ bundle: ClipboardFileBundle) throws {
    lock.lock()
    defer { lock.unlock() }
    try bundle.validate()
    let data = try codec.encode(JSONEncoder().encode(bundle))
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let target = encrypted(bundle.source)
    try data.write(to: target, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    // Bound disk use independently from the metadata-only history limit.
    let existing = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
    )
    .filter { $0.pathExtension == "enc" }
    .sorted {
      (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
        < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
    }
    var size = existing.reduce(0) {
      $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    for url in existing where size > capacity && url != target {
      let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      try FileManager.default.removeItem(at: url)
      size -= bytes
    }
  }
  func discard(_ source: ClipboardFileSource) {
    lock.lock()
    defer { lock.unlock() }
    try? FileManager.default.removeItem(at: encrypted(source))
  }
  func prune(keeping sources: [ClipboardFileSource]) {
    lock.lock()
    defer { lock.unlock() }
    let keep = Set(sources.map { $0.key + ".enc" })
    for url
      in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      ?? []
    where url.pathExtension == "enc" && !keep.contains(url.lastPathComponent) {
      try? FileManager.default.removeItem(at: url)
    }
  }
  func pruneExports(protecting urls: [URL]) {
    lock.lock()
    defer { lock.unlock() }
    // Keep files still referenced by the current clipboard. Other plaintext
    // exports can be recreated from encrypted data, including after restart.
    let protectedPaths = urls.map {
      $0.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
    }
    for directory
      in (try? FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil))
      ?? []
    {
      let prefix =
        directory.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping + "/"
      if !protectedPaths.contains(where: { $0.hasPrefix(prefix) }) {
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }
  func materialize(_ bundle: ClipboardFileBundle) throws -> ClipboardFiles {
    lock.lock()
    defer { lock.unlock() }
    try bundle.validate()
    try Task.checkCancellation()
    try FileManager.default.createDirectory(
      at: exports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directory = exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      var result: [URL] = []
      for (index, item) in bundle.source.items.enumerated() {
        try Task.checkCancellation()
        // Separate directories preserve duplicate names and case distinctions.
        let parent = directory.appendingPathComponent(String(index), isDirectory: true)
        try FileManager.default.createDirectory(
          at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = parent.appendingPathComponent(item.name)
        try bundle.contents[index].write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        result.append(file)
      }
      return try ClipboardFiles(urls: result)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}
