import Foundation
import XCTest

@testable import PolkaTools

final class ParallelCommandTests: XCTestCase {
  func testIndependentOperationsOverlapWithoutExceedingLimit() {
    let arrived = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let completed = expectation(description: "all operations joined")
    let operation: () throws -> Void = {
      arrived.signal()
      guard proceed.wait(timeout: .now() + 5) == .success else {
        throw ToolError("Timed out waiting for test gate.")
      }
    }
    DispatchQueue.global().async {
      do { try Command.parallel(Array(repeating: operation, count: 4), limit: 2) } catch {
        XCTFail("Parallel work failed: \(error)")
      }
      completed.fulfill()
    }
    for _ in 0..<2 { XCTAssertEqual(arrived.wait(timeout: .now() + 2), .success) }
    XCTAssertEqual(arrived.wait(timeout: .now() + 0.1), .timedOut)
    for _ in 0..<2 { proceed.signal() }
    for _ in 0..<2 { XCTAssertEqual(arrived.wait(timeout: .now() + 2), .success) }
    for _ in 0..<2 { proceed.signal() }
    wait(for: [completed], timeout: 3)
  }
  func testFailureJoinsRunningWorkAndStopsQueuedOperations() {
    let otherStarted = DispatchSemaphore(value: 0)
    let otherFinished = DispatchSemaphore(value: 0)
    XCTAssertThrowsError(
      try Command.parallel(
        [
          {
            guard otherStarted.wait(timeout: .now() + 2) == .success else {
              throw ToolError("Other operation did not start.")
            }
            throw ToolError("Fixture failure.")
          },
          {
            otherStarted.signal()
            Thread.sleep(forTimeInterval: 0.1)
            otherFinished.signal()
          },
        ], limit: 2)
    ) { error in
      XCTAssertEqual((error as? ToolError)?.description, "Fixture failure.")
    }
    XCTAssertEqual(otherFinished.wait(timeout: .now()), .success)
    XCTAssertThrowsError(
      try Command.parallel(
        [
          { throw ToolError("First operation failed.") },
          { XCTFail("Queued work must not start after a failure.") },
        ], limit: 1)
    ) { error in
      XCTAssertEqual((error as? ToolError)?.description, "First operation failed.")
    }
  }
}
