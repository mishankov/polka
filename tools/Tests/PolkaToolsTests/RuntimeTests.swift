import Foundation
import XCTest

@testable import PolkaTools

final class RuntimeTests: XCTestCase {
  func testLargeSeparateStreamsDoNotDeadlock() throws {
    let result = try Command.execute(TestSupport.fixture.path, ["streams"])
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.stdout.count, 1_000_000)
    XCTAssertEqual(result.stderr.count, 1_000_000)
  }
  func testPrivateInputRemainsOutOfArgumentsAndErrors() throws {
    let input = Data("synthetic-private-stdin".utf8)
    let result = try Command.execute(TestSupport.fixture.path, ["stdin"], input: input)
    XCTAssertEqual(result.stdout, input)
    XCTAssertThrowsError(try Command.capture(TestSupport.fixture.path, ["fail"], input: input)) {
      error in
      XCTAssertFalse(String(describing: error).contains("secret"))
      XCTAssertFalse(String(describing: error).contains("synthetic-private"))
      XCTAssertEqual((error as? ToolError)?.exitCode, 9)
    }
  }
  func testJSONComparisonKeepsBooleanAndNumberDistinct() throws {
    XCTAssertNotEqual(try Regression.canonicalJSON(true), try Regression.canonicalJSON(1))
    XCTAssertEqual(
      try Regression.canonicalJSON(["b": 2, "a": 1]),
      try Regression.canonicalJSON(["a": 1, "b": 2]))
  }
}
