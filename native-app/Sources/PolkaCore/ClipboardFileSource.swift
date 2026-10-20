import CryptoKit
import Darwin
import Foundation

/// Portable metadata; neither source paths nor file contents travel with history.
public struct ClipboardFileSource: Codable, Equatable, Sendable {
  public struct Item: Codable, Equatable, Sendable {
    public var name: String
    public var size: Int
    public var version: String
    public init(name: String, size: Int, version: String) {
      self.name = name
      self.size = size
      self.version = version
    }
  }
  public static let maximumBytes = 32 * 1024 * 1024
  public var device: String
  public var items: [Item]
  public init(device: String, items: [Item]) throws {
    self.device = device
    self.items = items
    try validate()
  }
  public var names: String { items.map(\.name).joined(separator: ", ") }
  public var byteCount: Int { items.reduce(0) { $0 + $1.size } }
  public var key: String {
    clipId(
      .files,
      device
        + items.map {
          "\0\($0.name.utf8.count):\($0.name):\($0.size):\($0.version)"
        }.joined())
  }
  public func validate() throws {
    guard validDeviceID(device), !items.isEmpty, items.count <= 1000,
      items.allSatisfy({ item in
        !item.name.isEmpty && item.name.utf8.count <= 1024 && ![".", ".."].contains(item.name)
          && !item.name.contains("/") && !item.name.contains("\0")
          && item.size >= 0 && item.size <= Self.maximumBytes && validClipID(item.version)
      }), byteCount <= Self.maximumBytes
    else { throw PolkaCoreError.invalid(localized("Invalid file transfer metadata")) }
  }
  private static func item(_ url: URL, info: stat) throws -> Item {
    guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
      info.st_size <= maximumBytes
    else {
      throw PolkaCoreError.invalid(localized("Only regular files up to 32 MB can be transferred"))
    }
    let version =
      "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    return Item(
      name: url.lastPathComponent, size: Int(info.st_size), version: clipId(.files, version))
  }
  public static func inspect(_ files: ClipboardFiles, device: String) throws -> Self {
    let items = try files.urls.map { url -> Item in
      var info = stat()
      guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
      return try item(url, info: info)
    }
    return try Self(device: device, items: items)
  }
  /// Open only the recorded local files, and reject replaced or modified originals.
  public func read(_ files: ClipboardFiles) throws -> [Data] {
    try validate()
    guard files.urls.count == items.count else { throw CocoaError(.fileReadCorruptFile) }
    return try zip(files.urls, items).map { url, expected in
      let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, try Self.item(url, info: info) == expected else {
        throw PolkaCoreError.invalid(
          localized("The original file changed. Copy it again on the source Mac."))
      }
      var data = Data(count: expected.size)
      try data.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < expected.size {
          let count = Darwin.read(
            fd, buffer.baseAddress!.advanced(by: offset), expected.size - offset)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw CocoaError(.fileReadUnknown) }
          offset += count
        }
      }
      guard fstat(fd, &info) == 0, try Self.item(url, info: info) == expected else {
        throw PolkaCoreError.invalid(
          localized("The original file changed. Copy it again on the source Mac."))
      }
      return data
    }
  }
}

public struct ClipboardFileBundle: Codable, Equatable, Sendable {
  public var source: ClipboardFileSource
  public var contents: [Data]
  public var hashes: [String]
  public init(source: ClipboardFileSource, contents: [Data]) throws {
    self.source = source
    self.contents = contents
    hashes = contents.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    try validate()
  }
  public func validate() throws {
    try source.validate()
    guard contents.count == source.items.count, hashes.count == contents.count,
      zip(contents, source.items).allSatisfy({ $0.count == $1.size }),
      zip(contents, hashes).allSatisfy({ data, hash in
        validClipID(hash)
          && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash
      })
    else { throw PolkaCoreError.invalid(localized("Incomplete file transfer. Try again.")) }
  }
}
