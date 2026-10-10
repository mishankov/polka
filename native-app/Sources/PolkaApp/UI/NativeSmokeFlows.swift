import AppKit
import Combine
import Foundation
import PolkaCore
import SwiftUI

/// SwiftUI can defer representable creation until the hosting view's next layout.
/// Wait for a usable control, rather than treating an animation delay as readiness.
@MainActor func nativeSmokeWaitForView<View: NSView>(
  in window: NSWindow, ofType type: View.Type, attempts: Int = 100,
  ready: (View) -> Bool = { _ in true }
) async -> View? {
  func find(in view: NSView) -> View? {
    if let match = view as? View, ready(match) { return match }
    for child in view.subviews { if let match = find(in: child) { return match } }
    return nil
  }
  for attempt in 0...attempts {
    if let content = window.contentView {
      content.layoutSubtreeIfNeeded()
      if let match = find(in: content) { return match }
    }
    if attempt < attempts { try? await Task.sleep(nanoseconds: 10_000_000) }
  }
  return nil
}

/// Runs only in the app-owned, isolated desktop fixture. All keys are posted to
/// this process's real AppKit event loop, and every copy uses the injected board.
@MainActor func nativeSmokeAdditionalFlows(
  application: NativeApplication, shelf: NSWindow, model: NativeUIModel, platform: NativePlatform,
  settingsOnly: Bool = false
) async -> [String] {
  guard NativeProfile.isolatedFixture else { return ["native smoke requires an isolated profile"] }
  // Ask this fixture process to materialize SwiftUI's virtual accessibility
  // elements, as an accessibility client would. This changes no system setting.
  NSApp.accessibilitySetValue(
    NSNumber(value: true),
    forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
  var failures: [String] = []
  if shelf.hasShadow {
    failures.append("system shelf keyline can cross the hardware notch")
  }
  let environment = ProcessInfo.processInfo.environment
  let screenshotDirectory: URL? = environment["POLKA_NATIVE_SMOKE_SCREENSHOT_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
  }
  if let screenshotDirectory {
    try? FileManager.default.createDirectory(
      at: screenshotDirectory, withIntermediateDirectories: true)
  }
  func post(
    _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ characters: String = "",
    repeatKey: Bool = false, window: NSWindow? = nil
  ) {
    let owner = window ?? shelf
    // charactersIgnoringModifiers still preserves Shift, just like events
    // emitted by AppKit: a shifted Z must be uppercase in both strings.
    if let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: repeatKey, keyCode: code)
    {
      NSApp.postEvent(event, atStart: false)
    } else {
      failures.append("cannot construct native key event \(code)")
    }
  }
  func wait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
  }
  func click(_ control: NSControl) {
    guard let owner = control.window else {
      failures.append("cannot click a detached native control")
      return
    }
    let point = control.convert(
      NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
    // Post both halves to AppKit rather than running performClick inside this
    // actor task. NSSwitch can run an animation/tracking loop synchronously;
    // its action must be free to schedule SwiftUI updates on the main actor.
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
      {
        NSApp.postEvent(event, atStart: false)
      } else {
        failures.append("cannot construct native mouse event")
      }
    }
  }
  func accessible(_ identifier: String, in source: Any? = nil) -> NativeSmokeAccessibility? {
    guard let source = source ?? shelf.contentView as Any? else { return nil }
    let object = source as AnyObject
    let element = NativeSmokeAccessibility(object: object)
    if element.accessibilityIdentifier() == identifier { return element }
    for child in element.children {
      if let match = accessible(identifier, in: child) { return match }
    }
    // Ignored animation containers can expose no accessibility children.
    if let view = object as? NSView {
      for child in view.subviews {
        if let match = accessible(identifier, in: child) { return match }
      }
    }
    return nil
  }
  func clickAccessible(_ identifier: String) {
    guard let button = accessible(identifier) else {
      failures.append("missing accessible button \(identifier)")
      return
    }
    let frame = shelf.convertFromScreen(button.accessibilityFrame())
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(
        with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shelf.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
      {
        NSApp.postEvent(event, atStart: false)
      }
    }
  }
  func settle() async { try? await Task.sleep(nanoseconds: 230_000_000) }
  func trace(_ message: String) {
    // stdout is buffered when the harness captures pipes. Keep the last step
    // available even if a hosted AppKit call hangs and the child is terminated.
    FileHandle.standardError.write(Data("Native smoke: \(message)\n".utf8))
  }
  func keyboardState(_ owner: NSWindow? = nil) -> String {
    let window = owner ?? shelf
    let text = window.firstResponder as? NSTextView
    return
      "destination=\(model.destination), query=\(model.query), visible=\(model.visible)/\(window.isVisible), busy=\(model.busy), key=\(window.isKeyWindow), keyWindow=\(String(describing: NSApp.keyWindow)), active=\(NSApp.isActive), hidden=\(NSApp.isHidden), fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled), firstResponder=\(String(describing: window.firstResponder)), delegate=\(String(describing: text?.delegate)), marked=\(text?.hasMarkedText() ?? false), sheet=\(window.attachedSheet != nil), modal=\(NSApp.modalWindow != nil), menuTracking=\(NSMenuTrackingState.shared.active); lifecycle trace:\n\(application.smokeLifecycleTrace.suffix(20).joined(separator: "\n"))"
  }
  func screenshot(_ name: String, window: NSWindow? = nil, includeTitlebar: Bool = false) async {
    guard let screenshotDirectory else { return }
    await settle()
    guard let content = (window ?? shelf).contentView else {
      failures.append("missing view for screenshot \(name)")
      return
    }
    let view = includeTitlebar ? (content.superview ?? content) : content
    view.layoutSubtreeIfNeeded()
    view.needsDisplay = true
    view.displayIfNeeded()
    if environment["POLKA_NATIVE_SMOKE_WINDOW_CAPTURE"] == "1",
      name.hasPrefix("controls-") || name == "snippet-editor"
        || name == "clipboard-clear-confirmation"
    {
      // Opt-in, window-only capture includes SwiftUI's compositor-backed glass.
      // The default bitmap path stays usable on CI without screen permission.
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = [
        "-x", "-o", "-l", String((window ?? shelf).windowNumber),
        screenshotDirectory.appendingPathComponent(name + ".png").path,
      ]
      do {
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus == 0 { return }
        failures.append("window capture failed for \(name)")
      } catch { failures.append("cannot capture window for \(name)") }
    }
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      failures.append("cannot allocate screenshot \(name)")
      return
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    if let png = bitmap.representation(using: .png, properties: [:]) {
      do { try png.write(to: screenshotDirectory.appendingPathComponent(name + ".png")) } catch {
        failures.append("cannot write screenshot \(name)")
      }
    } else {
      failures.append("cannot render screenshot \(name)")
    }
  }
  if !settingsOnly {
    // Real window lifecycle, not just model dispatch: a delayed close must not
    // order out a reopened panel, and repeated requests must remain harmless.
    await application.show("apps")
    await settle()
    application.hide()
    application.hide()
    await application.show("emoji")
    await settle()
    if !model.visible || !shelf.isVisible || model.destination != "emoji" {
      failures.append("stale close animation hid or replaced a reopened shelf")
    }
    await application.show("toggle")
    await settle()
    if model.visible || shelf.isVisible {
      failures.append("active launcher toggle did not close shelf")
    }
    await application.show("toggle")
    await settle()
    if !model.visible || !shelf.isVisible || model.destination != "emoji" {
      failures.append("launcher toggle did not reopen remembered shelf")
    }
    await application.show("apps")
    await settle()
    model.busy = true
    post(53)
    application.hide()
    application.applicationDidResignActive(
      Notification(name: NSApplication.didResignActiveNotification, object: NSApp))
    await settle()
    if !model.visible || !shelf.isVisible {
      failures.append("busy shelf was dismissed by Escape, close, or blur")
    }
    model.busy = false
    post(53, repeatKey: true)
    await settle()
    if !model.visible || !shelf.isVisible { failures.append("repeated Escape dismissed shelf") }
    let guardedSheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: 80), styleMask: [.titled],
      backing: .buffered, defer: false)
    guardedSheet.isReleasedWhenClosed = false
    shelf.beginSheet(guardedSheet, completionHandler: nil)
    post(53, window: guardedSheet)
    application.hide(force: true)
    application.applicationDidResignActive(
      Notification(name: NSApplication.didResignActiveNotification, object: NSApp))
    await settle()
    if !model.visible || !shelf.isVisible {
      failures.append("sheet owner was dismissed by Escape, forced close, or blur")
    }
    shelf.endSheet(guardedSheet)
    guardedSheet.close()
    shelf.makeKeyAndOrderFront(nil)
    await settle()
    await application.show("snippets")
    await settle()
    model.createSnippet()
    model.draft?.name = "Закрытие"
    model.draft?.content = "Несохранённый черновик"
    let draftOutside = NSWindow(
      contentRect: NSRect(x: 30, y: 30, width: 160, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    draftOutside.isReleasedWhenClosed = false
    draftOutside.makeKeyAndOrderFront(nil)
    if !(await wait({ !model.visible && !shelf.isVisible })) {
      failures.append("snippet editor did not close after focus loss")
    }
    draftOutside.close()
    await application.show(nil)
    await settle()
    if model.draft?.content != "Несохранённый черновик" {
      failures.append("focus-loss close discarded unsaved snippet draft")
    }
    post(13, .command, "w")
    if !(await wait({ !model.visible && !shelf.isVisible })) {
      failures.append("posted Command W did not close shelf editor")
    }
    await application.show(nil)
    await settle()
    if model.draft?.content != "Несохранённый черновик" {
      failures.append("Command W close discarded unsaved snippet draft")
    }
    post(53)
    if !(await wait({ model.draft == nil && model.visible })) {
      failures.append("Escape did not cancel restored draft without closing shelf")
    }
    await application.show("apps")
    await settle()
    model.query = "Hide preserves context"
    post(4, .command, "h")
    if !(await wait({ NSApp.isHidden && !model.visible })) {
      failures.append("posted Command H did not hide app and conceal shelf")
    }
    if !(await wait({ !shelf.isVisible })) {
      failures.append("application Hide did not finish ordering out shelf")
    }
    NSApp.unhide(nil)
    await application.show(nil)
    await settle()
    if !(await wait({ shelf.isKeyWindow && NSApp.isActive && !NSApp.isHidden })) {
      failures.append(
        "shelf did not regain keyboard focus after application Hide: \(keyboardState())")
    }
    if model.query != "Hide preserves context" {
      failures.append("application Hide discarded browse context")
    }
    // Reopen while the 150 ms close/unhide transitions are still pending. This
    // used to leave the accessory application's visible panel without a key
    // window, causing the local keyboard bridge to correctly ignore Escape.
    for cycle in 1...20 {
      post(4, .command, "h")
      if !(await wait({ NSApp.isHidden && !model.visible })) {
        failures.append("rapid Hide cycle \(cycle) did not hide application: \(keyboardState())")
        break
      }
      NSApp.unhide(nil)
      await application.show(nil)
      if !(await wait({ model.visible && shelf.isVisible && shelf.isKeyWindow && NSApp.isActive }))
      {
        failures.append(
          "rapid Hide/reopen cycle \(cycle) left shelf without keyboard focus: \(keyboardState())")
        break
      }
      // Also check after the native activation/close animations settle; an
      // immediate key-window success must not hide a delayed dismissal.
      await settle()
      if !model.visible || !shelf.isVisible || !shelf.isKeyWindow {
        failures.append("rapid Hide/reopen cycle \(cycle) was later dismissed: \(keyboardState())")
        break
      }
    }
    await application.show("apps")
    model.query = ""
    await settle()
    await screenshot("launcher")
    if let view = shelf.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      if let color = bitmap.colorAt(x: 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) {
        if color.alphaComponent < 0.99
          || max(color.redComponent, color.greenComponent, color.blueComponent) > 0.01
        {
          failures.append("shelf background is not opaque black")
        }
      } else {
        failures.append("cannot inspect shelf background")
      }
    }
    let standardWidth = shelf.frame.width
    trace("shared built-in controls")
    var backFrame: NSRect?
    var selectFrame: NSRect?
    for destination in ["clipboard", "snippets", "emoji", "files"] {
      await application.show(destination)
      if ["clipboard", "snippets"].contains(destination) {
        model.selectedID = model.clipResults.first(where: { $0.kind == "text" })?.id
      }
      await settle()
      guard let back = accessible("builtin-back"), let close = accessible("builtin-close") else {
        failures.append("\(destination) is missing accessible shared navigation")
        continue
      }
      let frame = back.accessibilityFrame()
      if let backFrame,
        abs(frame.minX - backFrame.minX) > 1
          || abs(frame.maxY - backFrame.maxY) > 1 || abs(frame.height - backFrame.height) > 1
      {
        failures.append("\(destination) shared Back placement or size differs")
      }
      backFrame = frame
      if back.accessibilityRole() != .button || close.accessibilityRole() != .button
        || frame.width < 28 || frame.height < 28
        || back.accessibilityHelp()?.contains("⌫") != true
        || close.accessibilityHelp()?.contains("⌘W") != true
      {
        failures.append("\(destination) navigation has no usable target or shortcut metadata")
      }
      if destination != "files" {
        guard let select = accessible("builtin-select") else {
          failures.append("\(destination) has no shared primary selection command")
          continue
        }
        let frame = select.accessibilityFrame()
        if let selectFrame,
          abs(frame.maxX - selectFrame.maxX) > 1
            || abs(frame.minY - selectFrame.minY) > 1 || abs(frame.height - selectFrame.height) > 1
        {
          failures.append("\(destination) primary action placement or size differs")
        }
        selectFrame = frame
        if select.accessibilityHelp()?.contains("↵") != true {
          failures.append("\(destination) primary action shortcut is inaccessible")
        }
        platform.capture.write(text: "Synthetic toolbar sentinel")
        let expected =
          destination == "emoji" ? model.selectedEmoji?.value : model.selectedClip?.content
        clickAccessible("builtin-copy")
        if !(await wait({ !model.busy && platform.capture.syntheticText == expected })) {
          failures.append("\(destination) toolbar pointer copy did not use selected-item command")
        }
        if !model.visible { await application.show(nil) }
        await settle()
      }
      await screenshot("controls-\(destination)")
      model.busy = true
      await settle()
      if accessible("builtin-back")?.isAccessibilityEnabled() != false
        || accessible("builtin-close")?.isAccessibilityEnabled() != false
      {
        failures.append("\(destination) busy navigation remains accessible as enabled")
      }
      clickAccessible("builtin-back")
      _ = accessible("builtin-close")?.accessibilityPerformPress()
      post(13, .command, "ц")
      await settle()
      if !model.visible || model.destination != destination {
        failures.append(
          "\(destination) busy pointer, accessibility or keyboard action escaped its guard")
      }
      model.busy = false
      await settle()
      clickAccessible("builtin-back")
      if !(await wait({ model.destination == "apps" && !model.busy })) {
        failures.append("\(destination) shared pointer Back did not return to apps")
      }
    }
    await application.show("snippets")
    await settle()
    _ = accessible("snippet-create")?.accessibilityPerformPress()
    if !(await wait({ model.draft != nil })) {
      failures.append("accessible Create did not open a snippet editor")
    }
    model.draft?.content = "Synthetic accessible draft"
    shelf.beginSheet(guardedSheet, completionHandler: nil)
    _ = accessible("snippet-save")?.accessibilityPerformPress()
    _ = accessible("builtin-close")?.accessibilityPerformPress()
    await settle()
    if model.draft?.content != "Synthetic accessible draft" || !model.visible || model.busy {
      failures.append("shared accessibility commands acted behind a native sheet")
    }
    shelf.endSheet(guardedSheet)
    guardedSheet.orderOut(nil)
    shelf.makeKeyAndOrderFront(nil)
    await settle()
    _ = accessible("builtin-close")?.accessibilityPerformPress()
    if !(await wait({ !model.visible && !model.busy })) {
      failures.append("accessible Close did not dismiss snippet editor")
    }
    await application.show(nil)
    await settle()
    if model.draft?.content != "Synthetic accessible draft" {
      failures.append("shared Close discarded an unsaved snippet draft")
    }
    post(53)
    await settle()
    await application.show("apps")
    await settle()
    func searchField(in view: NSView) -> NSSearchField? {
      if let field = view as? NSSearchField { return field }
      for child in view.subviews { if let field = searchField(in: child) { return field } }
      return nil
    }
    post(0, [], "я")
    if !(await wait({ model.query == "я" })) {
      failures.append("enlarged search field did not accept non-Latin keyboard text")
    }
    post(51, .command)
    if !(await wait({ model.query.isEmpty })) {
      failures.append("native Command Backspace did not clear enlarged search field")
    }
    // The model binding changes before SwiftUI's query observer resets the old
    // result selection. Let that text-edit transaction finish before navigation.
    await settle()
    post(125)
    if !(await wait({ model.selectedID != nil })) {
      failures.append(
        "Arrow Down from enlarged search field did not select launcher result: \(keyboardState())")
    }
    for destination in ["apps", "clipboard", "snippets", "emoji", "files"] {
      await application.show(destination)
      await settle()
      if abs(shelf.frame.width - standardWidth) > 1 {
        failures.append("\(destination) shelf width differs from launcher")
      }
      if destination != "files" {
        if let view = shelf.contentView, let field = searchField(in: view) {
          if field.focusRingType != .none || field.cell?.focusRingType != NSFocusRingType.none {
            failures.append(
              "\(destination) search uses a window focus ring outside the shelf animation mask")
          }
          if field.bounds.height < 44 || field.bounds.width < standardWidth - 100
            || (field.font?.pointSize ?? 0) < 20
          {
            failures.append("\(destination) search field is too small")
          }
          if let editor = field.currentEditor() as? NSTextView, let window = field.window {
            let caret = editor.firstRect(
              forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            let textBounds = field.convert(window.convertFromScreen(caret), from: nil)
            if textBounds.minX < 30 || abs(textBounds.midY - field.bounds.midY) > 4 {
              failures.append(
                "\(destination) search text overlaps its icon or is not vertically centered: \(textBounds), bezel \(field.isBezeled)"
              )
            }
          } else {
            failures.append("\(destination) search field did not receive keyboard focus")
          }
          if let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) {
            field.cacheDisplay(in: field.bounds, to: bitmap)
            if let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 4)?.usingColorSpace(
              .deviceRGB),
              color.alphaComponent < 0.9
                || max(color.redComponent, color.greenComponent, color.blueComponent) < 0.02
            {
              failures.append("\(destination) search bezel does not fill its enlarged height")
            }
          }
        } else {
          failures.append("\(destination) search field missing")
        }
      }
      let query = destination == "files" ? "" : destination == "emoji" ? "heart" : "Синтетическая"
      model.query = query
      await settle()
      post(53)
      if !(await wait({ !model.visible && !shelf.isVisible && !model.busy })) {
        failures.append("\(destination) shelf did not finish closing: \(keyboardState())")
      }
      await application.show(nil)
      await settle()
      if model.destination != destination || model.query != query {
        failures.append("fully closed \(destination) shelf did not resume its previous context")
      }
      post(53)
      if !(await wait({ !model.visible && !shelf.isVisible && !model.busy })) {
        failures.append("\(destination) shelf did not close before keyboard toggle")
      }
      await application.show("toggle")
      await settle()
      if model.destination != destination || model.query != query {
        failures.append("launcher shortcut path did not resume \(destination)")
      }
      await application.show("apps")
      await settle()
      if model.destination != "apps" || !model.query.isEmpty {
        failures.append(
          "explicit launcher navigation from \(destination) did not reset browse context: \(model.destination), query \(model.query)"
        )
      }
    }
    post(53)
    if !(await wait({ !model.visible && !shelf.isVisible })) {
      failures.append("posted Escape did not dismiss native shelf window")
    }
    await application.show("apps", byHover: true)
    await settle()
    // An app-owned test window exercises real key-window loss without clicking
    // in another user's application or changing its contents.
    let outside = NSWindow(
      contentRect: NSRect(x: 30, y: 30, width: 160, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    outside.isReleasedWhenClosed = false
    outside.makeKeyAndOrderFront(nil)
    if !(await wait({ !model.visible && !shelf.isVisible })) {
      failures.append("hover shelf stayed visible after outside window gained focus")
    }
    outside.close()
    await application.show("apps")
    await settle()
    NSApp.deactivate()
    if !(await wait({ !model.visible && !shelf.isVisible })) {
      failures.append("shelf stayed visible after application deactivation")
    }
    await application.show("clipboard")
    await settle()
    if let clip = model.clips.first(where: { $0.kind == "text" }) {
      model.selectedID = clip.id
      post(36, .command, "\r")
      if !(await wait({ model.previewID == clip.id })) {
        failures.append("posted Command Enter did not open clipboard preview")
      }
      post(18, .command, "1")
      if !(await wait({ model.transformation == "upperCase" })) {
        failures.append("posted Command1 did not transform preview")
      }
      await screenshot("clipboard-preview")
      if abs(shelf.frame.width - standardWidth) > 1 {
        failures.append("clipboard entry preview is wider than launcher")
      }
      post(53)
      if !(await wait({ model.previewID == nil })) {
        failures.append("posted Escape did not return preview to list")
      }
      let count = model.clips.count
      post(51, [.command, .shift])
      if !(await wait({ model.confirmClear })) {
        failures.append("posted Command Shift Backspace did not show clear confirmation")
      }
      await screenshot("clipboard-clear-confirmation")
      if abs(shelf.frame.width - standardWidth) > 1 {
        failures.append("clipboard clear confirmation is wider than launcher")
      }
      post(53)
      if !(await wait({ !model.confirmClear })) || model.clips.count != count {
        failures.append("clear confirmation cancellation changed history")
      }
    } else {
      failures.append("fixture has no text record for preview keyboard flow")
    }
    // Color/plain-text previews exercise the same real AppKit keyboard route and
    // synthetic clipboard as the other desktop flows, never the user's board.
    trace("color and plain-text previews")
    let previewFixtures: [(String, String)] = [
      ("color", "rgba(100, 160, 255, 0.5)"),
      ("plain", "Цвет #64a0ff упоминается в тексте.\nОбычный текст остаётся обычным текстом."),
      ("large", String(repeating: "x", count: 1_048_500)),
    ]
    for (name, content) in previewFixtures {
      do {
        try platform.history.add(.text, content: content, preview: String(content.prefix(400)))
      } catch {
        failures.append("cannot create \(name) preview fixture: \(error)")
        continue
      }
      platform.refresh()
      await application.show("clipboard")
      guard let clip = model.clips.first(where: { Data($0.content.utf8) == Data(content.utf8) })
      else {
        failures.append("missing \(name) preview fixture")
        continue
      }
      model.selectedID = clip.id
      let original = platform.history.snapshot()
      post(36, .command, "\r")
      if !(await wait({ model.previewID == clip.id })) {
        failures.append("Command Enter did not open \(name) preview")
      }
      guard
        let text = await nativeSmokeWaitForView(
          in: shelf, ofType: NSTextView.self,
          ready: {
            $0.accessibilityIdentifier() == "clipboard-preview-text"
              && Data($0.string.utf8) == Data(content.utf8)
          })
      else {
        failures.append("\(name) preview did not render exact selectable text")
        model.back()
        continue
      }
      if !text.isSelectable || text.isEditable || text.isAutomaticLinkDetectionEnabled {
        failures.append("\(name) preview text was not inert and selectable")
      }
      await screenshot("clipboard-preview-\(name)")
      if abs(shelf.frame.width - standardWidth) > 1 {
        failures.append("\(name) entry preview is wider than launcher")
      }
      platform.capture.write(text: "Synthetic preview copy sentinel")
      post(36, .shift, "\r")
      if !(await wait({
        !model.busy && Data(platform.capture.syntheticText.utf8) == Data(content.utf8)
      })) {
        failures.append("Shift Enter did not copy exact \(name) preview text")
      }
      if !model.visible { await application.show(nil) }
      platform.capture.write(text: "Synthetic preview select sentinel")
      post(36, [], "\r")
      if !(await wait({
        !model.busy && !model.visible
          && Data(platform.capture.syntheticText.utf8) == Data(content.utf8)
      })) {
        failures.append("Enter did not select exact \(name) preview text for paste")
      }
      if platform.history.snapshot() != original {
        failures.append("opening/copying \(name) preview changed stored history")
      }
      // A copy can close the shelf; reopen the preserved preview before returning.
      if !model.visible { await application.show(nil) }
      post(53)
      if !(await wait({ model.previewID == nil })) {
        failures.append("Escape did not return \(name) preview to history")
      }
    }
    await screenshot("clipboard-color-history")
    await application.show("snippets")
    await settle()
    if let snippet = model.snippets.first {
      model.selectedID = snippet.id
      post(36, .command, "\r")
      if !(await wait({ model.previewID == snippet.id })) {
        failures.append("posted Command Enter did not open snippet preview")
      }
      await screenshot("snippet-preview")
      if abs(shelf.frame.width - standardWidth) > 1 {
        failures.append("snippet entry preview is wider than launcher")
      }
      post(14, .command, "e")
      if !(await wait({ model.draft?.id == snippet.id })) {
        failures.append("posted Command E did not edit snippet from preview")
      }
      await screenshot("snippet-edit")
      if abs(shelf.frame.width - standardWidth) > 1 {
        failures.append("existing snippet editor is wider than launcher")
      }
      post(53)
      if !(await wait({ model.draft == nil })) {
        failures.append("posted Escape did not cancel existing snippet editor")
      }
      await application.show("snippets")
      await settle()
    }
    post(45, .command, "n")
    if !(await wait({ model.draft != nil })) {
      failures.append("posted CommandN did not create a snippet draft")
    }
    model.draft?.name = "Тестовый шаблон"
    model.draft?.content = "Несохранённый текст для проверки редактора."
    await screenshot("snippet-editor")
    if abs(shelf.frame.width - standardWidth) > 1 {
      failures.append("new snippet editor is wider than launcher")
    }
    post(53)
    if !(await wait({ model.draft == nil })) {
      failures.append("posted Escape did not cancel snippet editor")
    }
    await application.show("emoji")
    await settle()
    if let bar = await nativeSmokeWaitForView(
      in: shelf, ofType: NativeEmojiCategoryBar.self,
      ready: { $0.buttons.count == nativeEmojiCategories.count && $0.bounds.width > 0 }),
      let view = shelf.contentView
    {
      if bar.bounds.width < standardWidth - 32
        || bar.buttons.contains(where: { $0.bounds.width < 40 || $0.bounds.height < 36 })
      {
        failures.append("emoji category tabs are cramped")
      }
      // Creating the representables queues a separate search-focus request.
      // Sending Tab before it completes can target the departing snippet editor
      // or have the category focus overwritten by that queued request.
      if await nativeSmokeWaitForView(
        in: shelf, ofType: NSSearchField.self,
        ready: {
          guard let editor = $0.currentEditor() as? NSTextView else { return false }
          return $0.identifier?.rawValue == "polka-search" && shelf.isKeyWindow
            && shelf.firstResponder === editor && (editor.delegate as? NSTextField) === $0
        }) != nil
      {
        post(48, [], "\t")
        if !(await wait({ shelf.firstResponder === bar.buttons[0] })) {
          failures.append(
            "Tab from emoji search did not focus the selected category: \(keyboardState()); selected=\(bar.buttons[0].state.rawValue), enabled=\(bar.buttons[0].isEnabled), canBecomeKeyView=\(bar.buttons[0].canBecomeKeyView)"
          )
        }
      } else {
        failures.append("emoji search did not receive focus before Tab: \(keyboardState())")
      }
      click(bar.buttons[1])
      if !(await wait({ model.emojiCategory == "Smileys & Emotion" })) {
        failures.append("emoji category mouse click did not select smileys")
      }
      await screenshot("emoji-categories")
      if !shelf.makeFirstResponder(bar.buttons[1]) {
        failures.append("selected emoji category cannot receive keyboard focus")
      }
      post(124, repeatKey: true)
      await settle()
      if model.emojiCategory != "Smileys & Emotion" {
        failures.append("repeated emoji category arrow changed selection")
      }
      post(124)
      if !(await wait({ model.emojiCategory == "People & Body" })) {
        failures.append("emoji category ArrowRight did not select people")
      }
      post(119)
      if !(await wait({ model.emojiCategory == "Flags" })) {
        failures.append("emoji category End did not select flags")
      }
      post(124)
      if !(await wait({ model.emojiCategory == "all" })) {
        failures.append("emoji category ArrowRight did not wrap to all")
      }
      post(123)
      if !(await wait({ model.emojiCategory == "Flags" })) {
        failures.append("emoji category ArrowLeft did not wrap to flags")
      }
      post(115)
      if !(await wait({ model.emojiCategory == "all" })) {
        failures.append("emoji category Home did not select all")
      }
      if bar.buttons.filter({ $0.state == .on }).count != 1 {
        failures.append("emoji categories do not expose one selected tab")
      }
      model.busy = true
      await settle()
      click(bar.buttons[1])
      await settle()
      if model.emojiCategory != "all" {
        failures.append("busy emoji category button changed selection")
      }
      model.busy = false
      await settle()
      if let field = searchField(in: view) {
        shelf.makeFirstResponder(field)
        let editor = shelf.firstResponder
        click(bar.buttons[1])
        if !(await wait({ model.emojiCategory == "Smileys & Emotion" })) {
          failures.append("emoji category mouse click stayed disabled after busy state ended")
        }
        if shelf.firstResponder !== editor {
          failures.append("emoji category mouse click stole search editing focus")
        }
        click(bar.buttons[0])
        if !(await wait({ model.emojiCategory == "all" })) {
          failures.append("emoji category mouse click did not return to all")
        }
      }
      model.query = "no-such-synthetic-emoji-xyz"
      await settle()
      if !model.emojiResults.isEmpty { failures.append("empty emoji search returned results") }
      await screenshot("emoji-empty")
      model.query = ""
      await settle()
      await screenshot("emoji-all")
    } else {
      failures.append("emoji category tabs missing after layout: \(keyboardState())")
    }
    model.query = "heart"
    await settle()
    await screenshot("emoji")
    if let emoji = model.emojiResults.first {
      post(18, .command, "1")
      if !(await wait({
        !model.busy && platform.capture.syntheticText == emoji.value && !model.visible
      })) {
        failures.append("posted Command1 did not copy emoji and close shelf")
      }
    } else {
      failures.append("emoji fixture search did not find heart")
    }
    let fixtureRoot = URL(fileURLWithPath: platform.history.storage.state().path)
      .deletingLastPathComponent().appendingPathComponent("desktop-files")
    await platform.showIncomingFiles?()
    await settle()
    model.incomingFileDropPending = true
    platform.endIncomingFiles?()
    await settle()
    if !model.visible || !shelf.isVisible {
      failures.append("incomingEnd closed the shelf before file provider decoding finished")
    }
    model.incomingFileDropPending = false
    if !(await wait({ !model.visible && !shelf.isVisible })) {
      failures.append("cancelled incoming drag did not close after provider decoding ended")
    }
    await application.show("files")
    await settle()
    await screenshot("files-empty")
    model.incomingFileDropTargeted = true
    await screenshot("files-upload-zone")
    if !model.incomingFileDropTargeted || model.busy {
      failures.append("incoming file target did not retain its nonblocking drag state")
    }
    model.incomingFileDropTargeted = false
    do {
      try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
      let urls = [
        fixtureRoot.appendingPathComponent("Synthetic note.txt"),
        fixtureRoot.appendingPathComponent("Synthetic document.txt"),
      ]
      for url in urls { try Data("Synthetic desktop fixture".utf8).write(to: url) }
      try await platform.handle(NativeUICommand("shelf.files.add", ids: urls.map(\.path)))
      await application.show("files")
      await settle()
      if abs(shelf.frame.width - standardWidth) > 1 {
        failures.append("populated file shelf is wider than launcher")
      }
      post(0, .command, "a")
      if !(await wait({ model.selectedFiles.count == 2 })) {
        failures.append("posted CommandA did not select all file references")
      }
      await screenshot("files-selection")
      post(53)
      if !(await wait({ !model.visible && !shelf.isVisible && !model.busy })) {
        failures.append("selected file shelf did not finish closing")
      }
      await application.show(nil)
      await settle()
      if model.destination != "files" || model.selectedFiles.count != 2 {
        failures.append("file shelf did not resume multiple selection")
      }
      post(51, .command)
      if !(await wait({ !model.busy && platform.files.items.isEmpty })) {
        failures.append("posted Command Backspace did not remove selected file references")
      }
      if !urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
        failures.append("removing file references deleted synthetic originals")
      }
    } catch { failures.append("file fixture failed: " + error.localizedDescription) }
    model.error = ""
    await application.show("clipboard")
    await settle()
    return failures
  }
  // Disable every optional app using actual Settings focus navigation and Space.
  // The fixture's board and profiles remain synthetic throughout this flow.
  await application.show("snippets")
  await settle()
  model.createSnippet()
  model.draft?.name = "Disabled app draft"
  model.draft?.content = "Preserved while disabled"
  model.query = "disabled browse context"
  post(43, .command, "б")
  if !(await wait({ NSApp.keyWindow?.identifier?.rawValue == "polka-settings" && !model.busy })) {
    failures.append("Command comma with non-Latin layout did not open Settings")
  }
  if let settings = NSApp.windows.first(where: { $0.identifier?.rawValue == "polka-settings" }),
    let sidebar = await nativeSmokeWaitForView(in: settings, ofType: NSTableView.self)
  {
    settings.makeFirstResponder(sidebar)
    for _ in 0..<nativeSettingsPanes.count where model.settingsPane != "builtin-apps" {
      post(125, window: settings)
      await settle()
    }
    if model.settingsPane != "builtin-apps" {
      failures.append("ArrowDown could not reach Built-in apps Settings")
    }
    let settingsFrame = settings.frame
    settings.setContentSize(NSSize(width: 660, height: 480))
    await settle()
    var focused: NativeBuiltinAppSwitch?
    for _ in 0..<20 {
      post(48, window: settings)
      await settle()
      if let button = settings.firstResponder as? NativeBuiltinAppSwitch {
        focused = button
        break
      }
    }
    if focused == nil { failures.append("Tab did not reach a built-in app switch") }
    if let scroll = await nativeSmokeWaitForView(in: settings, ofType: NSScrollView.self),
      let document = scroll.documentView
    {
      document.scroll(NSPoint(x: 0, y: 24))
      await settle()
      if scroll.contentView.bounds.origin.y == 0 {
        failures.append("Settings stability fixture did not establish a nonzero scroll position")
      }
    } else {
      failures.append("Settings stability fixture is missing its scroll view")
    }
    // Track intermediate busy publications as well as final geometry: a brief
    // disable/re-enable flash can leave an identical final screenshot.
    var settingsBusyTransitions = 0
    let busyObservation = model.$busy.dropFirst().sink {
      if $0 { settingsBusyTransitions += 1 }
    }
    defer { busyObservation.cancel() }
    func settingsStability(excluding button: NativeBuiltinAppSwitch) -> () -> Void {
      let content = settings.contentView
      let row = sidebar.selectedRow
      let cells = nativeSettingsPanes.indices.compactMap { index in
        sidebar.view(atColumn: 0, row: index, makeIfNecessary: false).map { (index, $0) }
      }
      func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
      }
      let views = content.map(descendants) ?? []
      let switches = views.compactMap { $0 as? NativeBuiltinAppSwitch }.filter { $0 !== button }
      let states = switches.map(\.state)
      let scrolls = views.compactMap { $0 as? NSScrollView }
      let origins = scrolls.map { $0.contentView.bounds.origin }
      let busyBefore = settingsBusyTransitions
      let pairingCode = model.pairingCode
      return {
        if settingsBusyTransitions != busyBefore {
          failures.append("Settings toggle flashed window-wide busy feedback")
        }
        if settings.contentView !== content || sidebar.selectedRow != row
          || model.settingsPane != "builtin-apps"
        {
          failures.append("Settings toggle reconstructed content or changed the selected pane")
        }
        for (index, cell) in cells {
          if sidebar.view(atColumn: 0, row: index, makeIfNecessary: false) !== cell {
            failures.append("Settings toggle reconstructed unrelated sidebar cells")
          }
        }
        for (index, control) in switches.enumerated() {
          if control.window !== settings || !control.isEnabled || control.state != states[index] {
            failures.append("Settings toggle changed an unrelated switch")
          }
        }
        for (index, scroll) in scrolls.enumerated() {
          if scroll.window !== settings || scroll.contentView.bounds.origin != origins[index] {
            failures.append("Settings toggle lost its scroll position")
          }
        }
        if model.pairingCode != pairingCode {
          failures.append("Settings toggle lost unsaved pairing text")
        }
      }
    }
    model.pairingCode = "Unsaved synthetic pairing draft"
    if let button = focused {
      let action = model.action
      let verifyStability = settingsStability(excluding: button)
      model.action = { _ in throw PolkaCoreError.invalid("Synthetic settings write failure") }
      post(49, [], " ", window: settings)
      if !(await wait({ !model.commandPending && !model.error.isEmpty })) {
        failures.append("Failed settings write did not show its error")
      }
      await settle()
      if button.state != .on || settings.firstResponder !== button {
        failures.append("Failed settings write did not restore the switch value and focus")
      }
      verifyStability()
      model.action = action
      model.error = ""
      await settle()
    }
    var visited = Set<String>()
    for _ in 0..<4 {
      guard let button = settings.firstResponder as? NativeBuiltinAppSwitch else {
        failures.append(
          "Tab did not navigate between built-in app switches: \(keyboardState(settings))")
        break
      }
      let identifier = button.accessibilityIdentifier()
      let id = String(identifier.dropFirst("builtin-app-toggle-".count))
      visited.insert(id)
      let verifyStability = settingsStability(excluding: button)
      post(49, [], " ", window: settings)
      if !(await wait({ !model.settings.builtinApps.isEnabled(id) && !model.commandPending })) {
        failures.append("Space did not disable \(id)")
      }
      // Exercise consecutive Space presses through the same focused action.
      for enabled in [true, false] {
        post(49, [], " ", window: settings)
        if !(await wait({
          model.settings.builtinApps.isEnabled(id) == enabled && !model.commandPending
        })) {
          failures.append("Consecutive Space did not toggle \(id)")
        }
      }
      // A held Space must not repeatedly flip a focused toggle.
      if let repeatEvent = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: settings.windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49)
      {
        NSApp.postEvent(repeatEvent, atStart: false)
      }
      await settle()
      if model.settings.builtinApps.isEnabled(id) {
        failures.append("Repeated Space toggled \(id)")
      }
      if settings.firstResponder !== button {
        failures.append(
          "Switch lost focus after toggling \(id): enabled=\(button.isEnabled), attached=\(button.window === settings); \(keyboardState(settings))"
        )
      }
      verifyStability()
      post(48, window: settings)
      await settle()
    }
    if visited.count != 4 || !model.apps.filter({ $0.id.hasPrefix("builtin:") }).isEmpty {
      failures.append("Keyboard toggles did not independently disable all four built-in apps")
    }
    for destination in ["clipboard", "snippets", "files", "emoji", "toggle-clipboard"] {
      let previousKeyWindow = NSApp.keyWindow
      let previousDestination = model.destination
      await application.show(destination)
      // A blocked command must preserve the current surface and key window,
      // including when another application already took desktop focus.
      if model.visible || model.destination != previousDestination
        || NSApp.keyWindow !== previousKeyWindow
      {
        failures.append("Direct navigation reopened disabled \(destination)")
      }
    }
    if visited.count == 4 {
      await application.show(nil)
      await settle()
      if model.destination != "apps" || !model.visible {
        failures.append("Main shelf was unavailable with all optional apps disabled")
      }
      post(43, .command, "б")
      if !(await wait({ settings.isKeyWindow && !model.busy })) {
        failures.append("Settings was unavailable with all optional apps disabled")
      }
    }
    await screenshot("settings-builtin-apps-disabled", window: settings, includeTitlebar: true)
    // Re-enable with pointer events through the real AppKit event loop.
    for app in LauncherSearch.builtinApps {
      trace("find switch to re-enable \(app.id)")
      var reportedState = false
      if let button = await nativeSmokeWaitForView(
        in: settings, ofType: NativeBuiltinAppSwitch.self,
        ready: {
          guard $0.accessibilityIdentifier() == "builtin-app-toggle-" + app.id else { return false }
          if !reportedState {
            trace(
              "\(app.id): control enabled=\($0.isEnabled), state=\($0.state.rawValue), model enabled=\(model.settings.builtinApps.isEnabled(app.id)), canChange=\(model.canChangeBuiltinApps); \(keyboardState(settings))"
            )
            reportedState = true
          }
          return $0.isEnabled && $0.state == .off
        })
      {
        trace("post pointer events for \(app.id)")
        let verifyStability = settingsStability(excluding: button)
        for enabled in [true, false, true] {
          click(button)
          if !(await wait({
            model.settings.builtinApps.isEnabled(app.id) == enabled && !model.commandPending
          })) {
            failures.append("Consecutive pointer clicks did not toggle \(app.id)")
          }
        }
        await settle()
        verifyStability()
        trace("pointer input completed for \(app.id)")
      } else {
        failures.append("Missing built-in app switch: \(app.id)")
      }
    }
    busyObservation.cancel()
    settings.setFrame(settingsFrame, display: true)
    trace("render enabled built-in apps")
    await screenshot("settings-builtin-apps", window: settings, includeTitlebar: true)
    trace("restore snippets draft")
    settings.close()
    await application.show("snippets")
    await settle()
    if model.draft?.content != "Preserved while disabled"
      || model.query != "disabled browse context"
    {
      failures.append("Re-enabling snippets lost its draft or browsing context")
    }
    model.back()  // Deliberately discard only this synthetic draft.
    // Keep the existing Settings sidebar sequence starting from Clipboard.
  } else {
    failures.append("Settings controls missing for built-in app keyboard flow")
  }
  application.openSettings("clipboard")
  await settle()
  if let settings = NSApp.windows.first(where: { $0.identifier?.rawValue == "polka-settings" }) {
    await screenshot("settings-clipboard", window: settings)
    func table(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView { return table }
      for child in view.subviews { if let found = table(in: child) { return found } }
      return nil
    }
    if let view = settings.contentView, let sidebar = table(in: view) {
      let paneBeforeScrolling = model.settingsPane
      let rowFrames = nativeSettingsPanes.indices.map {
        sidebar.convert(sidebar.rect(ofRow: $0), to: nil)
      }
      for delta: Int32 in [-120, 120] {
        if let cg = CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
          wheel1: delta, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cg)
        {
          sidebar.scrollWheel(with: event)
          await settle()
          for row in nativeSettingsPanes.indices {
            if sidebar.convert(sidebar.rect(ofRow: row), to: nil) != rowFrames[row]
              || !sidebar.visibleRect.contains(sidebar.rect(ofRow: row))
            {
              failures.append("settings sidebar scrolling moved or hid pane \(row)")
            }
          }
          if model.settingsPane != paneBeforeScrolling {
            failures.append("settings sidebar scrolling changed selected pane")
          }
        } else {
          failures.append("cannot create settings sidebar wheel event")
        }
      }
      settings.makeFirstResponder(sidebar)
      for _ in 0..<nativeSettingsPanes.count where model.settingsPane != "about" {
        post(125, window: settings)
        await settle()
      }
      if !(await wait({ model.settingsPane == "about" })) {
        failures.append(
          "native settings sidebar ArrowDown did not select about: pane=\(model.settingsPane), row=\(sidebar.selectedRow); \(keyboardState(settings))"
        )
      }
      await screenshot("settings-about", window: settings)
      for _ in 0..<nativeSettingsPanes.count where model.settingsPane != "general" {
        post(126, window: settings)
        await settle()
      }
      if model.settingsPane != "general" {
        failures.append("native settings sidebar ArrowUp did not return to general")
      }
      await screenshot("settings-general", window: settings, includeTitlebar: true)
      post(125, window: settings)
      if !(await wait({ model.settingsPane == "shelf" })) {
        failures.append("native settings sidebar ArrowDown did not select shelf")
      }
      await screenshot("settings-shelf", window: settings, includeTitlebar: true)
      func recorder(in view: NSView) -> NativeShortcutCaptureView? {
        if let view = view as? NativeShortcutCaptureView { return view }
        for child in view.subviews { if let found = recorder(in: child) { return found } }
        return nil
      }
      if let content = settings.contentView, let recorder = recorder(in: content) {
        if recorder.bounds.width > 212 {
          failures.append("settings shortcut recorder overflows its aligned control column")
        }
        let originalShortcut = model.settings.launcherShortcut
        settings.makeFirstResponder(recorder)
        post(35, [.command, .option], "з", window: settings)
        if !(await wait({
          model.settings.launcherShortcut == "CommandOrControl+Alt+P" && !model.busy
        })) {
          failures.append("settings shortcut recorder did not handle a non-Latin physical key")
        }
        try? await platform.handle(
          NativeUICommand("launcher.setShortcut", strings: ["accelerator": originalShortcut]))
      } else {
        failures.append("settings launcher shortcut recorder missing")
      }
      settings.makeFirstResponder(sidebar)
      post(125, window: settings)
      if !(await wait({ model.settingsPane == "clipboard" })) {
        failures.append("native settings sidebar ArrowDown did not select clipboard")
      }
      let originalFrame = settings.frame
      settings.setContentSize(NSSize(width: 660, height: 480))
      await screenshot("settings-clipboard-compact", window: settings, includeTitlebar: true)
      settings.setFrame(originalFrame, display: true)
      // Render the expanded form using synthetic state only. Pairing is
      // not enabled on the platform and no LAN discovery is started.
      let originalContent = settings.contentView
      let previewModel = NativeUIModel()
      previewModel.settings = model.settings
      previewModel.settingsPane = "clipboard"
      previewModel.storageStatus = "ready"
      previewModel.preferencesAvailable = true
      previewModel.helperStatus = "running"
      previewModel.pasteAccess = "granted"
      previewModel.settings.syncEnabled = true
      previewModel.settings.syncStatus = "ready"
      previewModel.settings.deviceName = "Синтетический Mac"
      previewModel.settings.peers = [
        NativeUIPeer(id: "synthetic-peer", name: "Второй Mac", status: "connected")
      ]
      // A separate presentation model keeps the platform's maintenance
      // refresh from replacing the synthetic form while it is rendered.
      settings.contentView = NSHostingView(rootView: NativeSettingsView(model: previewModel))
      await settle()
      func document(in view: NSView) -> NSView? {
        if let scroll = view as? NSScrollView, !(scroll.documentView is NSTableView),
          scroll.documentView != nil
        {
          return scroll.documentView
        }
        for child in view.subviews { if let found = document(in: child) { return found } }
        return nil
      }
      if let content = settings.contentView, let document = document(in: content) {
        document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
      }
      await screenshot("settings-sync", window: settings)
      settings.contentView = originalContent
      settings.makeFirstResponder(sidebar)
      for _ in 0..<nativeSettingsPanes.count where model.settingsPane != "about" {
        post(125, window: settings)
        await settle()
      }
      if !(await wait({ model.settingsPane == "about" })) {
        failures.append("native settings sidebar did not return from sync to about")
      }
    } else {
      failures.append("native settings sidebar table missing")
    }
    let preservedPane = model.settingsPane
    settings.standardWindowButton(.closeButton)?.performClick(nil)
    if !(await wait({ !settings.isVisible })) {
      failures.append("settings traffic-light close did not close window")
    }
    application.openSettings(nil)
    await settle()
    if !settings.isVisible || NSApp.keyWindow !== settings || model.settingsPane != preservedPane {
      failures.append(
        "settings close/reopen did not reuse window and selected pane: pane=\(model.settingsPane), expected=\(preservedPane); \(keyboardState(settings))"
      )
    }
    if settings.titleVisibility != .hidden {
      failures.append("settings close/reopen restored unwanted title text")
    }
    post(13, .command, "w", window: settings)
    if !(await wait({ !settings.isVisible })) {
      failures.append("posted Command W did not close settings")
    }
    application.openSettings(nil)
    await settle()
    if NSApp.keyWindow !== settings || model.settingsPane != preservedPane {
      failures.append("Command W settings close/reopen lost persistent window context")
    }
    // Native editing uses the responder chain and the editor's undo manager.
    // Synthetic text never passes through the user's clipboard.
    let originalContent = settings.contentView
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
    editor.allowsUndo = true
    settings.contentView = editor
    settings.makeFirstResponder(editor)
    editor.insertText("Synthetic undo", replacementRange: NSRange(location: 0, length: 0))
    editor.breakUndoCoalescing()
    post(6, .command, "z", window: settings)
    if !(await wait({ editor.string.isEmpty })) {
      failures.append("posted Command Z did not use native editor undo")
    }
    post(6, [.command, .shift], "Z", window: settings)
    if !(await wait({ editor.string == "Synthetic undo" })) {
      failures.append(
        "posted Command Shift Z did not use native editor redo: canRedo=\(editor.undoManager?.canRedo ?? false), \(keyboardState(settings))"
      )
    }
    settings.contentView = originalContent
    settings.close()
  } else {
    failures.append("settings window was not created")
  }
  model.error = ""
  await application.show("clipboard")
  await settle()
  return failures
}

// Simulates the blocking Security lookup using only disposable fixture data.
final class NativeSmokeBlockedEncryption: EncryptionCodec {
  private let codec = SyntheticEncryptionCodec(key: Data(repeating: 0x71, count: 32))
  func encode(_ plaintext: Data) throws -> Data {
    Thread.sleep(forTimeInterval: 20)
    return try codec.encode(plaintext)
  }
  func decode(_ ciphertext: Data) throws -> Data { try codec.decode(ciphertext) }
}

@MainActor func nativeSmokePostQuit(_ window: NSWindow, characters: String = "q") {
  if let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
    keyCode: 12)
  {
    NSApp.postEvent(event, atStart: false)
  }
}

@MainActor func nativeSmokeStartupCloseFlows(
  application: NativeApplication, shelf: NSWindow,
  model: NativeUIModel, platform: NativePlatform
) async -> [String] {
  guard NativeProfile.isolatedFixture else { return ["startup smoke requires isolated profile"] }
  var failures: [String] = []
  try? await Task.sleep(nanoseconds: 100_000_000)
  if model.storageStatus != "starting" {
    failures.append("encryption fixture did not stay blocked at startup")
  }
  if let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [],
    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shelf.windowNumber,
    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)
  {
    NSApp.postEvent(event, atStart: false)
  }
  for _ in 0..<100 {
    if !model.visible && !shelf.isVisible { break }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  if model.visible || shelf.isVisible {
    failures.append("Escape failed while encryption startup was blocked")
  }
  await application.show("apps")
  if !shelf.isVisible { failures.append("could not reopen while encryption startup was blocked") }
  let outside = NSWindow(
    contentRect: NSRect(x: 30, y: 30, width: 160, height: 100), styleMask: [.titled],
    backing: .buffered, defer: false)
  outside.isReleasedWhenClosed = false
  outside.makeKeyAndOrderFront(nil)
  for _ in 0..<100 {
    if !model.visible && !shelf.isVisible { break }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  if model.visible || shelf.isVisible {
    failures.append("focus loss failed while encryption startup was blocked")
  }
  outside.close()
  await application.show("apps")
  try? await Task.sleep(nanoseconds: 100_000_000)
  if model.storageStatus != "starting" { failures.append("startup completed before close checks") }
  if FileManager.default.fileExists(atPath: platform.history.storage.state().path) {
    failures.append("startup preflight wrote an encrypted history file")
  }
  return failures
}

/// SwiftUI's virtual accessibility nodes do not all inherit NSObject or declare
/// NSAccessibilityProtocol conformance. Query their public Objective-C methods
/// dynamically, as AppKit does, rather than dropping nodes at a Swift cast.
private struct NativeSmokeAccessibility {
  let object: AnyObject
  var children: [Any] { object.accessibilityChildren?() ?? [] }
  func accessibilityIdentifier() -> String? { object.accessibilityIdentifier?() }
  func accessibilityLabel() -> String? { object.accessibilityLabel?() }
  func accessibilityHelp() -> String? { object.accessibilityHelp?() }
  func accessibilityRole() -> NSAccessibility.Role? { object.accessibilityRole?() }
  func accessibilityFrame() -> NSRect { object.accessibilityFrame?() ?? .zero }
  func isAccessibilityEnabled() -> Bool { object.isAccessibilityEnabled?() ?? false }
  func accessibilityPerformPress() { _ = object.accessibilityPerformPress?() }
}
