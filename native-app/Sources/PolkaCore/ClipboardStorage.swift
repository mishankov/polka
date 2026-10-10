import Foundation

public struct ClipboardStorageState: Codable, Equatable {
  public enum Status: String, Codable { case starting, ready, failed }
  public struct Diagnostic: Codable, Equatable {
    public var stage: String
    public var code: String?
    public var message: String
  }
  public var status: Status
  public var path: String
  public var diagnostic: Diagnostic?
}
public final class ClipboardStorage {
  private var value: ClipboardStorageState
  private var reason: Error?
  private let lock = NSRecursiveLock()
  private let changed: () -> Void
  private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }
  public var failureReason: Error? { synchronized { reason } }
  public init(path: URL, changed: @escaping () -> Void = {}) {
    value = .init(status: .starting, path: path.path)
    self.changed = changed
  }
  public func state() -> ClipboardStorageState { synchronized { value } }
  public var ready: Bool { synchronized { value.status == .ready } }
  public func loaded() throws {
    try synchronized {
      try assertNotFailed()
      value.status = .ready
      changed()
    }
  }
  public func requireReady() throws {
    try synchronized { guard value.status == .ready else { throw unavailable() } }
  }
  public func assertNotFailed() throws {
    try synchronized { guard value.status != .failed else { throw unavailable() } }
  }
  public func unavailable() -> Error {
    synchronized {
      PolkaCoreError.storage(value.diagnostic?.message ?? localized("Storage is not ready yet"))
    }
  }
  public func run<T>(_ stage: String, _ operation: () throws -> T) throws -> T {
    try synchronized {
      try assertNotFailed()
      do { return try operation() } catch {
        reason = error
        let messages = [
          "read": localized("Could not read the file"),
          "decrypt": localized("Could not decrypt the file"),
          "parse": localized("Could not read the saved data format"),
          "encrypt": localized("Could not encrypt the data"),
          "write": localized("Could not save the file"),
        ]
        value.status = .failed
        let error = error as NSError
        let codes: [Int: String] = [
          1: "EPERM", 2: "ENOENT", 5: "EIO", 13: "EACCES", 21: "EISDIR", 24: "EMFILE", 28: "ENOSPC",
          30: "EROFS",
        ]
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix =
          error.domain == NSPOSIXErrorDomain
          ? error : underlying?.domain == NSPOSIXErrorDomain ? underlying : nil
        value.diagnostic = .init(
          stage: stage, code: posix.flatMap { codes[$0.code] },
          message: messages[stage] ?? localized("Storage error"))
        changed()
        throw unavailable()
      }
    }
  }
}
