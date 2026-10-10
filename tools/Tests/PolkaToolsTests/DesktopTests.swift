import Darwin
import Foundation
import XCTest

@testable import PolkaTools

final class DesktopTests: XCTestCase {
  func testLiveLockCannotBeStolenAndOwnerCanRelease() async throws {
    let root = try Files.temporary("polka-lock-test")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("desktop.lock")
    let first = try await DesktopLock.acquire(path: path, timeout: 1)
    do {
      _ = try await DesktopLock.acquire(path: path, timeout: 0.05)
      XCTFail("Live owner evicted")
    } catch { XCTAssertTrue(String(describing: error).contains("Another desktop suite")) }
    try first.release()
    let second = try await DesktopLock.acquire(path: path, timeout: 1)
    try second.release()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
  }
  func testDeadOwnerReclaimedAndReplacementTokenPreserved() async throws {
    let root = try Files.temporary("polka-lock-test")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("desktop.lock")
    try Files.mkdir(path)
    try Files.writeJSON(
      ["pid": Int(Int32.max), "token": "dead"], to: path.appendingPathComponent("owner.json"))
    let lock = try await DesktopLock.acquire(path: path, timeout: 1)
    try Files.writeJSON(
      ["pid": Int(getpid()), "token": "replacement"], to: path.appendingPathComponent("owner.json"))
    try lock.release()
    let owner = try Files.json(path.appendingPathComponent("owner.json")) as? [String: Any]
    XCTAssertEqual(owner?["token"] as? String, "replacement")
  }
  func testIncompleteNewLockGetsOwnerWriteGraceAndCorruptOwnerFailsClosed() async throws {
    let root = try Files.temporary("polka-lock-test")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("desktop.lock")
    try Files.mkdir(path)
    do {
      _ = try await DesktopLock.acquire(path: path, timeout: 0.05)
      XCTFail("Incomplete new owner evicted")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    try Files.writeJSON(
      ["pid": -1, "token": "invalid"], to: path.appendingPathComponent("owner.json"))
    do {
      _ = try await DesktopLock.acquire(path: path, timeout: 0.05)
      XCTFail("Invalid owner accepted")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
  }
  func testChildCleanupReapsOnlySyntheticOwnedProcess() async throws {
    let child = try DesktopChild(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"],
      environment: Desktop.environment())
    XCTAssertTrue(child.process.isRunning)
    try await child.stop()
    XCTAssertFalse(child.process.isRunning)
    XCTAssertEqual(kill(child.process.processIdentifier, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }
  func testCancelledTaskStillDrainsSyntheticChild() async throws {
    let child = try DesktopChild(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"],
      environment: Desktop.environment())
    let task = Task { try await child.stop() }
    task.cancel()
    try await task.value
    XCTAssertFalse(child.process.isRunning)
  }
  func testCleanupMarkersLiteralAndUnsafeMarkersRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-native-update-fixture.[1]")
    let pattern = try UpdateFixtureCleanup.pattern(
      directory: root, appID: "app.polka.native-update-test.123")
    let regex = try NSRegularExpression(pattern: pattern)
    XCTAssertNotNil(
      regex.firstMatch(in: root.path, range: NSRange(root.path.startIndex..., in: root.path)))
    XCTAssertNil(
      regex.firstMatch(
        in: "appXpolkaXnative-update-testX123", range: NSRange(location: 0, length: 32)))
    XCTAssertThrowsError(
      try UpdateFixtureCleanup.pattern(
        directory: URL(fileURLWithPath: "/Applications/Polka.app"),
        appID: "app.polka.native-update-test.123"))
    XCTAssertThrowsError(
      try UpdateFixtureCleanup.pattern(directory: root, appID: "app.polka.desktop"))
    XCTAssertEqual(
      try UpdateFixtureCleanup.targets(output: "12\n13\n", status: 0, ownPID: 12), [13])
    XCTAssertEqual(try UpdateFixtureCleanup.targets(output: "", status: 1), [])
    XCTAssertThrowsError(try UpdateFixtureCleanup.targets(output: "not-a-pid", status: 0))
    XCTAssertThrowsError(try UpdateFixtureCleanup.targets(output: "", status: 2))
  }
  func testDesktopEnvironmentRetainsSyntheticProfileAndStripsHostMode() {
    XCTAssertEqual(
      Desktop.environment([
        "ELECTRON_RUN_AS_NODE": "1", "POLKA_PROFILE": "synthetic", "OTHER": "value",
      ]), ["POLKA_PROFILE": "synthetic", "OTHER": "value"])
  }
  func testUpdaterCleanupTerminatesOnlyProcessesUnderDisposableMarker() async throws {
    let root = try Desktop.directory("polka-native-update-")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("synthetic-sleeper")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
    let fixture = try DesktopChild(
      executable: executable, arguments: ["20"], environment: Desktop.environment())
    let unrelated = try DesktopChild(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"],
      environment: Desktop.environment())
    do {
      try await UpdateFixtureCleanup.stop(
        directory: root, appID: "app.polka.native-update-test.123456")
      XCTAssertFalse(fixture.process.isRunning)
      XCTAssertTrue(unrelated.process.isRunning)
      try await fixture.stop()
      try await unrelated.stop()
    } catch {
      try await fixture.stop()
      try await unrelated.stop()
      throw error
    }
  }
}
