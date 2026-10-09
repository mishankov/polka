import Foundation
import XCTest

@testable import PolkaTools

final class CIBudgetTests: XCTestCase {
  private let names = [
    "Verify native macOS source", "Verify Swift tooling", "Package and test native macOS arm64",
  ]

  private func fixture(
    starts: [Int] = [0, 0, 0], finishes: [Int] = [240, 120, 300], queue: Int = 0
  ) -> [[String: Any]] {
    let origin = Date(timeIntervalSince1970: 1_791_504_000)
    let formatter = ISO8601DateFormatter()
    func stamp(_ seconds: Int) -> String {
      formatter.string(from: origin.addingTimeInterval(Double(seconds)))
    }
    return names.indices.map { index in
      [
        "name": names[index], "status": "completed", "created_at": stamp(-queue),
        "started_at": stamp(starts[index]), "completed_at": stamp(finishes[index]),
      ]
    }
  }

  private func check(_ pages: [[String: Any]], withSummary: Bool = false) throws -> Command.Result {
    let temporary = try Files.temporary("polka-ci-budget")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let path = temporary.appendingPathComponent("jobs.json")
    try JSONSerialization.data(withJSONObject: pages).write(to: path)
    if withSummary {
      return try Command.execute(
        "/bin/bash",
        [
          "--noprofile", "--norc", "-e", "-o", "pipefail", "-c",
          #"bash "$1" "$2" | tee "$3""#, "ci-budget",
          TestSupport.root.appendingPathComponent("scripts/check-ci-budget.sh").path, path.path,
          temporary.appendingPathComponent("summary.md").path,
        ])
    }
    return try Command.execute(
      "/bin/bash",
      [TestSupport.root.appendingPathComponent("scripts/check-ci-budget.sh").path, path.path])
  }

  func testExactlyFiveMinutesPassesAndInitialQueueIsSeparate() throws {
    let result = try check([["jobs": fixture(queue: 180)]])
    XCTAssertEqual(result.status, 0, result.error)
    XCTAssertTrue(result.output.contains("300s / 300s"))
    XCTAssertTrue(result.output.contains("outside budget): 180s"))
  }

  func testOneSecondOverBudgetFails() throws {
    let result = try check([["jobs": fixture(finishes: [240, 120, 301])]])
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("301s / 300s"))
    XCTAssertTrue(result.output.contains("::error::"))
  }

  func testBudgetFailureSurvivesSummaryPipeline() throws {
    let result = try check([["jobs": fixture(finishes: [240, 120, 301])]], withSummary: true)
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("301s / 300s"))
  }

  func testStaggeredRunnerQueuesAreExcludedFromExecutionBudget() throws {
    let result = try check([
      ["jobs": fixture(starts: [0, 120, 180], finishes: [180, 240, 420])]
    ])
    XCTAssertEqual(result.status, 0, result.error)
    XCTAssertTrue(result.output.contains("240s / 300s"))
    XCTAssertTrue(result.output.contains("staggered runner queues: 420s"))
    XCTAssertTrue(result.output.contains("240s execution, 180s runner queue"))
  }

  func testLongQueueDoesNotHideExecutionOverrun() throws {
    let result = try check([
      ["jobs": fixture(starts: [0, 120, 600], finishes: [180, 240, 901])]
    ])
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("301s / 300s"))
    XCTAssertTrue(result.output.contains("301s execution, 600s runner queue"))
  }

  func testPaginationAndUnrelatedAggregateJob() throws {
    let jobs = fixture()
    let result = try check([
      ["jobs": Array(jobs.prefix(1))],
      ["jobs": Array(jobs.dropFirst()) + [["name": "aggregate"]]],
    ])
    XCTAssertEqual(result.status, 0, result.error)
  }

  func testMissingDuplicateUnfinishedAndInvalidJobsFailClosed() throws {
    var duplicate = fixture()
    duplicate.append(duplicate[0])
    var unfinished = fixture()
    unfinished[0]["status"] = "in_progress"
    var reversed = fixture()
    reversed[0]["completed_at"] = reversed[0]["created_at"]
    reversed[0]["started_at"] = reversed[1]["completed_at"]
    var invalid = fixture()
    invalid[0]["completed_at"] = "invalid date"
    for jobs in [Array(fixture().dropLast()), duplicate, unfinished, reversed, invalid] {
      let result = try check([["jobs": jobs]])
      XCTAssertNotEqual(result.status, 0)
      XCTAssertTrue(result.output.contains("::error::"))
    }
  }
}
