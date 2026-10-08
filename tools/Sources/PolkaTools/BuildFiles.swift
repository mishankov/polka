import CryptoKit
import Darwin
import Foundation

/// Filesystem primitives shared by build/signing operations; never shell strings.
enum ToolFiles {
  static let manager = FileManager.default
  static func error(_ message: String) -> NSError {
    NSError(domain: "PolkaTools", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  static func directory(_ url: URL, mode: Int = 0o700) throws {
    try manager.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: mode])
  }
  static func temporary(_ prefix: String, parent: URL? = nil) throws -> URL {
    // realpath preserves the physical /private/var path; Foundation may shorten
    // this system alias back to /var even after resolvingSymlinksInPath().
    guard let physical = realpath((parent ?? manager.temporaryDirectory).path, nil) else {
      throw posixError()
    }
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    let url = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    guard mkdir(url.path, 0o700) == 0 else { throw posixError() }
    return url
  }
  static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  static func remove(_ url: URL) throws {
    if try metadata(url) != nil { try manager.removeItem(at: url) }
  }
  static func write(_ data: Data, to url: URL, mode: Int = 0o600) throws {
    try data.write(to: url, options: .atomic)
    guard chmod(url.path, mode_t(mode)) == 0 else { throw posixError() }
  }
  static func write(_ text: String, to url: URL, mode: Int = 0o600) throws {
    try write(Data(text.utf8), to: url, mode: mode)
  }
  static func metadata(_ url: URL) throws -> stat? {
    var info = stat()
    if lstat(url.path, &info) == 0 { return info }
    if errno == ENOENT { return nil }
    throw posixError()
  }
  static func regular(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG }
  static func privateDirectory(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700
  }
  static func noSymlinks(_ url: URL) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    // Foundation's standardizedFileURL shortens /private/var to /var on macOS.
    // Inspect the supplied components instead, preserving canonical temp paths.
    for component in url.pathComponents.dropFirst() {
      current.appendPathComponent(component)
      if let info = try metadata(current), info.st_mode & S_IFMT == S_IFLNK {
        throw error("Development cache paths cannot contain symlinks: \(current.path).")
      }
    }
  }
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func random(_ count: Int = 32) -> Data {
    var random = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &random) })
  }
  static func jsonString(_ value: String) -> String {
    let data = try! JSONSerialization.data(
      withJSONObject: [value], options: [.withoutEscapingSlashes])
    return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
  }
  static func xml(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  static func relative(_ child: URL, to root: URL) -> String {
    let base = root.standardizedFileURL.path
    let path = child.standardizedFileURL.path
    return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
  }
  static func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }
}
