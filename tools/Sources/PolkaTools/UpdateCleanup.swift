import Darwin
import Foundation

public enum UpdateFixtureCleanup {
  /// Reject broad markers before inspecting or signalling any processes.
  public static func pattern(directory: URL, appID: String) throws -> String {
    let root = directory.standardizedFileURL
    guard root.lastPathComponent.hasPrefix("polka-native-update-"),
      root.deletingLastPathComponent().resolvingSymlinksInPath().path
        == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path,
      appID.hasPrefix("app.polka.native-update-test."),
      appID.dropFirst("app.polka.native-update-test.".count).allSatisfy({ $0.isNumber }),
      !appID.dropFirst("app.polka.native-update-test.".count).isEmpty
    else { throw DesktopFailure("Refusing cleanup without disposable updater fixture markers") }
    return [root.path, appID].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
  }
  public static func targets(output: String, status: Int32, ownPID: Int32 = getpid()) throws
    -> [Int32]
  {
    if status == 1 { return [] }
    guard status == 0 else { throw DesktopFailure("Could not inspect updater fixture processes") }
    return try output.split(whereSeparator: { $0.isWhitespace }).compactMap { value in
      guard let pid = Int32(value), pid > 0 else {
        throw DesktopFailure("Invalid updater fixture process ID")
      }
      return pid == ownPID ? nil : pid
    }
  }
  public static func stop(directory: URL, appID: String) async throws {
    let marker = try pattern(directory: directory, appID: appID)
    let deadline = Date().addingTimeInterval(15)
    var start: Date?
    var signalled = Set<Int32>()
    while Date() < deadline {
      let scan = try DesktopChild(
        executable: URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", marker],
        environment: Desktop.environment())
      let status: Int32
      do { status = try await scan.exit(timeout: min(5, deadline.timeIntervalSinceNow)) } catch {
        try? await scan.stop()
        if Date() < deadline { continue }
        throw error
      }
      try await scan.stop()
      let pids = try targets(output: scan.diagnostics, status: status)
      if pids.isEmpty { return }
      start = start ?? Date()
      let signal = Date().timeIntervalSince(start!) >= 2 ? SIGKILL : SIGTERM
      for pid in pids {
        if signal == SIGTERM && signalled.contains(pid) { continue }
        if kill(pid, signal) != 0 && errno != ESRCH {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        signalled.insert(pid)
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw DesktopFailure("Timed out waiting for updater fixture processes to exit")
  }
}
