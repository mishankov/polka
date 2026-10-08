import Foundation
import XCTest

@testable import PolkaTools

final class ToolCancellationTests: XCTestCase {
  func testCancellationReachesActiveAndLateBridgesExactlyOnce() {
    let registry = ToolCancellationRegistry()
    var active = 0
    var late = 0
    var removed = 0
    registry.register { active += 1 }
    let registration = registry.register { removed += 1 }
    registry.unregister(registration)
    registry.cancel()
    registry.cancel()
    registry.register { late += 1 }
    XCTAssertEqual(active, 1)
    XCTAssertEqual(late, 1)
    XCTAssertEqual(removed, 0)
  }
  func testCallbacksRunOutsideLockAndCanUnregisterOrRegister() {
    let registry = ToolCancellationRegistry()
    var nested = false
    registry.register { registry.register { nested = true } }
    registry.cancel()
    XCTAssertTrue(nested)
  }
  func testSynchronousDesktopBridgeWaitsForChildCleanupAfterCancellation() async throws {
    let registry = ToolCancellationRegistry()
    let started = DispatchSemaphore(value: 0)
    let child = try DesktopChild(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"],
      environment: Desktop.environment())
    let worker = Task.detached {
      try Desktop.runSync(registry: registry) {
        started.signal()
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch {
          try await child.stop()
          throw error
        }
      }
    }
    XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
    registry.cancel()
    do {
      try await worker.value
      XCTFail("Cancelled desktop bridge completed without cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(child.process.isRunning)
  }
}
