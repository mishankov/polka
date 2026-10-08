import AppKit
import XCTest

@testable import PolkaApp

final class NativeKeyboardTests: XCTestCase {
  @MainActor func testSnippetKeyboardPreservesDraftAndUsesSaveAction() async throws {
    let model = NativeUIModel()
    model.storageStatus = "ready"
    model.present(destination: "snippets")
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 45, characters: "т", modifiers: .command)))
    XCTAssertNotNil(model.draft)
    model.draft?.name = "Адрес"
    model.draft?.content = "Москва"
    model.conceal()
    model.present(destination: "snippets", resume: true)
    XCTAssertEqual(model.draft?.content, "Москва")
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: .command)))
    for _ in 0..<10 where commands.isEmpty { await Task.yield() }
    XCTAssertEqual(commands.first?.name, "clipboardHistory.createSnippet")
    XCTAssertEqual(commands.first?.strings["name"], "Адрес")
    XCTAssertEqual(commands.first?.strings["content"], "Москва")
    XCTAssertNil(model.draft)
  }
  @MainActor func testCompositionRepeatsBusyAndNormalEditingDoNotDispatch() async {
    let model = NativeUIModel()
    model.storageStatus = "ready"
    model.present(destination: "snippets")
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    XCTAssertFalse(
      model.handleKeyboard(
        NativeKeyInput(code: 45, characters: "n", modifiers: .command, composing: true)))
    XCTAssertNil(model.draft)
    XCTAssertTrue(
      model.handleKeyboard(
        NativeKeyInput(code: 45, characters: "n", modifiers: .command, repeatKey: true)))
    XCTAssertNil(model.draft)
    XCTAssertFalse(
      model.handleKeyboard(NativeKeyInput(code: 51, characters: "", modifiers: [], editing: true)))
    model.busy = true
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 45, characters: "n", modifiers: .command)))
    XCTAssertNil(model.draft)
    await Task.yield()
    XCTAssertTrue(commands.isEmpty)
  }
  @MainActor func testFreshEntryAndExpiredContextResetBrowseButKeepEditor() {
    let model = NativeUIModel()
    model.storageStatus = "ready"
    let now = Date(timeIntervalSince1970: 100)
    model.present(destination: "clipboard", now: now)
    model.query = "needle"
    model.selectedID = "id"
    model.saveContext(now: now)
    model.present(destination: "apps", now: now)
    model.present(destination: "clipboard", resume: true, now: now.addingTimeInterval(61))
    XCTAssertEqual(model.query, "")
    XCTAssertNil(model.selectedID)
    model.present(destination: "snippets", now: now)
    model.createSnippet()
    model.draft?.content = "unsaved"
    model.present(destination: "apps", now: now)
    model.present(destination: "snippets", now: now.addingTimeInterval(90))
    XCTAssertEqual(model.draft?.content, "unsaved")
  }
  @MainActor func testReopeningHiddenBuiltinDoesNotRefreshExpiredContext() {
    let model = NativeUIModel()
    let start = Date(timeIntervalSince1970: 100)
    model.present(destination: "clipboard", now: start)
    model.query = "old query"
    model.conceal(now: start)
    model.present(destination: "clipboard", resume: true, now: start.addingTimeInterval(61))
    XCTAssertEqual(model.query, "")
  }
  @MainActor func testPreviewEscapeReturnsToListAndDoesNotHide() async {
    let model = NativeUIModel()
    model.storageStatus = "ready"
    model.present(destination: "clipboard")
    model.clips = [NativeUIClip(id: "c", content: "Preview")]
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    model.openPreview(model.clips[0])
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [])))
    XCTAssertNil(model.previewID)
    XCTAssertTrue(model.visible)
    await Task.yield()
    XCTAssertTrue(commands.isEmpty)
  }
  @MainActor func testSearchEditingKeepsCommandBackspaceAndRepeatedDigits() {
    let model = NativeUIModel()
    model.storageStatus = "ready"
    model.present(destination: "clipboard")
    model.query = "query"
    model.clips = [NativeUIClip(id: "c", content: "text")]
    XCTAssertFalse(
      model.handleKeyboard(
        NativeKeyInput(
          code: 51, characters: "", modifiers: .command, editing: true, searchEditing: true)))
    XCTAssertFalse(
      model.handleKeyboard(
        NativeKeyInput(
          code: 18, characters: "1", modifiers: [], repeatKey: true, editing: true,
          searchEditing: true)))
  }
  @MainActor func testDeleteRequiresWritableAndHistoryClearRequiresConfirmation() async {
    let model = NativeUIModel()
    model.present(destination: "clipboard")
    model.clips = [NativeUIClip(id: "clip", content: "text")]
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 51, characters: "", modifiers: .command)))
    await Task.yield()
    XCTAssertTrue(commands.isEmpty)
    model.storageStatus = "ready"
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 51, characters: "", modifiers: [.command, .shift])))
    XCTAssertTrue(model.confirmClear)
    XCTAssertTrue(commands.isEmpty)
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: .command)))
    for _ in 0..<10 where commands.isEmpty { await Task.yield() }
    XCTAssertEqual(commands.first?.name, "clipboardHistory.clear")
    XCTAssertFalse(model.confirmClear)
  }
  @MainActor func testPreviewNumbersTransformWithoutChangingStoredText() {
    let model = NativeUIModel()
    model.storageStatus = "ready"
    model.present(destination: "clipboard")
    model.clips = [NativeUIClip(id: "c", content: "Привет", preview: "Привет")]
    model.openPreview(model.clips[0])
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 18, characters: "1", modifiers: .command)))
    XCTAssertEqual(model.previewText, "ПРИВЕТ")
    XCTAssertEqual(model.clips[0].content, "Привет")
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 20, characters: "3", modifiers: .command)))
    XCTAssertEqual(model.previewText, "Привет")
  }
  @MainActor func testFileMultiSelectionRangeAndToggle() {
    let model = NativeUIModel()
    model.files = (0..<4).map {
      NativeUIFile(id: "\($0)", name: "File \($0)", path: "/synthetic/\($0)")
    }
    model.selectFile("1", modifiers: [])
    model.selectFile("3", modifiers: .shift)
    XCTAssertEqual(model.selectedFiles, ["1", "2", "3"])
    model.selectFile("2", modifiers: .command)
    XCTAssertEqual(model.selectedFiles, ["1", "3"])
  }
  @MainActor func testImageSaveCommandWorksBeyondIndexedRowsAndRespectsPreviewGuards() async {
    let model = NativeUIModel()
    model.present(destination: "clipboard")
    model.clips =
      [NativeUIClip(id: "text", content: "Text")]
      + (0..<11).map { NativeUIClip(id: "image\($0)", kind: "image", content: "synthetic") }
    model.selectedID = "image10"
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    let save = NativeKeyInput(code: 1, characters: "ы", modifiers: .command)
    XCTAssertTrue(model.handleKeyboard(save))
    for _ in 0..<20 where model.busy { await Task.yield() }
    XCTAssertEqual(commands.last?.name, "clipboardHistory.saveImage")
    XCTAssertEqual(commands.last?.strings["id"], "image10")
    model.previewID = "image0"
    XCTAssertTrue(model.handleKeyboard(save))
    for _ in 0..<20 where model.busy { await Task.yield() }
    XCTAssertEqual(commands.last?.strings["id"], "image0")
    let count = commands.count
    model.busy = true
    XCTAssertTrue(model.handleKeyboard(save))
    model.secondaryClipAction(model.clips[1])
    model.busy = false
    XCTAssertTrue(
      model.handleKeyboard(
        NativeKeyInput(code: 1, characters: "ы", modifiers: .command, repeatKey: true)))
    XCTAssertFalse(
      model.handleKeyboard(
        NativeKeyInput(code: 1, characters: "ы", modifiers: .command, composing: true)))
    model.previewID = "text"
    XCTAssertFalse(model.handleKeyboard(save))
    model.previewID = nil
    model.confirmClear = true
    XCTAssertFalse(model.handleKeyboard(save))
    model.confirmClear = false
    model.draft = NativeSnippetDraft(content: "unsaved")
    XCTAssertFalse(model.handleKeyboard(save))
    XCTAssertEqual(model.draft?.content, "unsaved")
    model.draft = nil
    model.conceal()
    model.secondaryClipAction(model.clips[1])
    await Task.yield()
    XCTAssertEqual(commands.count, count)
  }
  @MainActor func testUpdateInstallShortcutUsesSameCommandAndIsScopedToVisibleNotice() async {
    let model = NativeUIModel()
    model.present(destination: "apps")
    model.settings.updateStatus = "ready"
    model.settings.updateNotification = "visible"
    model.settings.updateVersion = "0.2.0"
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    model.query = "search"
    XCTAssertFalse(
      model.handleKeyboard(
        NativeKeyInput(code: 32, characters: "г", modifiers: [.command, .shift])))
    model.query = ""
    XCTAssertTrue(
      model.handleKeyboard(
        NativeKeyInput(code: 32, characters: "г", modifiers: [.command, .shift])))
    for _ in 0..<10 where commands.isEmpty { await Task.yield() }
    XCTAssertEqual(commands.first?.name, "updates.install")
    XCTAssertEqual(commands.first?.strings["version"], "0.2.0")
  }
  func testReleaseNoteLanguagesPreservePlainTextAndMissingFallbacks() {
    var settings = NativeUISettings()
    XCTAssertEqual(
      nativeReleaseNoteText(settings, language: "en"),
      "Release notes have not been published for this version.")
    settings.updateNotesRussian = "Новая полка <script>пример</script>"
    settings.updateNotesEnglish = "A new shelf & literal text"
    XCTAssertEqual(nativeReleaseNoteText(settings, language: "ru"), settings.updateNotesRussian)
    XCTAssertEqual(nativeReleaseNoteText(settings, language: "en"), settings.updateNotesEnglish)
  }
  func testTextFieldLimitsUseUTF16WithoutSplittingSurrogatePairs() {
    XCTAssertEqual(nativeLimitedText("😀😀A", utf16Limit: 3), "😀")
    XCTAssertEqual(nativeLimitedText("😀A", utf16Limit: 3), "😀A")
    XCTAssertEqual(
      nativeLimitedText(String(repeating: "😀", count: 100), utf16Limit: 120).utf16.count, 120)
  }
  func testWholeWebURLValidation() {
    XCTAssertNotNil(nativeWebURL(" https://example.com/a?q=1 "))
    XCTAssertNil(nativeWebURL("visit https://example.com"))
    XCTAssertNil(nativeWebURL("https://user:pass@example.com"))
    XCTAssertNil(nativeWebURL("file:///tmp/test"))
    XCTAssertNil(nativeWebURL("https://example.com\\unsafe"))
  }
}
