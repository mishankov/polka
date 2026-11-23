import XCTest

@testable import PolkaCore

final class ShelfConversionTests: XCTestCase {
  func testIntegerBases() {
    for (query, expected) in [
      ("255 to hex", "0xFF"),
      ("0xFF to dec", "255"),
      ("0b11111111 to oct", "0o377"),
      ("0O377 IN BIN", "0b11111111"),
      ("  +010 в HEX  ", "0xA"),
      ("−0Xff to oct", "-0o377"),
      ("-0b0 to hex", "0x0"),
      ("0x20000000000001 to dec", "9007199254740993"),
      ("9223372036854775807 to hex", "0x7FFFFFFFFFFFFFFF"),
      ("-0x8000000000000000 to dec", "-9223372036854775808"),
    ] {
      let result = Calculator.calculate(query)
      XCTAssertEqual(result?.status, .result, query)
      XCTAssertEqual(result?.value, expected, query)
    }
  }

  func testRejectsInvalidIntegerDigitsAndOverflow() {
    for query in [
      "0b102 to dec", "0o8 to dec", "0xG to dec", "0x to dec", "1e3 to hex",
      "9223372036854775808 to hex", "-9223372036854775809 to hex",
      "0x8000000000000000 to dec", "-0x8000000000000001 to dec",
    ] {
      let result = Calculator.calculate(query)
      XCTAssertEqual(result?.status, .error, query)
      XCTAssertNil(result?.value, query)
    }
  }

  func testUnixSecondsRoundTrip() {
    for (seconds, date) in [
      ("1704067200", "2024-01-01 00:00:00 UTC"),
      ("0", "1970-01-01 00:00:00 UTC"),
      ("-1", "1969-12-31 23:59:59 UTC"),
      ("-2208988800", "1900-01-01 00:00:00 UTC"),
      ("253402300799", "9999-12-31 23:59:59 UTC"),
    ] {
      XCTAssertEqual(Calculator.calculate("\(seconds) to UTC")?.value, date)
      XCTAssertEqual(Calculator.calculate("\(date) to unix")?.value, seconds)
    }
    XCTAssertEqual(Calculator.calculate("2024-01-01 00:00 UTC to unix")?.value, "1704067200")
    XCTAssertEqual(Calculator.calculate("2024-02-29 12:34:56 utc в UNIX")?.value, "1709210096")
  }

  func testUnixQueryLengthLimit() {
    for (prefix, suffix, expected) in [
      ("0", "to UTC", "1970-01-01 00:00:00 UTC"),
      ("1970-01-01", "00:00 UTC to unix", "0"),
    ] {
      let padding = String(repeating: " ", count: 512 - prefix.count - suffix.count)
      XCTAssertEqual(Calculator.calculate(prefix + padding + suffix)?.value, expected)
      let overlong = Calculator.calculate(prefix + padding + " " + suffix)
      XCTAssertEqual(overlong?.status, .error)
      XCTAssertEqual(overlong?.message, localized("Expression is too long"))
    }
    let longSeconds = Calculator.calculate(String(repeating: "0", count: 513) + " to UTC")
    XCTAssertEqual(longSeconds?.status, .error)
  }

  func testRejectsInvalidAndAmbiguousConversions() {
    for query in [
      "12.5 to hex", "0x+FF to dec", "FF to dec", "1 000 to bin", "0xFF",
      "2024-01-01 00:00 to unix", "00:00 UTC to unix", "2024-01-01 00:00 London to unix",
      "2024-01-01 00:00 UTC+01:00 to unix", "2024-01-01 00:00 GMT to unix",
      "2023-02-29 00:00 UTC to unix", "2024-01-01 24:00 UTC to unix",
      "2024-01-01 00:60 UTC to unix", "2024-01-01 00:00:60 UTC to unix",
      "1704067200.5 to UTC", "1704067200000 to UTC", "0xFF to UTC",
      "-2208988801 to UTC", "253402300800 to UTC", "9223372036854775808 to UTC",
    ] {
      XCTAssertNil(Calculator.calculate(query)?.value, query)
    }
  }
}
