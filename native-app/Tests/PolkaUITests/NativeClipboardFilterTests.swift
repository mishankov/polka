import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeClipboardFilterTests: XCTestCase {
  @MainActor private func model() -> NativeUIModel {
    let model = NativeUIModel()
    model.present(destination: "clipboard")
    model.storageStatus = "ready"
    model.clips = [
      NativeUIClip(id: "hidden", content: "plain prose", createdAt: 40),
      NativeUIClip(id: "a", content: "https://example.com/a", createdAt: 30),
      NativeUIClip(id: "b", content: "https://example.com/b", createdAt: 20),
      NativeUIClip(id: "c", content: "https://example.com/c", createdAt: 10),
      NativeUIClip(id: "image", kind: "image", ocrText: "needle OCR"),
    ]
    return model
  }

  @MainActor func testFilterChangesPreserveQueryAndVisibleSelectionAndResetEmptyResults() {
    let model = model()
    model.query = "example.com"
    model.selectedID = "b"
    model.chooseClipboardFilter(.links)
    XCTAssertEqual(model.selectedClip?.id, "b")
    XCTAssertEqual(model.query, "example.com")
    model.chooseClipboardFilter(.colors)
    XCTAssertTrue(model.clipResults.isEmpty)
    XCTAssertNil(model.selectedID)
    XCTAssertNil(model.selectedClip)
    model.chooseClipboardFilter(.all)
    XCTAssertEqual(model.query, "example.com")
    XCTAssertEqual(model.clipResults.map(\.id), ["a", "b", "c"])
    XCTAssertTrue(
      model.handleKeyboard(
        NativeKeyInput(code: 23, characters: "5", modifiers: [.command, .control])))
    XCTAssertEqual(model.clipboardFilter, .colors)
    XCTAssertFalse(
      model.handleKeyboard(
        NativeKeyInput(code: 22, characters: "6", modifiers: [.command, .control])))
    model.query = "needle"
    model.chooseClipboardFilter(.images)
    XCTAssertEqual(model.clipResults.map(\.id), ["image"])
    model.snippets = [NativeUIClip(id: "snippet", content: "needle", snippet: true)]
    model.present(destination: "snippets")
    XCTAssertEqual(model.clipResults.map(\.id), ["snippet"])
  }

  @MainActor func testPinDeletionSyncAndRetentionReconcileVisibleSelection() {
    let model = model()
    model.chooseClipboardFilter(.links)
    model.selectedID = "b"
    model.clips[3].pinned = true
    XCTAssertEqual(model.clipResults.map(\.id), ["c", "a", "b"])
    XCTAssertEqual(model.selectedID, "b")
    model.clips.removeAll { $0.id == "b" }
    XCTAssertEqual(model.selectedID, "a")
    model.clips[1].content = "Remote edit is no longer a link"
    XCTAssertEqual(model.clipResults.map(\.id), ["c"])
    XCTAssertEqual(model.selectedID, "c")
    model.openPreview(model.selectedClip!)
    model.clips.removeAll { $0.id == "c" }
    XCTAssertTrue(model.clipResults.isEmpty)
    XCTAssertNil(model.selectedID)
    XCTAssertNil(model.previewID)
    model.clips.append(NativeUIClip(id: "new", content: "https://example.com/new"))
    XCTAssertEqual(model.selectedClip?.id, "new")
  }

  @MainActor func testPreviewBackAndBriefResumePreserveFilterQuerySelectionAndScroll() {
    let model = model()
    let now = Date(timeIntervalSince1970: 100)
    model.query = "example"
    model.chooseClipboardFilter(.links)
    model.selectedID = "b"
    model.listScrollOffset = 120
    model.openPreview(model.selectedClip!)
    model.previewScrollOffset = 40
    model.conceal(now: now)
    model.present(destination: "clipboard", resume: true, now: now.addingTimeInterval(2))
    XCTAssertEqual(model.clipboardFilter, .links)
    XCTAssertEqual(model.query, "example")
    XCTAssertEqual(model.selectedID, "b")
    XCTAssertEqual(model.previewID, "b")
    XCTAssertEqual(model.previewScrollOffset, 40)
    model.back()
    XCTAssertEqual(model.listScrollOffset, 120)
    XCTAssertEqual(model.selectedID, "b")
    XCTAssertEqual(model.clipboardFilter, .links)
    model.conceal(now: now)
    model.present(destination: "clipboard", resume: true, now: now.addingTimeInterval(61))
    XCTAssertEqual(model.clipboardFilter, .all)
    XCTAssertEqual(model.query, "")
    model.chooseClipboardFilter(.links)
    model.present(destination: "clipboard", searchQuery: "incoming")
    XCTAssertEqual(model.clipboardFilter, .all)
    XCTAssertEqual(model.query, "incoming")
  }

  @MainActor func testResumeDropsPreviewAndSelectionThatNoLongerMatchAfterOCRUpdate() {
    let model = model()
    model.query = "needle"
    model.chooseClipboardFilter(.images)
    model.selectedID = "image"
    model.openPreview(model.selectedClip!)
    let now = Date()
    model.conceal(now: now)
    model.clips[4].ocrText = "Recognition corrected the text"
    model.present(destination: "clipboard", resume: true, now: now.addingTimeInterval(2))
    XCTAssertEqual(model.clipboardFilter, .images)
    XCTAssertEqual(model.query, "needle")
    XCTAssertTrue(model.clipResults.isEmpty)
    XCTAssertNil(model.selectedID)
    XCTAssertNil(model.previewID)
    XCTAssertNil(model.preview)
  }

  @MainActor func testKeyboardFiltersAreScopedGuardedAndUseVisibleResultOrder() async {
    let model = model()
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    let links = NativeKeyInput(
      code: 21, characters: "4", modifiers: [.command, .control],
      editing: true, searchEditing: true)
    var blocked = links
    blocked.composing = true
    XCTAssertFalse(model.handleKeyboard(blocked))
    blocked = links
    blocked.repeatKey = true
    XCTAssertTrue(model.handleKeyboard(blocked))
    model.busy = true
    XCTAssertTrue(model.handleKeyboard(links))
    model.busy = false
    XCTAssertEqual(model.clipboardFilter, .all)
    XCTAssertTrue(model.handleKeyboard(links))
    XCTAssertEqual(model.clipboardFilter, .links)
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 125, characters: "", modifiers: [])))
    XCTAssertEqual(model.selectedID, "b")
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: .shift)))
    for _ in 0..<20 where model.commandPending { await Task.yield() }
    XCTAssertEqual(commands.last?.strings, ["id": "b"])
    XCTAssertEqual(commands.last?.name, "clipboardHistory.copy")
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 18, characters: "!", modifiers: .command)))
    for _ in 0..<20 where model.commandPending { await Task.yield() }
    XCTAssertEqual(commands.last?.strings, ["id": "a"])
    XCTAssertEqual(commands.last?.name, "clipboardHistory.select")
    let count = commands.count
    model.chooseClipboardFilter(.colors)
    XCTAssertFalse(
      model.handleKeyboard(NativeKeyInput(code: 18, characters: "1", modifiers: .command)))
    XCTAssertFalse(model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: [])))
    XCTAssertEqual(commands.count, count)
    model.confirmClear = true
    model.chooseClipboardFilter(.all)
    XCTAssertFalse(model.handleKeyboard(links))
    XCTAssertEqual(model.clipboardFilter, .colors)
    model.confirmClear = false
    model.draft = NativeSnippetDraft(content: "unsaved")
    XCTAssertFalse(model.handleKeyboard(links))
    XCTAssertEqual(model.draft?.content, "unsaved")
    model.draft = nil
    model.openPreview(model.clips[1])
    XCTAssertTrue(model.handleKeyboard(links))
    XCTAssertEqual(model.clipboardFilter, .colors)
    model.present(destination: "apps")
    XCTAssertFalse(model.handleKeyboard(links))
    model.conceal()
    model.chooseClipboardFilter(.links)
    XCTAssertEqual(model.clipboardFilter, .all)
  }
}
