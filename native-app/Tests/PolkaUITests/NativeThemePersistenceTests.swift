import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeThemePersistenceTests: XCTestCase {
  func testCatalogHasUniqueThemesWithValidColors() {
    let categories = NativeThemeCategory.allCases
    XCTAssertEqual(categories.map { $0.themes.count }, [8, 8, 8, 8])
    let themes = categories.flatMap(\.themes)
    XCTAssertEqual(Set(themes.map(\.id)).count, themes.count)
    XCTAssertTrue(themes.allSatisfy { $0.colors.isValid })
    for theme in themes {
      XCTAssertGreaterThanOrEqual(theme.colors.textContrastRatio, 4.5, theme.name)
    }
    XCTAssertEqual(NativeThemeSettings().active, NativeThemeSettings.standard)
  }

  @MainActor func testThemeShortcutsRespectScopeAndFinishAcrossShelfNavigation() async {
    let model = NativeUIModel()
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    var edit = NativeKeyInput(code: 14, characters: "у", modifiers: .command, isSettings: true)
    XCTAssertFalse(model.handleKeyboard(edit))
    model.settingsPane = "themes"
    edit.composing = true
    XCTAssertFalse(model.handleKeyboard(edit))
    XCTAssertNil(model.themeDraft)
    edit.composing = false
    XCTAssertTrue(model.handleKeyboard(edit))
    model.themeDraft?.name = "Graphite"
    let duplicateSave = NativeKeyInput(
      code: 1, characters: "ы", modifiers: .command, isSettings: true)
    XCTAssertTrue(model.handleKeyboard(duplicateSave))
    XCTAssertFalse(model.commandPending)
    model.themeDraft?.name = "Preserved custom theme"

    var save = NativeKeyInput(
      code: 1, characters: "ы", modifiers: .command, repeatKey: true, isSettings: true)
    XCTAssertTrue(model.handleKeyboard(save))
    XCTAssertTrue(commands.isEmpty)
    XCTAssertFalse(model.commandPending)
    save.repeatKey = false
    XCTAssertTrue(model.handleKeyboard(save))
    model.present(destination: "apps")
    for _ in 0..<20 where model.commandPending { await Task.yield() }
    XCTAssertEqual(commands.first?.strings["name"], "Preserved custom theme")
    XCTAssertEqual(commands.map(\.name), ["theme.save"])
    XCTAssertNil(model.themeDraft)
    XCTAssertEqual(model.themeFilter, .custom)
  }

  @MainActor func testCustomThemeLifecycleSurvivesReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-theme-\(UUID())")
    defer {
      AppLocalization.configure(.system)
      try? FileManager.default.removeItem(at: root)
    }
    let original = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    addTeardownBlock { await original.shutdown() }
    XCTAssertEqual(original.model.settings.themes.activeID, "polka")
    try await original.handle(NativeUICommand("theme.select", strings: ["id": "midnight"]))
    XCTAssertEqual(original.model.settings.themes.activeID, "midnight")

    try await original.handle(saveTheme(name: "  Ember  "))
    let saved = try XCTUnwrap(original.model.settings.themes.custom.first)
    XCTAssertEqual(original.model.settings.themes.active, saved)
    XCTAssertEqual(saved.name, "Ember")
    XCTAssertEqual(saved.colors.accent, "#FFB08A")
    try await original.handle(
      saveTheme(id: saved.id, name: "Midnight Ember", selection: "#A2483E"))
    let renamed = original.model.settings.themes.active
    XCTAssertEqual(renamed.id, saved.id)
    XCTAssertEqual(renamed.name, "Midnight Ember")
    XCTAssertEqual(renamed.colors.selection, "#A2483E")
    try await original.handle(NativeUICommand("theme.duplicate", strings: ["id": saved.id]))
    try await original.handle(NativeUICommand("theme.duplicate", strings: ["id": saved.id]))
    let beforeReopen = original.model.settings.themes
    XCTAssertEqual(Set(beforeReopen.custom.map(\.name)).count, 3)
    XCTAssertNotEqual(beforeReopen.active.id, saved.id)
    XCTAssertEqual(beforeReopen.active.colors, renamed.colors)

    let reopened = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    addTeardownBlock { await reopened.shutdown() }
    XCTAssertEqual(reopened.model.settings.themes, beforeReopen)
    try await reopened.handle(NativeUICommand("theme.delete", strings: ["id": saved.id]))
    XCTAssertEqual(reopened.model.settings.themes.active, beforeReopen.active)
    try await reopened.handle(
      NativeUICommand("theme.delete", strings: ["id": beforeReopen.activeID]))
    XCTAssertEqual(reopened.model.settings.themes.activeID, "polka")
    XCTAssertEqual(reopened.model.settings.themes.custom.count, 1)
  }

  @MainActor func testInvalidRequestsAndFailedWritesKeepActiveThemeAndLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-theme-\(UUID())")
    defer {
      AppLocalization.configure(.system)
      try? FileManager.default.removeItem(at: root)
    }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    addTeardownBlock { await platform.shutdown() }
    try await platform.handle(saveTheme(name: "Ember"))
    let beforeFailure = platform.model.settings.themes
    for invalid in [
      saveTheme(name: "ember"), saveTheme(name: "Dracula"), saveTheme(name: " "),
      saveTheme(name: "Invalid", selection: "#000Z00"),
      saveTheme(id: "polka", name: "New Polka"),
      NativeUICommand("theme.select", strings: ["id": "missing"]),
      NativeUICommand("theme.delete", strings: ["id": "polka"]),
    ] {
      do {
        try await platform.handle(invalid)
        XCTFail("Expected \(invalid.name) to fail")
      } catch {}
      XCTAssertEqual(platform.model.settings.themes, beforeFailure)
    }

    platform.settings.close()
    do {
      try await platform.handle(NativeUICommand("theme.select", strings: ["id": "polka"]))
      XCTFail("Expected a failed settings write")
    } catch {}
    XCTAssertEqual(platform.model.settings.themes, beforeFailure)
    let reopened = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    addTeardownBlock { await reopened.shutdown() }
    XCTAssertEqual(reopened.model.settings.themes, beforeFailure)
  }

  @MainActor func testExistingCustomThemeCanKeepANameAddedToTheCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-theme-\(UUID())")
    defer {
      AppLocalization.configure(.system)
      try? FileManager.default.removeItem(at: root)
    }
    let legacy = NativeShelfTheme(
      id: UUID().uuidString, name: "Dracula", colors: NativeThemeSettings.standard.colors)
    let saved = NativeThemeSettings(activeID: legacy.id, custom: [legacy])
    let store = try SettingsStore(root: root)
    try store.set(
      key: NativeThemeSettings.settingsKey,
      value: JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)))
    store.close()

    let model = NativeUIModel()
    let platform = try NativePlatform(model: model, root: root, fixture: true)
    addTeardownBlock { await platform.shutdown() }
    XCTAssertEqual(model.settings.themes.active, legacy)
    model.editTheme()
    let draft = try XCTUnwrap(model.themeDraft)
    XCTAssertTrue(draft.canSave(in: model.settings.themes))
    try await platform.handle(saveTheme(id: legacy.id, name: legacy.name, selection: "#A2483E"))
    XCTAssertEqual(model.settings.themes.active.id, legacy.id)
    XCTAssertEqual(model.settings.themes.active.name, legacy.name)
    XCTAssertEqual(model.settings.themes.active.colors.selection, "#A2483E")
    XCTAssertEqual(model.settings.themes.theme(id: "dracula")?.name, legacy.name)
  }

  private func saveTheme(id: String = "", name: String, selection: String = "#B55042")
    -> NativeUICommand
  {
    NativeUICommand(
      "theme.save",
      strings: [
        "id": id, "name": name, "background": "#21174B", "surface": "#30245E",
        "text": "#FBF5FF", "accent": " ffb08a ", "selection": selection,
      ])
  }
}
