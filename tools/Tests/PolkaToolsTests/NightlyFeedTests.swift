import Foundation
import XCTest

@testable import PolkaTools

final class NightlyFeedTests: XCTestCase {
  func testPublicationSelectsStableAndNightlyWithoutDowngrades() throws {
    let result = try Command.execute(
      "/usr/bin/env",
      ["python3", "-B", "scripts/tests/test_publish_nightly_feed.py"], directory: TestSupport.root)
    XCTAssertEqual(result.status, 0, result.output + result.error)
  }
}
