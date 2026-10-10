import AppKit
import XCTest

@testable import PolkaApp

final class NativeBuiltinAppSwitchTests: XCTestCase {
  @MainActor func testTabLoopReachesEverySwitch() {
    let (window, origin, controls) = fixture()
    defer { window.close() }
    XCTAssertTrue(origin.nextValidKeyView === controls[0])
    var previous: NSView = origin
    for control in controls {
      window.selectKeyView(following: previous)
      XCTAssertTrue(window.firstResponder === control)
      previous = control
    }
    window.selectKeyView(following: previous)
    XCTAssertTrue(window.firstResponder === origin)
  }

  @MainActor func testBusyHiddenAndDetachedSwitchesAreExcludedFromTabNavigation() {
    let (window, origin, controls) = fixture()
    defer { window.close() }
    controls[0].setAvailable(false, focusRevision: 0)
    XCTAssertFalse(controls[0].acceptsFirstResponder)
    XCTAssertTrue(origin.nextValidKeyView === controls[1])
    controls[1].isHidden = true
    XCTAssertTrue(origin.nextValidKeyView === controls[2])
    let container = NSView(frame: controls[2].frame)
    window.contentView!.addSubview(container)
    container.addSubview(controls[2])
    container.isHidden = true
    XCTAssertFalse(controls[2].canBecomeKeyView)
    controls[3].removeFromSuperview()
    XCTAssertFalse(controls[3].canBecomeKeyView)
  }

  @MainActor private func fixture() -> (NSWindow, NSView, [NativeBuiltinAppSwitch]) {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let origin = BuiltinSwitchFocusOrigin(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    window.contentView!.addSubview(origin)
    let controls = (0..<4).map { index in
      let control = NativeBuiltinAppSwitch(
        frame: NSRect(x: 120, y: 40 + index * 40, width: 50, height: 24))
      window.contentView!.addSubview(control)
      return control
    }
    origin.nextKeyView = controls[0]
    for index in controls.indices {
      controls[index].nextKeyView = index + 1 < controls.count ? controls[index + 1] : origin
    }
    return (window, origin, controls)
  }
}

@MainActor private final class BuiltinSwitchFocusOrigin: NSView {
  override var acceptsFirstResponder: Bool { true }
}
