import AppKit
import PolkaCore
import SwiftUI
import XCTest

@testable import PolkaApp

final class NativeTextPreviewTests: XCTestCase {
  @MainActor func testPreviewNeverChangesCopyOrSearchAndTransformationsStillWork() async {
    let model = NativeUIModel()
    model.present(destination: "clipboard")
    model.storageStatus = "ready"
    let content = "{\"name\": \"e\u{301} 👩🏽‍💻\"}\r\n"
    let clip = NativeUIClip(id: "code", content: content)
    model.clips = [clip]
    model.query = "name"
    let results = model.clipResults
    model.openPreview(clip)
    XCTAssertEqual(model.clipResults, results)
    XCTAssertEqual(Data(model.previewText.utf8), Data(content.utf8))
    var commands: [NativeUICommand] = []
    model.action = { commands.append($0) }
    model.chooseClip(clip, copyOnly: true)
    for _ in 0..<20 where model.busy { await Task.yield() }
    XCTAssertEqual(commands.last?.name, "clipboardHistory.copy")
    XCTAssertEqual(commands.last?.strings, ["id": "code"])
    model.chooseClip(clip)
    for _ in 0..<20 where model.busy { await Task.yield() }
    XCTAssertEqual(commands.last?.name, "clipboardHistory.select")
    XCTAssertEqual(commands.last?.strings, ["id": "code"])
    model.previewActions(for: clip)[0].run()
    XCTAssertEqual(model.previewText, content.uppercased())
    model.chooseClip(clip)
    for _ in 0..<20 where model.busy { await Task.yield() }
    XCTAssertEqual(commands.last?.strings["transformation"], "upperCase")
    XCTAssertEqual(Data(model.clips[0].content.utf8), Data(content.utf8))
  }

  @MainActor func testSelectableNativeTextIsExactForInertMarkupAndLargeContent() async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    for content in [
      "<script>fetch('https://example.com')</script>\r\n👩🏽‍💻",
      String(repeating: "x", count: 1_048_500),
    ] {
      window.contentView = NSHostingView(
        rootView: NativePlainTextPreview(
          text: content, scrollOffset: .constant(0)))
      let found = await nativeSmokeWaitForView(in: window, ofType: NSTextView.self)
      let view = try XCTUnwrap(found)
      XCTAssertEqual(Data(view.string.utf8), Data(content.utf8))
      XCTAssertTrue(view.isSelectable)
      XCTAssertFalse(view.isEditable)
      XCTAssertFalse(view.isAutomaticLinkDetectionEnabled)
      XCTAssertFalse(view.isAutomaticDataDetectionEnabled)
      XCTAssertFalse(view.textContainer?.widthTracksTextView ?? true)
      XCTAssertNotNil(view.enclosingScrollView)
    }
  }

  @MainActor func testLongLinesScrollAndPreviewRestoresVerticalPosition() async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let model = NativeUIModel()
    let content =
      String(repeating: "long line ", count: 300) + "\n"
      + String(repeating: "next line\n", count: 100)
    model.previewScrollOffset = 120
    func install(_ token: String) {
      window.contentView = NSHostingView(
        rootView: NativePlainTextPreview(
          text: content,
          scrollOffset: Binding(
            get: { model.previewScrollOffset }, set: { model.previewScrollOffset = $0 }),
          scrollToken: token))
    }
    install("first")
    let found = await nativeSmokeWaitForView(in: window, ofType: NSTextView.self)
    let text = try XCTUnwrap(found)
    for _ in 0..<10 { await Task.yield() }
    let scroll = try XCTUnwrap(text.enclosingScrollView)
    XCTAssertGreaterThan(text.frame.width, scroll.contentSize.width)
    XCTAssertGreaterThan(text.frame.height, scroll.contentSize.height)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, 120, accuracy: 1)
    scroll.contentView.scroll(to: NSPoint(x: 50, y: 200))
    scroll.reflectScrolledClipView(scroll.contentView)
    XCTAssertEqual(model.previewScrollOffset, 200, accuracy: 1)
    install("resumed")
    let restored = await nativeSmokeWaitForView(in: window, ofType: NSTextView.self)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(
      try XCTUnwrap(restored?.enclosingScrollView).contentView.bounds.origin.y, 200, accuracy: 1)
  }
}
