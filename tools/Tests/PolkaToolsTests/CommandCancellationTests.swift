import Darwin
import Foundation
import XCTest

@testable import PolkaTools

final class CommandCancellationTests: XCTestCase {
  func testCancellationEscalatesAndReapsChildIgnoringTermination() async throws {
    let root = try Files.temporary("polka-cancellation-test")
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("ready.pid")
    let registry = ToolCancellationRegistry()
    let worker = Task.detached {
      try Command.capture(
        TestSupport.fixture.path, ["ignore-termination", ready.path], registry: registry)
    }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let bytes = try? String(contentsOf: ready, encoding: .utf8)
    registry.cancel()
    let start = Date()
    do {
      _ = try await worker.value
      XCTFail("Cancelled command completed successfully")
    } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    let pid = try XCTUnwrap(bytes.flatMap { Int32($0) })
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }
  func testCancelledRegistryRejectsNewWorkButAllowsExplicitCleanup() throws {
    let registry = ToolCancellationRegistry()
    registry.cancel()
    XCTAssertThrowsError(
      try Command.execute(TestSupport.fixture.path, ["stdin"], registry: registry)
    ) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertThrowsError(try Command.run(TestSupport.fixture.path, ["stdin"], registry: registry)) {
      XCTAssertTrue($0 is CancellationError)
    }
    let secret = Data("synthetic cleanup stdin".utf8)
    XCTAssertEqual(
      try Command.capture(
        TestSupport.fixture.path, ["stdin"], input: secret, cancellable: false, registry: registry),
      String(decoding: secret, as: UTF8.self))
    try Command.run(TestSupport.fixture.path, ["stdin"], cancellable: false, registry: registry)
  }
  func testTaskCancellationStillAllowsRequiredCleanup() async throws {
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let worker = Task.detached {
      started.signal()
      proceed.wait()
      return try Command.capture(
        TestSupport.fixture.path, ["stdin"], input: Data("cleanup survived".utf8),
        cancellable: false, registry: ToolCancellationRegistry())
    }
    XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
    worker.cancel()
    proceed.signal()
    let result = try await worker.value
    XCTAssertEqual(result, "cleanup survived")
  }
}
