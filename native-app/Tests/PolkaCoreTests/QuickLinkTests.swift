import XCTest

@testable import PolkaCore

final class QuickLinkTests: XCTestCase {
  func testTrimsAndPreservesSavedLinksAcrossCoding() throws {
    let web = try QuickLink(name: "  Team Calendar\n", url: " HTTPS://example.org/today?q=a%20b\n")
    let app = try QuickLink(
      name: "Settings", url: "x-apple.systempreferences:com.apple.WiFiSettings")
    XCTAssertEqual(web.name, "Team Calendar")
    XCTAssertEqual(web.url.absoluteString, "HTTPS://example.org/today?q=a%20b")
    XCTAssertEqual(app.url.scheme, "x-apple.systempreferences")
    XCTAssertEqual(
      try JSONDecoder().decode([QuickLink].self, from: JSONEncoder().encode([web, app])),
      [web, app])
  }

  func testValidatesInternationalURLsWithoutRepairingMalformedInput() throws {
    let link = try QuickLink(name: "Документы", url: "https://пример.рф/документы")
    XCTAssertEqual(link.url, URL(string: "https://пример.рф/документы"))
    XCTAssertEqual(link.url.path(percentEncoded: false), "/документы")
    XCTAssertNoThrow(try QuickLink(name: "Local IPv6", url: "https://[::1]:65535"))

    for url in [
      "", "example.org", "/relative", "https://", "https:example.org", "https://a%20b.example",
      "https://staging.example.org:65536", "https://example.org:99999999999999999999",
      "https://[foo]",
      "https://example.org/one two", "https://example.org/путь%zz", "https://example.org/a\\b",
      "file:///tmp/example", "data:text/plain,test", "JavaScript:alert(1)",
    ] {
      XCTAssertThrowsError(try QuickLink(name: "Example", url: url), url) {
        XCTAssertEqual($0 as? QuickLink.ValidationError, .invalidURL)
      }
    }
    XCTAssertThrowsError(try QuickLink(name: " \n", url: "https://example.org")) {
      XCTAssertEqual($0 as? QuickLink.ValidationError, .emptyName)
    }
  }
}
