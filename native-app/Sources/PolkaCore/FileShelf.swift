import Darwin
import Foundation

public struct ShelfFile: Identifiable, Equatable {
  public let id: String
  public let name: String
  public let path: String
  public let directory: Bool
  public var available: Bool
  fileprivate let identity: String
}

/// Session-only references. Removing a reference never alters the original.
public final class FileShelf {
  public static let maximum = 200
  public private(set) var items: [ShelfFile] = []
  public private(set) var error = ""
  public init() {}
  private func identity(_ path: String) throws -> (String, Bool) {
    var info = stat()
    guard fstatat(AT_FDCWD, path, &info, 0) == 0, Darwin.access(path, R_OK) == 0 else {
      throw CocoaError(.fileReadNoPermission)
    }
    let type = info.st_mode & S_IFMT
    guard type == S_IFREG || type == S_IFDIR else { throw CocoaError(.fileReadUnsupportedScheme) }
    return ("\(info.st_dev):\(info.st_ino)", type == S_IFDIR)
  }
  public func add(_ paths: [String]) throws {
    error = ""
    for input in paths {
      guard input.hasPrefix("/"), !input.contains("\0") else {
        throw NSError(
          domain: "Polka", code: 1,
          userInfo: [NSLocalizedDescriptionKey: localized("A local file is required")])
      }
      let path = URL(fileURLWithPath: input).standardizedFileURL.path
      if items.contains(where: { $0.path == path }) { continue }
      guard items.count < Self.maximum else {
        error = localized("The shelf can hold up to 200 files. Remove some and try again.")
        break
      }
      do {
        let (identity, directory) = try identity(path)
        items.append(
          ShelfFile(
            id: UUID().uuidString, name: URL(fileURLWithPath: path).lastPathComponent, path: path,
            directory: directory, available: true, identity: identity))
      } catch {
        self.error = localized("Some files are unavailable. Check access and drag them again.")
      }
    }
  }
  public func refresh() {
    for index in items.indices {
      items[index].available = (try? identity(items[index].path).0) == items[index].identity
    }
  }
  public func remove(_ ids: [String]) {
    items.removeAll { ids.contains($0.id) }
    error = ""
  }
  public func clear() {
    items.removeAll()
    error = ""
  }
  public func drag(_ ids: [String]) throws -> [URL] {
    let unique = Array(Set(ids))
    guard !unique.isEmpty, unique.allSatisfy({ id in items.contains { $0.id == id } }) else {
      throw NSError(
        domain: "Polka", code: 2,
        userInfo: [NSLocalizedDescriptionKey: localized("Select files on the shelf")])
    }
    refresh()
    guard unique.allSatisfy({ id in items.first { $0.id == id }?.available == true }) else {
      error = localized(
        "The file was moved, deleted, or is unavailable. Remove the link and add the file again.")
      throw NSError(domain: "Polka", code: 3, userInfo: [NSLocalizedDescriptionKey: error])
    }
    return items.filter { unique.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
  }
}
