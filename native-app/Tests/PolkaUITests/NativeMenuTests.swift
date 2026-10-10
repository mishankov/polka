import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeMenuTests: XCTestCase {
  @MainActor func testRedoKeyEquivalentMatchesNativeShiftedEvent() throws {
    _ = NSApplication.shared
    let application = NativeApplication()
    let edit = try XCTUnwrap(
      application.makeMainMenu().items.first { $0.submenu?.title == localized("Edit") }?.submenu)
    let redo = try XCTUnwrap(edit.items.first { $0.action == Selector(("redo:")) })
    let target = NativeMenuActionFixture()
    redo.target = target
    redo.action = #selector(NativeMenuActionFixture.execute(_:))
    edit.autoenablesItems = false
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
        windowNumber: 0, context: nil, characters: "Z", charactersIgnoringModifiers: "Z",
        isARepeat: false, keyCode: 6))
    XCTAssertTrue(edit.performKeyEquivalent(with: event))
    XCTAssertEqual(target.count, 1)
  }
  @MainActor func testNativeMenuShortcutsHaveDistinctMasksAndSharedHandlers() throws {
    _ = NSApplication.shared
    let application = NativeApplication()
    let menu = application.makeMainMenu()
    let items = menu.items.flatMap { $0.submenu?.items ?? [] }.filter { !$0.isSeparatorItem }
    let undo = try XCTUnwrap(items.first { $0.action == Selector(("undo:")) })
    let redo = try XCTUnwrap(items.first { $0.action == Selector(("redo:")) })
    XCTAssertEqual(undo.keyEquivalent, "z")
    XCTAssertEqual(undo.keyEquivalentModifierMask, .command)
    XCTAssertEqual(redo.keyEquivalent, "Z")
    XCTAssertEqual(redo.keyEquivalentModifierMask, [.command, .shift])
    XCTAssertNil(undo.target)
    XCTAssertNil(redo.target)  // Native editor undo manager owns both.
    let hide = try XCTUnwrap(
      items.first { $0.keyEquivalent == "h" && $0.keyEquivalentModifierMask == .command })
    let others = try XCTUnwrap(
      items.first {
        $0.keyEquivalent == "h" && $0.keyEquivalentModifierMask == [.command, .option]
      })
    let close = try XCTUnwrap(items.first { $0.keyEquivalent == "w" })
    XCTAssertTrue(hide.target === application)
    XCTAssertTrue(close.target === application)
    XCTAssertEqual(close.keyEquivalentModifierMask, .command)
    XCTAssertTrue(others.target === NSApp)
    XCTAssertEqual(others.action, #selector(NSApplication.hideOtherApplications(_:)))
    let bindings = items.filter { !$0.keyEquivalent.isEmpty }.map {
      "\($0.keyEquivalent):\($0.keyEquivalentModifierMask.rawValue)"
    }
    XCTAssertEqual(Set(bindings).count, bindings.count)
  }
  @MainActor func testHideAndCloseMenuValidationBlocksBusyActions() throws {
    _ = NSApplication.shared
    let application = NativeApplication()
    let items = application.makeMainMenu().items.flatMap { $0.submenu?.items ?? [] }
    let hide = try XCTUnwrap(
      items.first { $0.keyEquivalent == "h" && $0.keyEquivalentModifierMask == .command })
    let close = try XCTUnwrap(items.first { $0.keyEquivalent == "w" })
    application.model.busy = true
    XCTAssertFalse(application.validateMenuItem(hide))
    XCTAssertFalse(application.validateMenuItem(close))
    application.model.busy = false
    XCTAssertTrue(application.validateMenuItem(hide))
  }
}

@MainActor private final class NativeMenuActionFixture: NSObject {
  var count = 0
  @objc func execute(_ sender: Any?) { count += 1 }
}
