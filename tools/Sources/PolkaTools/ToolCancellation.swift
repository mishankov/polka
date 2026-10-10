import Foundation

/// Synchronous packaging can be waiting for a detached desktop runner when the
/// CLI task is cancelled. Signal handlers call this registry off the main queue.
public final class ToolCancellationRegistry: @unchecked Sendable {
  public static let shared = ToolCancellationRegistry()
  private let mutex = NSLock()
  private var cancelled = false
  private var handlers: [UUID: () -> Void] = [:]
  public init() {}
  public var isCancelled: Bool {
    mutex.lock()
    defer { mutex.unlock() }
    return cancelled
  }
  @discardableResult public func register(_ handler: @escaping () -> Void) -> UUID {
    let token = UUID()
    mutex.lock()
    if cancelled {
      mutex.unlock()
      handler()
    } else {
      handlers[token] = handler
      mutex.unlock()
    }
    return token
  }
  public func unregister(_ token: UUID) {
    mutex.lock()
    handlers.removeValue(forKey: token)
    mutex.unlock()
  }
  public func cancel() {
    mutex.lock()
    guard !cancelled else {
      mutex.unlock()
      return
    }
    cancelled = true
    let callbacks = Array(handlers.values)
    handlers.removeAll()
    mutex.unlock()
    for callback in callbacks { callback() }
  }
}
