import Foundation
import XCTest

@testable import PolkaCore

final class ClipboardColorTests: XCTestCase {
  func testWholeColorValuesAndTransparency() throws {
    for value in [
      "#f00", "#ff0000", "rgb(255, 0, 0)", "rgb(100% 0% 0%)", "hsl(0, 100%, 50%)",
      "hsl(1turn 100% 50%)", "hsl(-360deg, 100%, 50%)",
    ] {
      let color = try XCTUnwrap(ClipboardColor.parse(value), value)
      XCTAssertEqual(color.red, 1, accuracy: 0.00001, value)
      XCTAssertEqual(color.green, 0, accuracy: 0.00001, value)
      XCTAssertEqual(color.blue, 0, accuracy: 0.00001, value)
      XCTAssertEqual(color.alpha, 1, value)
    }
    for value in ["#f008", "#ff000088"] {
      XCTAssertEqual(
        try XCTUnwrap(ClipboardColor.parse(value)).alpha, 136 / 255.0, accuracy: 0.00001)
    }
    for value in [
      "rgba(255, 0, 0, 0.5)", "rgb(255 0 0 / 50%)", "hsla(0, 100%, 50%, .5)",
      "hsl(0 100% 50% / 50%)",
    ] {
      XCTAssertEqual(try XCTUnwrap(ClipboardColor.parse(value)).alpha, 0.5, value)
    }
    XCTAssertEqual(try XCTUnwrap(ClipboardColor.parse("#0000")).alpha, 0)
    let green = try XCTUnwrap(ClipboardColor.parse("hsl(120, 100%, 50%)"))
    XCTAssertEqual(green.green, 1, accuracy: 0.00001)
    XCTAssertNotNil(ClipboardColor.parse(" \n#AbCdEf\t"))
    for value in ["hsl(200grad, 100%, 50%)", "hsl(3.141592653589793rad, 100%, 50%)"] {
      let color = try XCTUnwrap(ClipboardColor.parse(value))
      XCTAssertEqual(color.green, 1, accuracy: 0.00001)
      XCTAssertEqual(color.blue, 1, accuracy: 0.00001)
    }
    for hue in [60, 180, 240, 300] {
      XCTAssertNotNil(ClipboardColor.parse("hsl(\(hue) 100% 50%)"))
    }
  }

  func testInvalidColorsAndProseAreNotSwatches() {
    for value in [
      "Use #f00", "#f00 is red", "#12", "#12345", "#ggg", "#ＦＦＦ", "rgb(256,0,0)", "rgb(-1,0,0)",
      "rgb(1%,2,3)", "rgb(1,2,3,0.5)", "rgba(1,2,3)", "rgba(1,2,3,2)", "rgba(1,2,3,NaN)",
      "rgb(1 2 3 / -1)", "rgb(1 2 / 3)", "hsl(0,50,50)", "hsl(0,101%,50%)", "hsl(inf,50%,50%)",
      "red", "url(https://example.com)", "rgb(1,2,3) extra",
      String(repeating: " ", count: 300) + "#fff",
    ] {
      XCTAssertNil(ClipboardColor.parse(value), value)
    }
  }

  func testLargeContentIsNotParsedAsColor() {
    let huge = String(repeating: "x", count: 1_048_576)
    XCTAssertNil(ClipboardColor.parse(huge))
  }
}
