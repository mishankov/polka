import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeLanguageTests: XCTestCase {
  @MainActor func testOverridePersistsAndRefreshesWithoutLosingDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-language-\(UUID())")
    defer {
      AppLocalization.configure(.system)
      try? FileManager.default.removeItem(at: root)
    }
    let model = NativeUIModel()
    let platform = try NativePlatform(model: model, root: root, fixture: true)
    addTeardownBlock { await platform.shutdown() }
    model.settingsPane = "general"
    model.query = "unsaved search"
    model.pairingCode = "unsaved code"
    model.draft = NativeSnippetDraft(name: "Название", content: "Draft stays intact")
    var changes = 0
    platform.languageChanged = { changes += 1 }
    try await platform.handle(NativeUICommand("settings.language", strings: ["value": "ru"]))
    XCTAssertEqual(model.settings.language, .russian)
    XCTAssertEqual(nativeSettingsPanes.first?.label, "Основные")
    try await platform.handle(NativeUICommand("settings.language", strings: ["value": "en"]))
    XCTAssertEqual(model.settings.language, .english)
    XCTAssertEqual(model.settings.languagePreference, .english)
    XCTAssertEqual(nativeSettingsPanes.first?.label, "General")
    XCTAssertEqual(model.query, "unsaved search")
    XCTAssertEqual(model.pairingCode, "unsaved code")
    XCTAssertEqual(model.draft?.name, "Название")
    XCTAssertEqual(model.draft?.content, "Draft stays intact")
    XCTAssertGreaterThanOrEqual(changes, 1)
    XCTAssertEqual(
      try platform.settings.get(key: AppLanguagePreference.settingsKey) as? String, "en")
    let reopened = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    addTeardownBlock { await reopened.shutdown() }
    XCTAssertEqual(reopened.model.settings.languagePreference, .english)
    reopened.updateSystemLanguage(preferredLanguages: ["ru-RU"])
    XCTAssertEqual(reopened.model.settings.language, .english)
    try await reopened.handle(NativeUICommand("settings.language", strings: ["value": "system"]))
    reopened.updateSystemLanguage(preferredLanguages: ["ru-RU"])
    XCTAssertEqual(reopened.model.settings.language, .russian)
    reopened.updateSystemLanguage(preferredLanguages: ["de-DE", "ru"])
    XCTAssertEqual(reopened.model.settings.language, .english)
  }

  @MainActor func testInvalidOrFailedWriteKeepsExistingLanguage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-language-failure-\(UUID())")
    defer {
      AppLocalization.configure(.system)
      try? FileManager.default.removeItem(at: root)
    }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    addTeardownBlock { await platform.shutdown() }
    try await platform.handle(NativeUICommand("settings.language", strings: ["value": "ru"]))
    for value in ["invalid", "en"] {
      if value == "en" { platform.settings.close() }
      do {
        try await platform.handle(NativeUICommand("settings.language", strings: ["value": value]))
        XCTFail("Expected a failed setting write")
      } catch {}
      XCTAssertEqual(platform.model.settings.languagePreference, .russian)
      XCTAssertEqual(AppLocalization.language, .russian)
    }
  }

  @MainActor func testLanguageChoiceSharesGuardedActionAndSettingsShortcut() async {
    _ = NSApplication.shared
    let model = NativeUIModel()
    model.storageStatus = "ready"
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    let control = NativeLanguagePopUp(frame: .zero, pullsDown: false)
    control.addItems(withTitles: ["System", "English", "Русский"])
    control.changeValue = { model.setLanguage($0) }
    control.selectItem(at: 2)
    control.change()
    for _ in 0..<100 where model.commandPending { await Task.yield() }
    XCTAssertEqual(commands.last?.name, "settings.language")
    XCTAssertEqual(commands.last?.strings["value"], "ru")
    model.busy = true
    control.selectItem(at: 1)
    control.change()
    XCTAssertEqual(commands.count, 1)
    model.busy = false
    XCTAssertFalse(
      model.handleKeyboard(
        NativeKeyInput(code: 43, characters: "б", modifiers: .command, composing: true)))
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 43, characters: "б", modifiers: .command)))
    for _ in 0..<100 where model.commandPending { await Task.yield() }
    XCTAssertEqual(commands.last?.name, "shelf.settings")
  }
}
