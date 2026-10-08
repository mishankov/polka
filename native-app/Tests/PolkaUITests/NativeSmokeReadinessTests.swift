import AppKit
import XCTest

@testable import PolkaApp

final class NativeSmokeReadinessTests: XCTestCase {
  @MainActor func testMaterializesCategoryControlsDuringLayout() async {
    let window = makeWindow()
    let content = DeferredCategoryView(frame: window.contentView!.bounds)
    window.contentView = content
    content.needsLayout = true
    XCTAssertTrue(content.subviews.isEmpty)

    let bar = await nativeSmokeWaitForView(
      in: window, ofType: NativeEmojiCategoryBar.self, attempts: 0,
      ready: { $0.buttons.count == nativeEmojiCategories.count && $0.bounds.width > 0 })

    XCTAssertNotNil(bar)
    XCTAssertEqual(bar?.buttons.count, nativeEmojiCategories.count)
    XCTAssertTrue(bar?.buttons.allSatisfy { $0.bounds.width >= 40 } == true)
  }

  @MainActor func testWaitsForDelayedControlAndRejectsUnreadyControl() async {
    let window = makeWindow()
    let bar = NativeEmojiCategoryBar(frame: .zero)
    window.contentView!.addSubview(bar)
    let initial = await nativeSmokeWaitForView(
      in: window, ofType: NativeEmojiCategoryBar.self, attempts: 0,
      ready: { $0.bounds.width > 0 })
    XCTAssertNil(initial)
    let materialize = Task { @MainActor in
      await Task.yield()
      bar.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
      bar.needsLayout = true
    }
    let ready = await nativeSmokeWaitForView(
      in: window, ofType: NativeEmojiCategoryBar.self,
      ready: { $0.bounds.width > 0 })
    await materialize.value
    XCTAssertTrue(ready === bar)
    XCTAssertTrue(bar.buttons.allSatisfy { $0.bounds.width >= 40 })
  }

  @MainActor func testMissingControlReturnsAfterBoundedAttempts() async {
    let window = makeWindow()
    let missing = await nativeSmokeWaitForView(
      in: window, ofType: NativeEmojiCategoryBar.self, attempts: 1)
    XCTAssertNil(missing)
  }

  @MainActor func testWaitsForQueuedResponderChangeAfterControlCreation() async {
    let window = makeWindow()
    let control = DeferredFocusableView(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
    window.contentView!.addSubview(control)
    XCTAssertFalse(window.firstResponder === control)
    let focus = Task { @MainActor in
      await Task.yield()
      XCTAssertTrue(window.makeFirstResponder(control))
    }
    let focused = await nativeSmokeWaitForView(
      in: window, ofType: DeferredFocusableView.self,
      ready: { window.firstResponder === $0 })
    await focus.value
    XCTAssertTrue(focused === control)
  }

  @MainActor private func makeWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }
}

@MainActor private final class DeferredFocusableView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

@MainActor private final class DeferredCategoryView: NSView {
  override func layout() {
    super.layout()
    guard subviews.isEmpty else { return }
    let bar = NativeEmojiCategoryBar(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 40))
    addSubview(bar)
    bar.needsLayout = true
  }
}
