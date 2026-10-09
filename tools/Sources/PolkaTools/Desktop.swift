import Darwin
import Foundation

public struct DesktopFailure: Error, LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// Every native GUI suite shares focus and synthetic drag events on one desktop.
public final class DesktopLock {
  public let path: URL
  private let token: String
  private init(path: URL, token: String) {
    self.path = path
    self.token = token
  }
  public static func acquire(
    path: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-desktop-tests.lock"),
    timeout: TimeInterval = 120
  ) async throws -> DesktopLock {
    let token = UUID().uuidString
    let deadline = Date().addingTimeInterval(timeout)
    let owner = path.appendingPathComponent("owner.json")
    let fm = FileManager.default
    while true {
      try Task.checkCancellation()
      if mkdir(path.path, 0o700) == 0 {
        do {
          try JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "token": token]).write(
            to: owner)
          return DesktopLock(path: path, token: token)
        } catch {
          try? fm.removeItem(at: path)
          throw error
        }
      }
      guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      var observed: Data?
      var stale = false
      do {
        observed = try Data(contentsOf: owner)
        guard let json = try JSONSerialization.jsonObject(with: observed!) as? [String: Any],
          let pid = json["pid"] as? Int, pid > 0, pid <= Int(Int32.max)
        else { throw DesktopFailure("Invalid desktop test owner") }
        stale = kill(pid_t(pid), 0) != 0 && errno == ESRCH
      } catch let error as NSError
        where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
      {
        let modified = (try? fm.attributesOfItem(atPath: path.path)[.modificationDate]) as? Date
        stale = modified.map { Date().timeIntervalSince($0) > 30 } ?? false
      }
      if stale {
        let reclaim = path.appendingPathComponent("reclaim")
        if mkdir(reclaim.path, 0o700) == 0 {
          let current = try? Data(contentsOf: owner)
          if current == observed {
            try? fm.removeItem(at: path)
          } else {
            try? fm.removeItem(at: reclaim)
          }
        } else if errno != EEXIST && errno != ENOENT {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
      guard Date() < deadline else {
        throw DesktopFailure("Another desktop suite owns \(path.path). Run GUI tests sequentially.")
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }
  public func release() throws {
    let owner = path.appendingPathComponent("owner.json")
    guard let data = try? Data(contentsOf: owner),
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["token"] as? String == token
    else { return }
    try FileManager.default.removeItem(at: path)
  }
}

final class DesktopChild: @unchecked Sendable {
  let process = Process()
  private let output = Pipe(), errors = Pipe(), mutex = NSLock()
  private var bytes = Data()
  var diagnostics: String {
    mutex.lock()
    defer { mutex.unlock() }
    return String(decoding: bytes, as: UTF8.self)
  }
  init(executable: URL, arguments: [String], environment: [String: String], directory: URL? = nil)
    throws
  {
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = directory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    for pipe in [output, errors] {
      let handle = pipe.fileHandleForReading
      let flags = fcntl(handle.fileDescriptor, F_GETFL)
      guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw POSIXError(.EIO)
      }
      pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        self?.drain(handle)
      }
    }
    try process.run()
  }
  private func drain(_ handle: FileHandle) {
    mutex.lock()
    defer { mutex.unlock() }
    var buffer = [UInt8](repeating: 0, count: 8192)
    let capacity = buffer.count
    while true {
      let count = read(handle.fileDescriptor, &buffer, capacity)
      if count > 0 {
        bytes.append(contentsOf: buffer.prefix(count))
      } else if count == 0 {
        handle.readabilityHandler = nil
        return
      } else if errno == EINTR {
        continue
      } else {
        return
      }
    }
  }
  func exit(timeout: TimeInterval) async throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    guard !process.isRunning else {
      throw DesktopFailure("Fixture did not stop cleanly: \(diagnostics)")
    }
    return process.terminationStatus
  }
  func wait(timeout: TimeInterval) async throws {
    let code = try await exit(timeout: timeout)
    guard process.terminationReason == .exit && code == 0 else {
      throw DesktopFailure("Fixture exited \(process.terminationStatus): \(diagnostics)")
    }
  }
  func stop() async throws {
    // Cleanup must finish even if the calling test task was cancelled.
    try await Task.detached { try await self.stopOwnedProcess() }.value
  }
  private func stopOwnedProcess() async throws {
    if process.isRunning {
      process.terminate()
      let deadline = Date().addingTimeInterval(3)
      while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < killDeadline {
          try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !process.isRunning else { throw DesktopFailure("Fixture did not stop after SIGKILL") }
      }
    }
    for pipe in [output, errors] {
      pipe.fileHandleForReading.readabilityHandler = nil
      drain(pipe.fileHandleForReading)
    }
  }
}

public enum Desktop {
  public static func environment(_ input: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String]
  {
    input.filter { $0.key != "ELECTRON_RUN_AS_NODE" }
  }
  static func directory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      prefix + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
  }
  static func appURL(_ explicit: URL?, release: Bool, context: ToolContext) -> URL {
    if let explicit { return explicit }
    let path =
      context.environment["POLKA_NATIVE_APP"]
      ?? "release/\(release ? "native-build" : "native-dev")/Polka Native.app"
    return
      (path.hasPrefix("/") ? URL(fileURLWithPath: path) : context.root.appendingPathComponent(path))
      .standardizedFileURL
  }
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DesktopFailure(message) }
  }
  static func report(_ path: URL, child: DesktopChild, timeout: TimeInterval) async throws
    -> [String: Any]
  {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let bytes = try? Data(contentsOf: path),
        let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
      {
        return json
      }
      if !child.process.isRunning { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw DesktopFailure("No native smoke report: \(child.diagnostics)")
  }
  static func save(_ json: [String: Any], to path: URL) throws {
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(
      to: path, options: .atomic)
  }
  public static func smoke(
    release: Bool = false, app: URL? = nil, scrollOnly: Bool = false,
    context: ToolContext = ToolContext()
  ) async throws {
    let only = scrollOnly || context.environment["POLKA_NATIVE_SCROLL_ONLY"] == "1"
    for phase in only ? ["scroll"] : ["scroll", "core", "startup", "notice"] {
      try await smokePhase(
        phase, app: appURL(app, release: release, context: context), context: context)
    }
  }
  public static func smokeSync(app: URL, context: ToolContext = ToolContext()) throws {
    try runSync { try await smoke(app: app, context: context) }
  }
  static func runSync(
    registry: ToolCancellationRegistry = .shared, operation: @escaping () async throws -> Void
  ) throws {
    try Task.checkCancellation()
    let result = DesktopSyncResult()
    let task = Task.detached {
      do {
        try await operation()
        result.result = .success(())
      } catch { result.result = .failure(error) }
      result.ready.signal()
    }
    let registration = registry.register { task.cancel() }
    defer { registry.unregister(registration) }
    result.ready.wait()
    try result.result!.get()
  }
  private static func smokePhase(_ phase: String, app: URL, context: ToolContext) async throws {
    let lock = try await DesktopLock.acquire()
    defer { try? lock.release() }
    let profile = try directory("polka-native-desktop-")
    let artifacts = context.root.appendingPathComponent("artifacts/desktop/native-smoke")
    let filename = phase == "core" ? "result" : "\(phase)-result"
    let resultPath = profile.appendingPathComponent(filename + ".json")
    var child: DesktopChild?
    do {
      try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
      let flag = [
        "scroll": "--native-scroll-smoke", "core": "--native-smoke",
        "startup": "--native-startup-close-smoke", "notice": "--native-notice-quit-smoke",
      ][phase]!
      var env = environment(context.environment)
      env["POLKA_PROFILE"] = profile.path
      env["POLKA_NATIVE_FIXTURE"] = "1"
      env["POLKA_NATIVE_SMOKE_RESULT"] = resultPath.path
      env["POLKA_NATIVE_SMOKE_SCREENSHOT"] = artifacts.appendingPathComponent("clipboard.png").path
      env["POLKA_NATIVE_SMOKE_SCREENSHOT_DIR"] = artifacts.path
      let running = try DesktopChild(
        executable: app.appendingPathComponent("Contents/MacOS/PolkaNative"),
        // Pin the default macOS tab-navigation mode in this child only. Tests
        // must not inherit a developer's global keyboard-navigation setting.
        arguments: [flag, "-AppleKeyboardUIMode", "0"],
        environment: env, directory: context.root)
      child = running
      let result = try await report(
        resultPath, child: running, timeout: phase == "scroll" || phase == "startup" ? 30 : 60)
      try save(result, to: artifacts.appendingPathComponent(filename + ".json"))
      try validateSmoke(result, phase: phase)
      try await running.wait(timeout: 5)
      try await running.stop()
      try Data(running.diagnostics.utf8).write(to: artifacts.appendingPathComponent("\(phase).log"))
      try FileManager.default.removeItem(at: profile)
      try lock.release()
      print("Native desktop \(phase) smoke passed.")
    } catch {
      if let child {
        if child.process.isRunning,
          let failure = error as? DesktopFailure,
          failure.message.hasPrefix("No native smoke report:")
        {
          // Sample only the child owned by this locked, isolated fixture,
          // before cleanup removes the process that failed to make progress.
          if let sampler = try? DesktopChild(
            executable: URL(fileURLWithPath: "/usr/bin/sample"),
            arguments: [
              String(child.process.processIdentifier), "1", "-file",
              artifacts.appendingPathComponent("\(phase)-timeout.sample.txt").path,
            ], environment: environment(context.environment))
          {
            try? await sampler.wait(timeout: 5)
            try? await sampler.stop()
            try? Data(sampler.diagnostics.utf8).write(
              to: artifacts.appendingPathComponent("\(phase)-timeout.sample.log"))
          }
        }
        try await child.stop()
        try? Data(child.diagnostics.utf8).write(
          to: artifacts.appendingPathComponent("\(phase).log"))
      }
      try? FileManager.default.removeItem(at: profile)
      try? lock.release()
      throw error
    }
  }

  static func validateSmoke(_ result: [String: Any], phase: String) throws {
    try require(
      ["core", "scroll", "startup", "notice"].contains(phase), "Unknown native smoke phase")
    try require(
      result["ok"] as? Bool == true, (result["failures"] as? [String] ?? []).joined(separator: "\n")
    )
    try require(result["nativeVisible"] as? Bool == true, "Native shelf is not visible")
    try require(
      result["destination"] as? String == (phase == "core" ? "clipboard" : "apps"),
      "Unexpected native destination")
    if phase == "core" {
      try require((result["snippets"] as? Int ?? 0) > 0, "Missing synthetic snippets")
    } else if phase == "startup" || phase == "notice" {
      try require(
        result["storageStatus"] as? String == "starting", "Blocked startup touched storage")
    }
  }

  public static func files(
    release: Bool = false, app: URL? = nil, external: Bool = true,
    context: ToolContext = ToolContext()
  ) async throws {
    let phases =
      context.environment["POLKA_NATIVE_EXTERNAL_ONLY"] == "1"
      ? [true] : external ? [false, true] : [false]
    for outside in phases {
      try await filesPhase(
        app: appURL(app, release: release, context: context), external: outside, context: context)
    }
  }
  private static func filesPhase(app: URL, external: Bool, context: ToolContext) async throws {
    let lock = try await DesktopLock.acquire()
    defer { try? lock.release() }
    let profile = try directory("polka-native-file-drop-")
    let artifacts = context.root.appendingPathComponent("artifacts/desktop/native-file-drop")
    let resultPath = profile.appendingPathComponent("file-drop-result.json")
    var child: DesktopChild?
    do {
      try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
      var env = environment(context.environment)
      env["POLKA_PROFILE"] = profile.path
      env["POLKA_NATIVE_FIXTURE"] = "1"
      env["POLKA_NATIVE_SMOKE_RESULT"] = resultPath.path
      if external {
        let source = profile.appendingPathComponent("external-source")
        let compiler = try DesktopChild(
          executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
          arguments: [
            "swiftc",
            context.root.appendingPathComponent("tests/desktop/native-external-file-source.swift")
              .path, "-o", source.path,
          ], environment: env, directory: context.root)
        do {
          try await compiler.wait(timeout: 60)
          try await compiler.stop()
        } catch {
          try await compiler.stop()
          throw error
        }
        env["POLKA_NATIVE_EXTERNAL_FILE_DROP"] = "1"
        env["POLKA_NATIVE_EXTERNAL_DRAG_SOURCE"] = source.path
      }
      let running = try DesktopChild(
        executable: app.appendingPathComponent("Contents/MacOS/PolkaNative"),
        arguments: [external ? "--native-external-file-drop-smoke" : "--native-file-drop-smoke"],
        environment: env, directory: context.root)
      child = running
      let result = try await report(resultPath, child: running, timeout: 80)
      try save(
        result,
        to: artifacts.appendingPathComponent(external ? "external-result.json" : "result.json"))
      try validateFiles(result, external: external)
      try await running.wait(timeout: 5)
      try await running.stop()
      try Data(running.diagnostics.utf8).write(
        to: artifacts.appendingPathComponent(external ? "external.log" : "app.log"))
      try FileManager.default.removeItem(at: profile)
      print("Native \(external ? "external " : "")file-drop smoke passed.")
    } catch {
      if let child {
        try await child.stop()
        try? Data(child.diagnostics.utf8).write(
          to: artifacts.appendingPathComponent(external ? "external.log" : "app.log"))
      }
      try? FileManager.default.removeItem(at: profile)
      throw error
    }
  }
  static func validateFiles(_ report: [String: Any], external: Bool) throws {
    try require(
      report["ok"] as? Bool == true, (report["failures"] as? [String] ?? []).joined(separator: "\n")
    )
    let targets = report["targets"] as? [[String: Any]] ?? []
    let names =
      external
      ? [
        "external-center", "external-bottom", "external-row", "external-release-first",
        "external-duplicate-enter",
      ]
      : [
        "empty-center", "empty-bottom", "header", "populated-center-two-files", "populated-row",
        "scroll-populated-body",
      ]
    try require(
      targets.compactMap { $0["name"] as? String } == names, "Missing genuine native drag targets")
    for target in targets {
      let name = target["name"] as? String ?? "target"
      for field in [
        "sessionStarted", "sessionCompleted", "accepted", "highlightObserved", "highlightCleared",
      ] {
        try require(target[field] as? Bool == true, "\(name): \(field) failed")
      }
      try require(
        (target["operation"] as? Int ?? 0) != 0, "\(name): native drag operation cancelled")
      let expected = target["expectedEnd"] as? [String: Double] ?? [:]
      let actual = target["actualEnd"] as? [String: Double] ?? [:]
      guard let ex = expected["x"], let ey = expected["y"], let ax = actual["x"],
        let ay = actual["y"]
      else { throw DesktopFailure("\(name): missing drag coordinates") }
      try require(hypot(ex - ax, ey - ay) <= 4, "\(name): drag did not end at requested target")
      if external {
        try require(
          target["sourcePID"] as? Int != report["mainPID"] as? Int,
          "\(name): external source was not independent")
        for field in ["inactiveBeforeDrag", "helperEntered", "autoOpened"] {
          try require(target[field] as? Bool == true, "\(name): \(field) failed")
        }
        try require(
          target["selfDrop"] as? Bool == false, "\(name): incoming drag treated as self-drop")
      } else {
        try require(
          (target["hitView"] as? String ?? "").isEmpty == false
            && (target["viewChain"] as? [[String: Any]] ?? []).isEmpty == false,
          "\(name): missing routed native view")
        try require(
          (target["sourceReceived"] as? [String]) == [],
          "\(name): self-drop masqueraded as target drop")
      }
    }
    if external {
      try require(report["fileProbeRunning"] as? Bool == true, "Real file probe was not running")
      try require(
        report["driver"] as? String == "external AppKit + real file probe + guarded sessionTap",
        "Wrong external drag driver")
      let events = report["events"] as? [[String: Any]] ?? []
      try require(
        events.contains {
          $0["kind"] as? String == "source.mask" && $0["context"] as? String == "outside"
        }, "No external source operation mask")
      try require(
        events.contains {
          $0["kind"] as? String == "native.perform" && $0["sourceNil"] as? Bool == true
        }, "No external native drop")
      for kind in ["deterministic.releaseFirst", "deterministic.duplicateEnter.after"] {
        try require(
          events.contains { $0["kind"] as? String == kind }, "Missing \(kind) lifecycle regression")
      }
    } else {
      try require(
        report["driver"] as? String
          == "CGEvent sessionTap with existing Accessibility + own-window checks",
        "Wrong native drag driver")
      for field in ["clickWorks", "scrollWorks", "outgoingWorks"] {
        try require(report[field] as? Bool == true, "Ordinary input failed: \(field)")
      }
      try require(report["outgoingStarts"] as? Int == 1, "Outgoing drag did not start exactly once")
    }
  }
}

private final class DesktopSyncResult: @unchecked Sendable {
  let ready = DispatchSemaphore(value: 0)
  var result: Result<Void, Error>?
}
