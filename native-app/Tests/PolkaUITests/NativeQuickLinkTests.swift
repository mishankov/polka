import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeQuickLinkTests: XCTestCase {
  @MainActor func testShelfSelectionResetsWithSearchAndKeepsNeighborAfterDeletion() async throws {
    let model = NativeUIModel()
    let alpha = try QuickLink(name: "Team Alpha", url: "https://example.invalid/alpha")
    let beta = try QuickLink(name: "Team Beta", url: "https://example.invalid/beta")
    let gamma = try QuickLink(name: "Team Gamma", url: "https://example.invalid/gamma")
    model.quickLinks = [alpha, beta, gamma]
    model.present(destination: "quick-links")
    var openedID: String?
    model.action = { [weak model] command in
      switch command.name {
      case "quickLinks.open": openedID = command.strings["id"]
      case "quickLinks.delete":
        model?.quickLinks.removeAll { $0.id.uuidString == command.strings["id"] }
      default: XCTFail("Unexpected command \(command.name)")
      }
    }
    func waitForCommand() async {
      for _ in 0..<100 where model.commandPending { await Task.yield() }
      XCTAssertFalse(model.commandPending)
    }

    model.selectedQuickLinkID = gamma.id
    model.query = "Alpha"
    model.query = "Team"
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: [])))
    await waitForCommand()
    XCTAssertEqual(openedID, alpha.resultID)

    model.selectedQuickLinkID = beta.id
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 51, characters: "", modifiers: .command)))
    await waitForCommand()
    XCTAssertEqual(model.quickLinkResults, [alpha, gamma])
    XCTAssertEqual(model.selectedQuickLink?.id, gamma.id)
  }

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
    for enabled in [false, true] {
      try await reopened.handle(
        NativeUICommand(
          "builtinApps.setEnabled", strings: ["id": "builtin:quick-links"],
          bools: ["enabled": enabled]))
      XCTAssertEqual(reopened.model.searchResults.contains(row), enabled)
      XCTAssertEqual(reopened.model.quickLinks, [saved])
    }

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
