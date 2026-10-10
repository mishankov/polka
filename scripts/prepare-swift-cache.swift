import CryptoKit
import Darwin
import Foundation

// Run before SwiftPM (including the tooling bootstrap), after restoring .build.
// Fresh checkouts otherwise make unchanged source look newer than cached objects.
struct CacheInput: Codable {
  let digest: String
  let seconds: Int
  let nanoseconds: Int
}

func prepareCache(_ package: URL) throws {
  let manager = FileManager.default
  let manifest = package.appendingPathComponent(".build/polka-inputs-v1.json")
  let previous =
    (try? Data(contentsOf: manifest)).flatMap {
      try? JSONDecoder().decode([String: CacheInput].self, from: $0)
    } ?? [:]
  var inputs: [URL] = ["Package.swift", "Package.resolved"].map {
    package.appendingPathComponent($0)
  }
  for directory in ["Sources", "Tests"] {
    if let enumerator = manager.enumerator(
      at: package.appendingPathComponent(directory), includingPropertiesForKeys: nil)
    {
      for case let path as URL in enumerator { inputs.append(path) }
    }
  }
  var current: [String: CacheInput] = [:]
  var restored = 0
  for path in inputs {
    var info = stat()
    // Only files discovered in this checkout are eligible; never follow links
    // or use a path from the restored manifest to choose a write destination.
    guard lstat(path.path, &info) == 0, info.st_mode & 0o170000 == 0o100000 else { continue }
    let base = package.standardizedFileURL.path + "/"
    let normalized = path.standardizedFileURL.path
    guard normalized.hasPrefix(base) else { continue }
    let relative = String(normalized.dropFirst(base.count))
    let digest = SHA256.hash(data: try Data(contentsOf: path)).map {
      String(format: "%02x", $0)
    }.joined()
    if let cached = previous[relative], cached.digest == digest,
      cached.seconds >= 0, (0..<1_000_000_000).contains(cached.nanoseconds)
    {
      let modified = timespec(tv_sec: cached.seconds, tv_nsec: cached.nanoseconds)
      guard utimensat(AT_FDCWD, path.path, [info.st_atimespec, modified], AT_SYMLINK_NOFOLLOW) == 0
      else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      info.st_mtimespec = modified
      restored += 1
    }
    current[relative] = CacheInput(
      digest: digest, seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
  }
  try manager.createDirectory(
    at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
  try JSONEncoder().encode(current).write(to: manifest, options: .atomic)
  print(
    "Swift cache \(package.lastPathComponent): restored timestamps for \(restored)/\(current.count) identical inputs."
  )
}

guard CommandLine.arguments.count > 1 else {
  fputs("Usage: swift scripts/prepare-swift-cache.swift PACKAGE...\n", stderr)
  exit(1)
}
do {
  for path in CommandLine.arguments.dropFirst() {
    try prepareCache(URL(fileURLWithPath: path).standardizedFileURL)
  }
} catch {
  fputs("Swift cache preparation failed: \(error)\n", stderr)
  exit(1)
}
