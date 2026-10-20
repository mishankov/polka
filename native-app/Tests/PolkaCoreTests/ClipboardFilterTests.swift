import XCTest

@testable import PolkaCore

final class ClipboardFilterTests: XCTestCase {
  func testTypesComposeWithSearchOCRAndPinnedOrderingWithoutChangingRecords() {
    func clip(
      _ id: String, _ content: String, kind: ClipboardClip.Kind = .text,
      pinned: Bool = false, time: Double = 0, ocr: String = ""
    ) -> ClipboardClip {
      ClipboardClip(
        id: id, kind: kind, content: content, preview: content, createdAt: time,
        pinned: pinned, ocr: ImageText(version: "1", status: .ready, text: ocr, languages: []))
    }
    let records = [
      clip("plain", "Needle in prose", time: 10),
      clip("link", " https://example.com/needle\r\n", time: 9),
      clip("code", "{\"needle\": \"e\u{301} 👩🏽‍💻\"}\r\n", time: 8),
      clip("color", "#abcdef", pinned: true),
      clip("image", "synthetic image", kind: .image, time: 11, ocr: "Needle from OCR"),
      clip("ambiguous", "The color #abcdef and https://example.com/needle are examples.", time: 7),
    ]
    let expected: [ClipboardFilter: [String]] = [
      .all: ["color", "image", "plain", "link", "code", "ambiguous"],
      .text: ["color", "plain", "link", "code", "ambiguous"],
      .images: ["image"], .links: ["link"], .colors: ["color"], .files: [],
    ]
    for filter in ClipboardFilter.allCases {
      XCTAssertEqual(
        clipboardResults(records, query: "", filter: filter).map(\.id), expected[filter])
      let matches = clipboardResults(records, query: "  NeEdLe\u{FEFF} ", filter: filter)
      XCTAssertEqual(matches.map(\.id), expected[filter]?.filter { $0 != "color" })
      XCTAssertTrue(clipboardResults(records, query: "missing", filter: filter).isEmpty)
      for match in matches {
        XCTAssertEqual(match, records.first { $0.id == match.id })
      }
    }
    XCTAssertEqual(
      clipboardResults(records, query: "needle OCR", filter: .images).map(\.id), ["image"])
    XCTAssertTrue(clipboardResults(records, query: "prose", filter: .images).isEmpty)
    XCTAssertEqual(clipboardResults(records, query: "abcdef", filter: .colors).map(\.id), ["color"])
  }

  func testStructuredContentStaysTextAndDerivedFiltersRequireWholeValues() {
    XCTAssertEqual(ClipboardFilter.allCases, [.all, .text, .images, .links, .colors, .files])
    for value in ["#abc8", "rgba(0, 2, 3, 0.5)", "hsl(120 50% 25%)"] {
      XCTAssertTrue(ClipboardFilter.colors.matches(kind: .text, content: value), value)
      XCTAssertFalse(ClipboardFilter.colors.matches(kind: .image, content: value), value)
    }
    XCTAssertTrue(ClipboardFilter.links.matches(kind: .text, content: "https://example.com/a?q=1"))
    XCTAssertFalse(ClipboardFilter.links.matches(kind: .image, content: "https://example.com"))
    for value in [
      "{\"enabled\":true}", "[1, 2, 3]", "function hello() { return 1; }",
      "const value: number = 42;", "def hello():\n    return 1", "#!/bin/sh\necho hello",
      "<p>hello</p>", ".hello { color: red; }", "name: Alice\nage: 30", "name = Alice",
      "Please use #abc", "visit https://example.com", "https://user:pass@example.com",
      "https://example.com\\unsafe", "file:///tmp/test", String(repeating: "x", count: 1_048_500),
    ] {
      XCTAssertTrue(ClipboardFilter.text.matches(kind: .text, content: value))
      XCTAssertFalse(ClipboardFilter.links.matches(kind: .text, content: value))
      XCTAssertFalse(ClipboardFilter.colors.matches(kind: .text, content: value))
    }
  }
}
