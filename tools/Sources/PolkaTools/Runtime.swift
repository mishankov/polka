import Darwin
import Foundation

public struct ToolError: Error, CustomStringConvertible {
  public let description: String
  public let exitCode: Int32
  public init(_ message: String, exitCode: Int32 = 1) {
    description = message
    self.exitCode = exitCode
  }
}

public struct ToolContext {
  public var root: URL
  public var environment: [String: String]
  public var swiftBuildArguments: [String] {
    var arguments =
      environment["POLKA_SWIFT_BUILD_SYSTEM"] == "native"
      ? ["--build-system", "native"] : []
    if let value = environment["POLKA_SWIFT_BUILD_JOBS"], let jobs = Int(value), jobs > 0 {
      arguments += ["--jobs", String(jobs)]
    }
    return arguments
  }
  public init(
    root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.root = root
    self.environment = environment
  }
}

public enum Command {
  private final class ParallelWork: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [() throws -> Void]
    private(set) var failure: Error?
    init(_ operations: [() throws -> Void]) { pending = operations }
    func next() -> (() throws -> Void)? {
      lock.lock()
      defer { lock.unlock() }
      guard failure == nil, !pending.isEmpty else { return nil }
      return pending.removeFirst()
    }
    func fail(_ error: Error) {
      lock.lock()
      defer { lock.unlock() }
      if failure == nil { failure = error }
    }
  }
  /// Independent operations finish before returning, including on failure, so
  /// callers can safely remove their shared inputs and temporary directories.
  static func parallel(_ operations: [() throws -> Void], limit: Int) throws {
    try checkCancellation(true, registry: .shared)
    let work = ParallelWork(operations)
    if !operations.isEmpty {
      DispatchQueue.concurrentPerform(iterations: max(1, min(limit, operations.count))) { _ in
        while let operation = work.next() {
          do { try operation() } catch { work.fail(error) }
        }
      }
    }
    try checkCancellation(true, registry: .shared)
    if let failure = work.failure { throw failure }
  }
  /// Escalation retains the exact Process object, so a later unrelated process
  /// can never be targeted merely because macOS reused an exited child's PID.
  public static func terminate(_ process: Process, signal: Int32 = SIGTERM, grace: TimeInterval = 2)
  {
    guard process.isRunning else { return }
    kill(process.processIdentifier, signal)
    DispatchQueue.global().asyncAfter(deadline: .now() + max(0, grace)) {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }
  private static func checkCancellation(_ cancellable: Bool, registry: ToolCancellationRegistry)
    throws
  {
    if cancellable {
      try Task.checkCancellation()
      if registry.isCancelled { throw CancellationError() }
    }
  }
  public struct Result {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var error: String { String(decoding: stderr, as: UTF8.self) }
    public init(status: Int32, stdout: Data, stderr: Data) {
      self.status = status
      self.stdout = stdout
      self.stderr = stderr
    }
  }
  public static func process(
    _ executable: String, _ arguments: [String] = [],
    environment: [String: String]? = nil, directory: URL? = nil
  ) -> Process {
    let process = Process()
    if executable.contains("/") {
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [executable] + arguments
    }
    process.environment = environment ?? ProcessInfo.processInfo.environment
    process.currentDirectoryURL = directory
    return process
  }
  // File-backed streams avoid pipe deadlocks on large LLVM/probe output and
  // keep private stdin bytes out of process arguments and failure messages.
  public static func execute(
    _ executable: String, _ arguments: [String] = [],
    environment: [String: String]? = nil, directory: URL? = nil,
    input: Data? = nil, cancellable: Bool = true, registry: ToolCancellationRegistry = .shared
  ) throws -> Result {
    try checkCancellation(cancellable, registry: registry)
    let temporary = try Files.temporary("polka-command")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let out = temporary.appendingPathComponent("stdout")
    let err = temporary.appendingPathComponent("stderr")
    try Data().write(to: out)
    try Data().write(to: err)
    let output = try FileHandle(forWritingTo: out)
    let errors = try FileHandle(forWritingTo: err)
    defer {
      try? output.close()
      try? errors.close()
    }
    let process = self.process(
      executable, arguments, environment: environment, directory: directory)
    process.standardOutput = output
    process.standardError = errors
    var source: FileHandle?
    if let input {
      let path = temporary.appendingPathComponent("stdin")
      try input.write(to: path, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
      source = try FileHandle(forReadingFrom: path)
      process.standardInput = source
    } else {
      process.standardInput = FileHandle.nullDevice
    }
    defer { try? source?.close() }
    try process.run()
    let registration = cancellable ? registry.register { terminate(process) } : nil
    defer { if let registration { registry.unregister(registration) } }
    process.waitUntilExit()
    try checkCancellation(cancellable, registry: registry)
    return Result(
      status: process.terminationStatus, stdout: try Data(contentsOf: out),
      stderr: try Data(contentsOf: err))
  }
  public static func capture(
    _ executable: String, _ arguments: [String] = [],
    environment: [String: String]? = nil, directory: URL? = nil,
    input: Data? = nil, cancellable: Bool = true, registry: ToolCancellationRegistry = .shared
  ) throws -> String {
    let result = try execute(
      executable, arguments, environment: environment, directory: directory, input: input,
      cancellable: cancellable, registry: registry)
    guard result.status == 0 else {
      throw ToolError("\(executable) failed (\(result.status)).", exitCode: result.status)
    }
    return result.output
  }
  public static func run(
    _ executable: String, _ arguments: [String] = [],
    environment: [String: String]? = nil, directory: URL? = nil,
    cancellable: Bool = true, registry: ToolCancellationRegistry = .shared
  ) throws {
    try checkCancellation(cancellable, registry: registry)
    let process = self.process(
      executable, arguments, environment: environment, directory: directory)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    let registration = cancellable ? registry.register { terminate(process) } : nil
    defer { if let registration { registry.unregister(registration) } }
    process.waitUntilExit()
    try checkCancellation(cancellable, registry: registry)
    guard process.terminationStatus == 0 else {
      throw ToolError(
        "\(executable) failed (\(process.terminationStatus)).", exitCode: process.terminationStatus)
    }
  }
}

public enum Files {
  public static func temporary(_ prefix: String) throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return path
  }
  public static func mkdir(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
  public static func json(_ url: URL) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.fragmentsAllowed])
  }
  public static func writeJSON(_ value: Any, to url: URL) throws {
    try mkdir(url.deletingLastPathComponent())
    try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
    ).write(to: url, options: .atomic)
  }
  public static func relative(_ url: URL, to root: URL) -> String {
    let base = root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
  }
}
