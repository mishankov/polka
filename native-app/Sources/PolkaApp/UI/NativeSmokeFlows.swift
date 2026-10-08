import AppKit
import Foundation
import PolkaCore
import SwiftUI

/// Runs only in the app-owned, isolated desktop fixture. All keys are posted to
/// this process's real AppKit event loop, and every copy uses the injected board.
@MainActor func nativeSmokeAdditionalFlows(
  application: NativeApplication, shelf: NSWindow, model: NativeUIModel, platform: NativePlatform
) async -> [String] {
  guard NativeProfile.isolatedFixture else { return ["native smoke requires an isolated profile"] }
  var failures: [String] = []
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
  func settle() async { try? await Task.sleep(nanoseconds: 230_000_000) }
  func keyboardState(_ owner: NSWindow? = nil) -> String {
    let window = owner ?? shelf
    let text = window.firstResponder as? NSTextView
    return
      "destination=\(model.destination), query=\(model.query), visible=\(model.visible)/\(window.isVisible), busy=\(model.busy), key=\(window.isKeyWindow), keyWindow=\(String(describing: NSApp.keyWindow)), active=\(NSApp.isActive), hidden=\(NSApp.isHidden), firstResponder=\(String(describing: window.firstResponder)), delegate=\(String(describing: text?.delegate)), marked=\(text?.hasMarkedText() ?? false), sheet=\(window.attachedSheet != nil), modal=\(NSApp.modalWindow != nil), menuTracking=\(NSMenuTrackingState.shared.active); lifecycle trace:\n\(application.smokeLifecycleTrace.suffix(20).joined(separator: "\n"))"
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
    if !(await wait({ model.visible && shelf.isVisible && shelf.isKeyWindow && NSApp.isActive })) {
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
    post(53)
    if !(await wait({ !model.confirmClear })) || model.clips.count != count {
      failures.append("clear confirmation cancellation changed history")
    }
  } else {
    failures.append("fixture has no text record for preview keyboard flow")
  }
  await application.show("snippets")
  await settle()
  post(45, .command, "n")
  if !(await wait({ model.draft != nil })) {
    failures.append("posted CommandN did not create a snippet draft")
  }
  model.draft?.name = "Тестовый шаблон"
  model.draft?.content = "Несохранённый текст для проверки редактора."
  await screenshot("snippet-editor")
  post(53)
  if !(await wait({ model.draft == nil })) {
    failures.append("posted Escape did not cancel snippet editor")
  }
  await application.show("emoji")
  await settle()
  func categoryBar(in view: NSView) -> NativeEmojiCategoryBar? {
    if let bar = view as? NativeEmojiCategoryBar { return bar }
    for child in view.subviews { if let bar = categoryBar(in: child) { return bar } }
    return nil
  }
  if let view = shelf.contentView, let bar = categoryBar(in: view),
    bar.buttons.count == nativeEmojiCategories.count
  {
    if bar.bounds.width < standardWidth - 32
      || bar.buttons.contains(where: { $0.bounds.width < 40 || $0.bounds.height < 36 })
    {
      failures.append("emoji category tabs are cramped")
    }
    post(48, [], "\t")
    if !(await wait({ shelf.firstResponder === bar.buttons[0] })) {
      failures.append("Tab from emoji search did not focus the selected category")
    }
    bar.buttons[1].performClick(nil)
    if !(await wait({ model.emojiCategory == "Smileys & Emotion" })) {
      failures.append("emoji category button did not select smileys")
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
    bar.buttons[1].performClick(nil)
    if model.emojiCategory != "all" {
      failures.append("busy emoji category button changed selection")
    }
    model.busy = false
    await settle()
    if let field = searchField(in: view) { shelf.makeFirstResponder(field) }
    model.query = "no-such-synthetic-emoji-xyz"
    await settle()
    if !model.emojiResults.isEmpty { failures.append("empty emoji search returned results") }
    await screenshot("emoji-empty")
    model.query = ""
    await settle()
    await screenshot("emoji-all")
  } else {
    failures.append("emoji category tabs missing")
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
      settings.makeFirstResponder(sidebar)
      post(125, window: settings)
      if !(await wait({ model.settingsPane == "about" })) {
        failures.append("native settings sidebar ArrowDown did not select about")
      }
      await screenshot("settings-about", window: settings)
      for _ in 0..<3 {
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
      post(125, window: settings)
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
      failures.append("settings close/reopen did not reuse window and selected pane")
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
