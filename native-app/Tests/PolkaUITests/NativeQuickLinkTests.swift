import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeQuickLinkTests: XCTestCase {
  @MainActor func testQuickLinksPersistAndRefreshShelfSearchAfterWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-quick-links-\(UUID())")
    defer {
      AppLocalization.configure(.system)
      try? FileManager.default.removeItem(at: root)
    }
    let model = NativeUIModel()
    let platform = try NativePlatform(model: model, root: root, fixture: true)
    addTeardownBlock { await platform.shutdown() }
    let name = "Snippets Guide"
    model.query = name
    XCTAssertFalse(model.searchResults.contains { $0.kind == "quick-link" })

    try await platform.handle(
      NativeUICommand(
        "quickLinks.save",
        strings: [
          "name": name,
          "url": "x-apple.systempreferences:com.apple.preference.keyboard",
        ]))
    let saved = try XCTUnwrap(model.quickLinks.first)
    let row = try XCTUnwrap(model.searchResults.first { $0.kind == "quick-link" })
    XCTAssertEqual(row.title, saved.name)
    XCTAssertEqual(row.detail, saved.url.absoluteString)
    XCTAssertEqual(model.selectedSearch, row)
    model.query = "Snippets"
    XCTAssertEqual(model.selectedSearch?.id, "builtin:snippets")
    XCTAssertTrue(model.searchResults.contains(row))
    await platform.shutdown()

    let reopened = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    addTeardownBlock { await reopened.shutdown() }
    reopened.model.query = name
    XCTAssertEqual(reopened.model.quickLinks, [saved])
    XCTAssertEqual(reopened.model.searchResults.first { $0.kind == "quick-link" }, row)

    try await reopened.handle(
      NativeUICommand(
        "quickLinks.delete",
        strings: [
          "id": saved.id.uuidString
        ]))
    XCTAssertFalse(reopened.model.searchResults.contains { $0.kind == "quick-link" })

    for (title, url) in [
      ("Все", "test-app:without-yo"), ("Всё", "test-app:with-yo"),
      ("Maß", "test-app:measurement"), ("Mass Transit", "test-app:transit"),
      ("1+1", "test-app:arithmetic"),
    ] {
      try await reopened.handle(
        NativeUICommand(
          "quickLinks.save",
          strings: [
            "name": title, "url": url,
          ]))
    }
    reopened.model.query = "всё"
    XCTAssertEqual(reopened.model.selectedSearch?.detail, "test-app:with-yo")
    reopened.model.query = "MASS"
    XCTAssertEqual(reopened.model.selectedSearch?.detail, "test-app:measurement")
    reopened.model.query = "1+1"
    XCTAssertEqual(reopened.model.selectedSearch?.detail, "test-app:arithmetic")
    XCTAssertTrue(reopened.model.searchResults.contains { $0.kind == "calculation" })
  }
}
