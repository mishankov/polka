import Darwin
import Foundation

/// A pipe read returns the currently available bytes. Foundation's read(upToCount:)
/// can wait to fill the requested count, which would delay short interactive replies.
private func readPipe(_ handle: FileHandle, bytes: (Data) -> Void) {
  var buffer = [UInt8](repeating: 0, count: 16 * 1024)
  while true {
    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
    if count > 0 {
      bytes(Data(buffer.prefix(count)))
    } else if count < 0 && errno == EINTR {
      continue
    } else {
      return
    }
  }
}

/// macOS descriptor-local suppression prevents a helper that closes stdin from
/// sending SIGPIPE to Polka, without changing the application's signal handling.
private func writePipe(_ handle: FileHandle, data: Data) throws {
  let descriptor = handle.fileDescriptor
  guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  try data.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(
        descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      if count > 0 {
        offset += count
      } else if count < 0 && errno == EINTR {
        continue
      } else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(count == 0 ? EPIPE : errno))
      }
    }
  }
}

private func terminateAndReap(_ child: Process) {
  guard child.isRunning else { return }
  child.terminate()
  DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
    if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
  }
  child.waitUntilExit()
}

/// A single helper generation. Blocking readers have exclusive ownership of their pipe;
/// the exit callback follows all complete stdout records, including the final reply.
private final class HelperSession {
  let child: Process
  let input: FileHandle
  let output: FileHandle
  let errors: FileHandle
  private let readers = DispatchGroup()
  init(child: Process, input: FileHandle, output: FileHandle, errors: FileHandle) {
    self.child = child
    self.input = input
    self.output = output
    self.errors = errors
  }
  func read(bytes: @escaping (Data) -> Void, exited: @escaping (Int32) -> Void) {
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      defer {
        try? self.output.close()
        self.readers.leave()
      }
      readPipe(self.output, bytes: bytes)
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      defer {
        try? self.errors.close()
        self.readers.leave()
      }
      readPipe(self.errors) { _ in }
    }
    DispatchQueue.global(qos: .utility).async {
      self.child.waitUntilExit()
      self.readers.wait()
      exited(self.child.terminationStatus)
    }
  }
  func stop() {
    try? input.close()
    terminateAndReap(child)
  }
}

/// Owns a trusted Swift helper. Callbacks are delivered on the application's main queue.
@MainActor final class HelperProcess {
  private var session: HelperSession?
  private var buffer = Data()
  private var requestID = 0
  private var pending: [String: CheckedContinuation<[String: Any], Never>] = [:]
  private var stopped = false
  private var generation = 0
  var onMessage: (([String: Any]) -> Void)?
  var onExit: ((Int32) -> Void)?
  var running: Bool { session?.child.isRunning == true }
  func start(_ url: URL, arguments: [String] = []) throws {
    stop()
    stopped = false
    generation += 1
    let epoch = generation
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    child.executableURL = url
    child.arguments = arguments
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = stderr
    do { try child.run() } catch {
      try? stdin.fileHandleForWriting.close()
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
      stopped = true
      throw error
    }
    let session = HelperSession(
      child: child, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading,
      errors: stderr.fileHandleForReading)
    self.session = session
    session.read(
      bytes: { [weak self] data in
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == epoch, !self.stopped else { return }
          self.accept(data)
        }
      },
      exited: { [weak self] status in
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == epoch, !self.stopped else { return }
          self.completeRequests()
          try? self.session?.input.close()
          self.session = nil
          self.onExit?(status)
        }
      })
  }
  private func accept(_ data: Data) {
    buffer.append(data)
    while let end = buffer.firstIndex(of: 10) {
      guard end < 4 * 1024 * 1024 else {
        stop()
        onExit?(-1)
        return
      }
      let line = buffer.prefix(upTo: end)
      buffer.removeSubrange(...end)
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      if object["type"] as? String == "paste.reply", let id = object["id"] as? String {
        pending.removeValue(forKey: id)?.resume(
          returning: object["result"] as? [String: Any] ?? [:])
      }
      onMessage?(object)
    }
    if buffer.count >= 4 * 1024 * 1024 {
      stop()
      onExit?(-1)
    }
  }
  func write(_ value: [String: Any]) -> Bool {
    guard running, let session, var data = try? JSONSerialization.data(withJSONObject: value),
      data.count < 4096
    else { return false }
    data.append(10)
    do {
      try writePipe(session.input, data: data)
      return true
    } catch { return false }
  }
  func request(_ method: String, fields: [String: Any] = [:]) async -> [String: Any] {
    requestID += 1
    let id = String(requestID)
    return await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { continuation in
          guard !Task.isCancelled else {
            continuation.resume(returning: [:])
            return
          }
          pending[id] = continuation
          var value = fields
          value["id"] = id
          value["method"] = method
          value["expiresAt"] = Date().timeIntervalSince1970 * 1000 + 1500
          if !write(value) {
            pending.removeValue(forKey: id)?.resume(returning: [:])
            return
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.pending.removeValue(forKey: id)?.resume(returning: [:])
          }
        }
      },
      onCancel: { [weak self] in
        Task { @MainActor in
          guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
          if !["status", "requestAccess", "cancel"].contains(method) {
            self.requestID += 1
            _ = self.write(["id": String(self.requestID), "method": "cancel"])
          }
          continuation.resume(returning: [:])
        }
      })
  }
  private func completeRequests() {
    let requests = pending
    pending.removeAll()
    for continuation in requests.values { continuation.resume(returning: [:]) }
  }
  func stop() {
    stopped = true
    generation += 1
    let previous = session
    session = nil
    buffer.removeAll()
    completeRequests()
    // Reap before a restart so two helpers cannot monitor or paste at the same time.
    previous?.stop()
  }
}

private final class CommandOperation: @unchecked Sendable {
  let url: URL
  let arguments: [String]
  let stdin: Data?
  let timeout: TimeInterval
  let limit: Int
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, Error>?
  private var child: Process?
  private var cancelled = false
  private var timedOut = false
  private var overflow = false
  private var finished = false
  private var result = Data()
  init(url: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, limit: Int) {
    self.url = url
    self.arguments = arguments
    self.stdin = stdin
    self.timeout = timeout
    self.limit = limit
  }
  private func synchronized<T>(_ block: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try block()
  }
  func start(_ continuation: CheckedContinuation<Data, Error>) {
    let begin = synchronized { () -> Bool in
      self.continuation = continuation
      return !cancelled
    }
    guard begin else {
      finish(.failure(CancellationError()))
      return
    }
    DispatchQueue.global(qos: .utility).async { self.execute() }
  }
  func cancel() {
    let child = synchronized {
      cancelled = true
      return self.child
    }
    terminate(child)
  }
  private func terminate(_ child: Process?) {
    guard let child, child.isRunning else { return }
    child.terminate()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
      if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
    }
  }
  private func finish(_ value: Result<Data, Error>) {
    let continuation = synchronized { () -> CheckedContinuation<Data, Error>? in
      guard !finished else { return nil }
      finished = true
      let c = self.continuation
      self.continuation = nil
      return c
    }
    continuation?.resume(with: value)
  }
  private func execute() {
    let child = Process()
    let output = Pipe()
    let errors = Pipe()
    let input = Pipe()
    child.executableURL = url
    child.arguments = arguments
    child.standardOutput = output
    child.standardError = errors
    child.standardInput = stdin == nil ? FileHandle.nullDevice : input
    do {
      let launched = try synchronized { () throws -> Bool in
        guard !cancelled else { return false }
        try child.run()
        self.child = child
        return true
      }
      guard launched else {
        finish(.failure(CancellationError()))
        return
      }
      let readers = DispatchGroup()
      readers.enter()
      DispatchQueue.global(qos: .utility).async {
        defer {
          try? output.fileHandleForReading.close()
          readers.leave()
        }
        readPipe(output.fileHandleForReading) { bytes in
          let exceeded = self.synchronized { () -> Bool in
            if self.overflow { return false }
            if self.result.count + bytes.count <= self.limit {
              self.result.append(bytes)
              return false
            }
            self.overflow = true
            return true
          }
          if exceeded { self.terminate(child) }
        }
      }
      readers.enter()
      DispatchQueue.global(qos: .utility).async {
        defer {
          try? errors.fileHandleForReading.close()
          readers.leave()
        }
        readPipe(errors.fileHandleForReading) { _ in }
      }
      if let stdin {
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
          defer {
            try? input.fileHandleForWriting.close()
            readers.leave()
          }
          try? writePipe(input.fileHandleForWriting, data: stdin)
        }
      }
      let timer = DispatchWorkItem {
        guard child.isRunning else { return }
        self.synchronized { self.timedOut = true }
        self.terminate(child)
      }
      DispatchQueue.global(qos: .utility).asyncAfter(
        deadline: .now() + max(0.001, timeout), execute: timer)
      child.waitUntilExit()
      timer.cancel()
      readers.wait()
      let (cancelled, expired, tooLarge, data) = synchronized {
        (self.cancelled, timedOut, overflow, result)
      }
      if cancelled { throw CancellationError() }
      guard !expired, !tooLarge, child.terminationStatus == 0 else {
        throw NSError(
          domain: "Polka.Helper", code: Int(child.terminationStatus),
          userInfo: [
            NSLocalizedDescriptionKey: expired
              ? "Помощник не ответил вовремя"
              : tooLarge ? "Слишком большой ответ помощника" : "Нативный адаптер недоступен"
          ])
      }
      finish(.success(data))
    } catch {
      if child.isRunning { terminateAndReap(child) }
      try? input.fileHandleForWriting.close()
      try? output.fileHandleForReading.close()
      try? errors.fileHandleForReading.close()
      finish(.failure(error))
    }
  }
}

enum NativeCommand {
  /// Bounded subprocess work with exclusive pipe readers, cancellation, and process reaping.
  /// Images and recognized text travel only through pipes, never plaintext temporary files.
  static func run(
    _ url: URL, arguments: [String] = [], stdin: Data? = nil, timeout: TimeInterval = 2,
    limit: Int = 128 * 1024
  ) async throws -> Data {
    let operation = CommandOperation(
      url: url, arguments: arguments, stdin: stdin, timeout: timeout, limit: max(0, limit))
    let data = try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { operation.start($0) }
      }, onCancel: { operation.cancel() })
    try Task.checkCancellation()
    return data
  }
}
