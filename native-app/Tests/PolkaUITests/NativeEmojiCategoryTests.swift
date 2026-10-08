import AppKit
import XCTest

@testable import PolkaApp

final class NativeEmojiCategoryTests: XCTestCase {
  @MainActor func testTabLoopIncludesOnlySelectedCategoryAndFollowsArrowSelection() {
    let (window, model, bar) = fixture()
    let search = EmojiFocusOrigin(frame: NSRect(x: 0, y: 60, width: 600, height: 44))
    window.contentView!.addSubview(search)
    search.nextKeyView = bar.buttons[0]
    for index in bar.buttons.indices {
      bar.buttons[index].nextKeyView =
        index + 1 < bar.buttons.count ? bar.buttons[index + 1] : search
    }
    XCTAssertEqual(bar.buttons.filter(\.canBecomeKeyView).count, 1)
    XCTAssertTrue(search.nextValidKeyView === bar.buttons[0])
    window.selectKeyView(following: search)
    XCTAssertTrue(window.firstResponder === bar.buttons[0])

    XCTAssertTrue(bar.moveSelection(keyCode: 124))
    XCTAssertEqual(model.emojiCategory, "Smileys & Emotion")
    XCTAssertTrue(window.firstResponder === bar.buttons[1])
    XCTAssertEqual(bar.buttons.filter(\.canBecomeKeyView).count, 1)
    XCTAssertTrue(search.nextValidKeyView === bar.buttons[1])
    XCTAssertTrue(bar.moveSelection(keyCode: 119))
    XCTAssertTrue(search.nextValidKeyView === bar.buttons.last)
    XCTAssertTrue(bar.moveSelection(keyCode: 124))
    XCTAssertTrue(search.nextValidKeyView === bar.buttons[0])
  }

  @MainActor func testBusyHiddenAndDetachedCategoriesAreExcludedFromTabNavigation() {
    let (window, model, bar) = fixture()
    let selected = bar.buttons[0]
    XCTAssertTrue(selected.canBecomeKeyView)
    model.busy = true
    bar.synchronizeSelection()
    XCTAssertFalse(bar.buttons.contains(where: \.canBecomeKeyView))
    model.busy = false
    bar.synchronizeSelection()
    selected.isHidden = true
    XCTAssertFalse(selected.canBecomeKeyView)
    selected.isHidden = false
    bar.isHidden = true
    XCTAssertFalse(selected.canBecomeKeyView)
    bar.isHidden = false
    XCTAssertTrue(selected.canBecomeKeyView)
    bar.removeFromSuperview()
    XCTAssertFalse(selected.canBecomeKeyView)
    XCTAssertNotNil(window.contentView)
  }

  @MainActor private func fixture() -> (ShelfPanel, NativeUIModel, NativeEmojiCategoryBar) {
    _ = NSApplication.shared
    let window = ShelfPanel(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let model = NativeUIModel()
    model.storageStatus = "ready"
    model.present(destination: "emoji")
    let bar = NativeEmojiCategoryBar(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
    window.contentView!.addSubview(bar)
    bar.model = model
    bar.synchronizeSelection()
    return (window, model, bar)
  }
}

@MainActor private final class EmojiFocusOrigin: NSView {
  override var acceptsFirstResponder: Bool { true }
}
