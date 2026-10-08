import AppKit
import XCTest

@testable import PolkaApp

final class NativeCloseTests: XCTestCase {
  @MainActor func testEscapeRespectsCompositionRepeatBusyAndSettingsScope() async {
    let model = NativeUIModel()
    model.present(destination: "apps")
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    XCTAssertFalse(
      model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [], composing: true))
    )
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [], repeatKey: true))
    )
    model.busy = true
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [])))
    model.busy = false
    XCTAssertFalse(
      model.handleKeyboard(
        NativeKeyInput(code: 53, characters: "", modifiers: [], isSettings: true)))
    await Task.yield()
    XCTAssertTrue(commands.isEmpty)
    XCTAssertTrue(model.visible)
  }
  @MainActor func testRepeatedEscapeDispatchesOnlyOnePendingHide() async {
    let model = NativeUIModel()
    model.present(destination: "apps")
    var commands: [NativeUICommand] = []
    var release: CheckedContinuation<Void, Never>?
    model.action = { command in
      commands.append(command)
      await withCheckedContinuation { release = $0 }
      model.conceal()
    }
    let escape = NativeKeyInput(code: 53, characters: "", modifiers: [])
    XCTAssertTrue(model.handleKeyboard(escape))
    for _ in 0..<100 where release == nil { await Task.yield() }
    XCTAssertNotNil(release)
    XCTAssertTrue(model.busy)
    XCTAssertTrue(model.handleKeyboard(escape))
    XCTAssertTrue(model.handleKeyboard(escape))
    XCTAssertEqual(commands.map(\.name), ["launcher.hide"])
    release?.resume()
    for _ in 0..<100 where model.busy { await Task.yield() }
    XCTAssertFalse(model.visible)
    XCTAssertFalse(model.busy)
  }
  @MainActor func testBlurPreservesUnsavedEditorButEscapeDeliberatelyCancelsIt() async {
    let model = NativeUIModel()
    model.storageStatus = "ready"
    model.present(destination: "snippets")
    model.createSnippet()
    model.draft?.name = "Несохранённое"
    model.draft?.content = "Черновик"
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    model.conceal()
    model.present(destination: "snippets", resume: true)
    XCTAssertEqual(model.draft?.name, "Несохранённое")
    XCTAssertEqual(model.draft?.content, "Черновик")
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [])))
    XCTAssertNil(model.draft)
    XCTAssertTrue(model.visible)
    model.conceal()
    model.present(destination: "snippets", resume: true)
    XCTAssertNil(model.draft)
    await Task.yield()
    XCTAssertTrue(commands.isEmpty)
  }
  @MainActor func testEscapeCancelsConfirmationBeforeClosingAndNeverClearsHistory() async {
    let model = NativeUIModel()
    model.storageStatus = "ready"
    model.present(destination: "clipboard")
    model.clips = [NativeUIClip(id: "clip", content: "Keep")]
    model.showClearConfirmation()
    var commands: [NativeUICommand] = []
    model.action = {
      commands.append($0)
      model.conceal()
    }
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [])))
    XCTAssertFalse(model.confirmClear)
    XCTAssertTrue(model.visible)
    XCTAssertEqual(model.clips.count, 1)
    await Task.yield()
    XCTAssertTrue(commands.isEmpty)
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [])))
    for _ in 0..<100 where model.busy { await Task.yield() }
    XCTAssertEqual(commands.map(\.name), ["launcher.hide"])
    XCTAssertFalse(model.visible)
    XCTAssertEqual(model.clips.count, 1)
  }
}
