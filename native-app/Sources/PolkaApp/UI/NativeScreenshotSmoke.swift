import AppKit
import PolkaCore
import ScreenCaptureKit

/// Runs only inside the desktop runner's disposable profile. Capture input and
/// clipboard output are synthetic; keyboard, selection, editor, and save sheet
/// use actual AppKit windows and events.
@MainActor func nativeScreenshotSmoke(
  application: NativeApplication, shelf: NSWindow,
  platform: NativePlatform, directory: URL?
) async -> [String] {
  guard NativeProfile.isolatedFixture else { return ["screenshot smoke requires isolation"] }
  func trace(_ text: String) {
    FileHandle.standardError.write(Data("Screenshot smoke: \(text)\n".utf8))
  }
  trace("start")
  var failures: [String] = []
  let model = platform.model
  func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }
  func wait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<80 {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return predicate()
  }
  func key(
    _ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String, _ window: NSWindow,
    repeatKey: Bool = false
  ) {
    if let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: repeatKey, keyCode: code)
    {
      NSApp.postEvent(event, atStart: false)
    }
  }
  func typeText(_ value: String, in window: NSWindow) {
    let codes: [Character: UInt16] = [
      "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
      "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
      "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
      "w": 13, "x": 7, "y": 16, "z": 6, " ": 49,
      "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
    for character in value {
      let lower = Character(String(character).lowercased())
      guard let code = codes[lower] else { continue }
      key(code, character == lower ? [] : .shift, String(character), window)
    }
  }
  func mouse(
    _ type: NSEvent.EventType, _ point: CGPoint, _ window: NSWindow,
    immediate: Bool = false, modifiers: NSEvent.ModifierFlags = []
  ) {
    if let event = NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    {
      if immediate {
        NSApp.sendEvent(event)
      } else {
        NSApp.postEvent(event, atStart: false)
      }
    }
  }
  func shift(_ held: Bool, in window: NSWindow) {
    if let event = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: held ? .shift : [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)
    {
      NSApp.postEvent(event, atStart: false)
    }
  }
  func accessible(_ id: String, in source: Any) -> AnyObject? {
    let object = source as AnyObject
    if object.accessibilityIdentifier?() == id { return object }
    for child in object.accessibilityChildren?() ?? [] {
      if let found = accessible(id, in: child) { return found }
    }
    if let view = object as? NSView {
      for child in view.subviews {
        if let found = accessible(id, in: child) { return found }
      }
    }
    return nil
  }
  func numberField(_ id: String, in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let field = view as? NSTextField, field.identifier?.rawValue == id { return field }
    return view.subviews.compactMap { numberField(id, in: $0) }.first
  }
  func typeNumber(_ value: String, field id: String, in window: NSWindow) async {
    guard let field = numberField(id, in: window.contentView) else {
      failures.append("missing editable number field: \(id)")
      return
    }
    let point = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
    mouse(.leftMouseDown, point, window)
    mouse(.leftMouseUp, point, window)
    await settle()
    key(0, .command, "a", window)
    typeText(value, in: window)
    key(36, [], "\r", window)
    await settle()
  }
  func screenshot(_ window: NSWindow, name: String) async {
    guard let directory else { return }
    await settle()
    let url = directory.appendingPathComponent(name + ".png")
    if ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_WINDOW_CAPTURE"] == "1" {
      do {
        var arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        if !window.isOpaque {
          let frame = NativeScreenshotCapture.captureRect(
            window.frame,
            desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
          arguments = [
            "-x",
            "-R\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",
            url.path,
          ]
        }
        _ = try await NativeCommand.run(
          URL(fileURLWithPath: "/usr/sbin/screencapture"), arguments: arguments, timeout: 10)
        return
      } catch { failures.append("cannot capture screenshot UI: \(error)") }
    }
    guard let view = window.contentView?.superview,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
      failures.append("cannot render screenshot UI")
      return
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
  }
  func canvas(_ view: NSView?) -> NativeScreenshotCanvas? {
    guard let view else { return nil }
    if let result = view as? NativeScreenshotCanvas { return result }
    return view.subviews.compactMap { canvas($0) }.first
  }
  guard
    let context = CGContext(
      data: nil, width: 800, height: 480, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else {
    return ["cannot create screenshot fixture"]
  }
  context.setFillColor(NSColor.white.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: 800, height: 480))
  context.setFillColor(NSColor.systemBlue.cgColor)
  context.fill(CGRect(x: 40, y: 360, width: 720, height: 70))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  NSAttributedString(
    string: "Account settings",
    attributes: [
      .font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.white,
    ]
  )
  .draw(at: CGPoint(x: 60, y: 380))
  NSAttributedString(
    string: "Email address:   private@example.test",
    attributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
  )
  .draw(at: CGPoint(x: 60, y: 280))
  NSGraphicsContext.restoreGraphicsState()
  guard let image = context.makeImage() else { return ["cannot create screenshot fixture image"] }
  // Two adjacent synthetic display panels exercise a drag beyond its starting window.
  let desktop = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
  let displayFrames = [
    CGRect(x: desktop.minX, y: desktop.minY, width: 400, height: desktop.height),
    CGRect(
      x: desktop.minX + 400, y: desktop.minY,
      width: desktop.width - 400, height: desktop.height),
  ]
  var selectedRegion: CGRect?
  var capturedWindow: (id: CGWindowID, omitShadow: Bool, image: CGImage)?
  platform.screenshots.captureImage = {
    switch await platform.screenshots.captureService.selectTarget(screenFrames: displayFrames) {
    case .region(let region):
      selectedRegion = region
      return image
    case .window(let id, let omitShadow, _):
      let content = try await SCShareableContent.currentProcess
      let window = try await NativeScreenshotCapture.captureWindow(
        id, omitShadow: omitShadow, in: content)
      capturedWindow = (id, omitShadow, window)
      return window
    case nil:
      return nil
    }
  }
  defer {
    platform.screenshots.captureImage = nil
    platform.screenshots.suspend()
  }
  // Use the actual global hotkey path in the isolated guest. The fixture
  // substitutes only captured pixels and clipboard writes.
  let directShortcut = GlobalShortcuts()
  defer { directShortcut.stop() }
  var shortcutInvocations = 0
  do {
    try directShortcut.set(
      "screenshots.copy", accelerator: model.settings.screenshotCopyShortcut, persist: {},
      action: {
        shortcutInvocations += 1
        platform.performScreenshotShortcut(copyImmediately: true)
      })
  } catch { return ["could not register direct screenshot shortcut: \(error)"] }
  func copyShortcut(down: Bool) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 21, keyDown: down)
    event?.flags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
    event?.post(tap: .cghidEventTap)
  }
  trace("direct copy shortcut")
  await application.show("clipboard")
  guard await wait({ shelf.isKeyWindow && model.visible }) else {
    return ["could not open the clipboard shelf before screenshot capture"]
  }
  let clipboardRevision = platform.capture.clipboardRevision
  copyShortcut(down: true)
  if !(await wait { NSApp.keyWindow?.contentView is NativeScreenshotSelectionView }) {
    copyShortcut(down: false)
    return ["direct copy global shortcut did not open region selection"]
  }
  // Repeated press events must not start a second capture.
  copyShortcut(down: true)
  await settle()
  copyShortcut(down: false)
  if shortcutInvocations != 1 { failures.append("direct copy shortcut repeated while held") }
  await application.show("toggle")
  await application.show("toggle-clipboard")
  if !(NSApp.keyWindow?.contentView is NativeScreenshotSelectionView) {
    failures.append("launcher toggle took focus from screenshot selection")
  }
  if !shelf.isVisible || !model.visible {
    failures.append("direct copy shortcut hid the open shelf during region selection")
  } else if model.busy {
    failures.append("direct copy shortcut put the open shelf into a loading state")
  } else {
    await screenshot(shelf, name: "screenshot-open-shelf")
  }
  if let panel = NSApp.keyWindow {
    mouse(.leftMouseDown, CGPoint(x: 100, y: 100), panel)
    mouse(.leftMouseDragged, CGPoint(x: 700, y: 500), panel)
    await screenshot(panel, name: "screenshot-direct-copy-selection")
    mouse(.leftMouseUp, CGPoint(x: 700, y: 500), panel)
  }
  if !(await wait { !model.commandPending && !model.screenshotCapturing }) {
    failures.append("direct screenshot copy did not finish")
  }
  if !(await wait { shelf.isKeyWindow && model.visible }) {
    failures.append("direct screenshot copy did not return keyboard focus to the open shelf")
  }
  if platform.capture.clipboardRevision != clipboardRevision + 1
    || !platform.capture.syntheticTypes.contains("public.png")
    || !platform.screenshots.editors.isEmpty
  {
    failures.append("direct capture did not copy immediately without an editor")
  }
  let expectedPNG = try? NativeScreenshotDocument(source: image).png().base64EncodedString()
  if !platform.history.snapshot().clips.contains(where: {
    $0.kind == .image && $0.content == expectedPNG
  }) {
    failures.append("direct screenshot copy did not enter history")
  }
  await application.show("clipboard")
  // Let the shelf's presentation animation finish before capturing the artifact.
  try? await Task.sleep(nanoseconds: 300_000_000)
  await screenshot(shelf, name: "screenshot-direct-copy-result")
  copyShortcut(down: true)
  copyShortcut(down: false)
  if await wait({ NSApp.keyWindow?.contentView is NativeScreenshotSelectionView }),
    let panel = NSApp.keyWindow
  {
    key(53, [], "\u{1b}", panel)
    _ = await wait { !model.commandPending && !model.screenshotCapturing }
  } else {
    failures.append("direct copy shortcut could not be used again after release")
  }
  if platform.capture.clipboardRevision != clipboardRevision + 1
    || !platform.screenshots.editors.isEmpty
  {
    failures.append("cancelling direct screenshot changed clipboard or created an editor")
  }
  if !(await wait { shelf.isKeyWindow && model.visible }) {
    failures.append("cancelling direct screenshot did not restore keyboard focus to the open shelf")
  }
  trace("window selection and capture")
  do {
    // The Shelf sits above normal windows. Keep both test points below it and
    // inside the same selection panel even on the hosted runner's smaller display.
    let fixtureCenter = CGPoint(
      x: displayFrames[1].midX, y: (desktop.minY + shelf.frame.minY) / 2)
    let background = NSWindow(
      contentRect: CGRect(
        x: fixtureCenter.x - 180, y: fixtureCenter.y - 120, width: 360, height: 240),
      styleMask: .borderless, backing: .buffered, defer: false)
    let foreground = NSWindow(
      contentRect: CGRect(
        x: fixtureCenter.x - 40, y: fixtureCenter.y - 75, width: 180, height: 150),
      styleMask: .borderless, backing: .buffered, defer: false)
    background.backgroundColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    foreground.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    background.orderFrontRegardless()
    foreground.orderFrontRegardless()
    defer {
      platform.screenshots.captureService.finish(nil)
      foreground.orderOut(nil)
      background.orderOut(nil)
    }
    let revision = platform.capture.clipboardRevision
    copyShortcut(down: true)
    copyShortcut(down: false)
    guard await wait({ NSApp.keyWindow?.contentView is NativeScreenshotSelectionView }),
      let keyboardPanel = NSApp.keyWindow,
      let panel = NSApp.windows.first(where: {
        $0.isVisible && $0.contentView is NativeScreenshotSelectionView
          && $0.frame == displayFrames[1]
      }), let view = panel.contentView as? NativeScreenshotSelectionView
    else { return failures + ["window capture did not open the selector"] }

    key(49, [], " ", keyboardPanel)
    key(49, [], " ", keyboardPanel, repeatKey: true)
    let coveredPoint = panel.convertPoint(fromScreen: fixtureCenter)
    mouse(.mouseMoved, coveredPoint, panel)
    if !(await wait { view.selection?.targetWindow?.id == CGWindowID(foreground.windowNumber) }) {
      let hit = NSWindow.windowNumber(
        at: panel.convertPoint(toScreen: coveredPoint),
        belowWindowWithWindowNumber: panel.windowNumber)
      failures.append(
        "window capture did not highlight the frontmost window after Space (hit \(hit), expected \(foreground.windowNumber))"
      )
    }
    key(49, [], " ", keyboardPanel)
    if !(await wait { view.selection?.selectsWindow == false }) {
      failures.append("Space did not switch back to region selection")
    }
    key(49, [], " ", keyboardPanel)
    let exposedPoint = panel.convertPoint(
      fromScreen: CGPoint(x: fixtureCenter.x - 120, y: fixtureCenter.y))
    mouse(.mouseMoved, exposedPoint, panel)
    if !(await wait { view.selection?.targetWindow?.id == CGWindowID(background.windowNumber) }) {
      failures.append("window highlight did not follow the pointer")
    }
    await screenshot(panel, name: "screenshot-window-selection")
    mouse(.leftMouseDown, exposedPoint, panel)
    mouse(.leftMouseUp, exposedPoint, panel)
    guard await wait({ !model.commandPending && !model.screenshotCapturing }) else {
      return failures + ["window capture did not finish"]
    }
    if let capturedWindow, capturedWindow.id == CGWindowID(background.windowNumber) {
      let pixels = NSBitmapImageRep(cgImage: capturedWindow.image)
      if let pixel = pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)?
        .usingColorSpace(.sRGB), pixel.greenComponent > 0.7, pixel.redComponent < 0.4
      {
        let png = try? NativeScreenshotDocument(source: capturedWindow.image).png()
        if let directory, let png {
          try? png.write(to: directory.appendingPathComponent("screenshot-window-capture.png"))
        }
        if platform.capture.clipboardRevision != revision + 1
          || !platform.screenshots.editors.isEmpty
        {
          failures.append("window capture did not copy directly to the clipboard")
        }
      } else {
        failures.append("the captured window included pixels from the overlapping window")
      }
    } else {
      failures.append("click did not capture the highlighted window: \(model.error)")
    }

    capturedWindow = nil
    foreground.orderFrontRegardless()
    platform.performScreenshotShortcut()
    guard await wait({ NSApp.keyWindow?.contentView is NativeScreenshotSelectionView }),
      let keyboardPanel = NSApp.keyWindow,
      let panel = NSApp.windows.first(where: {
        $0.isVisible && $0.contentView is NativeScreenshotSelectionView
          && $0.frame == displayFrames[1]
      }), let view = panel.contentView as? NativeScreenshotSelectionView
    else { return failures + ["window capture and edit did not open the selector"] }
    key(49, [], " ", keyboardPanel)
    let pointer = panel.convertPoint(toScreen: coveredPoint)
    let top = NSScreen.screens.first?.frame.maxY ?? desktop.maxY
    let priorPointer = NSEvent.mouseLocation
    func moveSystemPointer(_ point: CGPoint) {
      CGEvent(
        mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: CGPoint(x: point.x, y: top - point.y), mouseButton: .left
      )?.post(tap: .cghidEventTap)
    }
    defer { moveSystemPointer(priorPointer) }
    moveSystemPointer(pointer)
    guard await wait({ view.selection?.targetWindow?.id == CGWindowID(foreground.windowNumber) })
    else {
      return failures + [
        "keyboard capture did not highlight the foreground window (target \(view.selection?.targetWindow?.id ?? 0), expected \(foreground.windowNumber), window mode \(view.selection?.selectsWindow == true))"
      ]
    }
    key(36, .option, "\r", keyboardPanel)
    if await wait({ !model.commandPending && platform.screenshots.editors.count == 1 }),
      let editor = platform.screenshots.editors.values.first,
      let window = editor.window
    {
      if capturedWindow?.id != CGWindowID(foreground.windowNumber)
        || capturedWindow?.omitShadow != true
      {
        failures.append(
          "Option-Return captured window \(capturedWindow?.id ?? 0) with omitShadow=\(capturedWindow?.omitShadow ?? false), expected window \(foreground.windowNumber) with omitShadow=true"
        )
      }
      await screenshot(window, name: "screenshot-window-editor")
      key(53, [], "\u{1b}", window)
      if !(await wait { platform.screenshots.editors.isEmpty }) {
        failures.append("Escape did not close the window screenshot editor")
      }
    } else {
      failures.append("Return did not open the editor for the highlighted window: \(model.error)")
    }
  }
  directShortcut.stop()
  await application.show("apps", query: "Screenshots")
  guard let screenshotRow = model.searchResults.first(where: { $0.id == "builtin:screenshots" })
  else { return failures + ["missing Screenshots result in the shelf"] }
  model.activateSearch(screenshotRow)
  if await wait({ NSApp.keyWindow?.contentView is NativeScreenshotSelectionView }),
    let panel = NSApp.keyWindow
  {
    if shelf.isVisible || model.visible {
      failures.append("opening Screenshots from the shelf left the shelf visible")
    }
    key(53, [], "\u{1b}", panel)
    _ = await wait { !model.commandPending && !model.screenshotCapturing }
  } else {
    failures.append("opening Screenshots from the shelf did not start region selection")
  }
  await application.show("clipboard")
  platform.performScreenshotShortcut()
  await settle()
  trace("capture")
  if !(await wait { NSApp.keyWindow?.contentView is NativeScreenshotSelectionView }) {
    return ["screenshot capture shortcut did not open region selection"]
  }
  guard
    let selection = NSApp.windows.first(where: {
      $0.contentView is NativeScreenshotSelectionView && $0.frame == displayFrames[0]
    })
  else { return ["missing region selection window"] }
  for panel in NSApp.windows where panel.contentView is NativeScreenshotSelectionView {
    if panel.areCursorRectsEnabled {
      failures.append("capture panel allows automatic cursor resets")
    }
    for x in [120.0, 140.0, 160.0] {
      NSCursor.arrow.set()
      panel.resetCursorRects()
      // Dispatch through AppKit and inspect the result in the same main-actor
      // turn. A delayed check can observe a subsequent WindowServer cursor
      // update rather than the synthetic move we are testing.
      mouse(.mouseMoved, CGPoint(x: x, y: 130), panel, immediate: true)
      let view = panel.contentView as? NativeScreenshotSelectionView
      if !platform.screenshots.captureService.cursorHidden {
        failures.append("capture exposed system pointer during movement")
      }
      let expected = panel.convertPoint(toScreen: CGPoint(x: x, y: 130))
      if view?.selection?.pointer != expected {
        failures.append(
          "capture crosshair did not follow movement across displays: expected=\(expected), actual=\(String(describing: view?.selection?.pointer)), panel=\(panel.frame), key=\(panel.isKeyWindow), mouse=\(NSEvent.mouseLocation)"
        )
      }
      // A competing cursor request between movement events must stay invisible.
      NSCursor.arrow.set()
      if !platform.screenshots.captureService.cursorHidden {
        failures.append("competing cursor update exposed an arrow during capture")
      }
      await settle()
    }
  }
  mouse(.leftMouseDown, CGPoint(x: 100, y: 100), selection)
  mouse(.leftMouseDragged, CGPoint(x: 700, y: 500), selection)
  await settle()
  if let adjacentPanel = NSApp.windows.first(where: {
    $0.isVisible && $0.contentView is NativeScreenshotSelectionView && $0.frame == displayFrames[1]
  }), let adjacentView = adjacentPanel.contentView as? NativeScreenshotSelectionView {
    if adjacentView.selection?.rect?.width != 600 {
      failures.append("cross-display selection was not shared with the adjacent panel")
    }
    await screenshot(adjacentPanel, name: "screenshot-region-pointer")
  } else {
    failures.append("missing adjacent display selection panel")
  }
  mouse(.leftMouseUp, CGPoint(x: 700, y: 500), selection)
  if !(await wait { !model.commandPending && platform.screenshots.editors.count == 1 }) {
    return failures + [
      "region selection did not create an editable screenshot: region=\(String(describing: selectedRegion)), pending=\(model.commandPending), editors=\(platform.screenshots.editors.count)"
    ]
  }
  if selectedRegion?.width != 600 || selectedRegion?.height != 400 {
    failures.append("cross-display capture was clipped at the starting display edge")
  }
  trace("editor")
  guard let editor = platform.screenshots.editors.values.first,
    let window = editor.window
  else { return ["missing screenshot editor"] }
  let shot = editor.shot
  await settle()
  if !shelf.isVisible || !model.visible || model.destination != "clipboard" {
    failures.append("capture and edit shortcut did not preserve the open clipboard shelf")
  }
  if NSCursor.current != .arrow || platform.screenshots.captureService.cursorHidden

  {
    failures.append("completed capture did not restore regular system pointer")
  }
  guard let canvas = canvas(window.contentView) else { return ["missing annotation canvas"] }
  key(20, .command, "3", window)
  await settle()
  func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    canvas.convert(
      CGPoint(
        x: canvas.imageRect.minX + x * canvas.imageRect.width / shot.size.width,
        y: canvas.imageRect.minY + y * canvas.imageRect.height / shot.size.height), to: nil)
  }
  let a = point(210, 275)
  let b = point(620, 312)
  mouse(.leftMouseDown, a, window)
  mouse(.leftMouseDragged, b, window)
  mouse(.leftMouseUp, b, window)
  await settle()
  if shot.marks.count != 1 || shot.marks.first?.kind != .rectangle {
    failures.append("rectangle gesture did not edit screenshot")
  }
  if shot.objectDraft?.id != shot.marks.first?.id {
    failures.append("new rectangle did not remain selected")
  }
  key(53, [], "", window)
  await settle()
  if shot.objectDraft != nil || !window.isVisible || shot.marks.count != 1 {
    failures.append("Escape did not deselect new rectangle and preserve capture")
  }
  await screenshot(window, name: "screenshot-rectangle-outline")
  mouse(.leftMouseDown, a, window)
  mouse(.leftMouseUp, a, window)
  await settle()
  await typeNumber("8", field: "screenshot-rectangle-width", in: window)
  if let content = window.contentView,
    let checkbox = accessible("screenshot-rectangle-filled", in: content)
  {
    _ = checkbox.accessibilityPerformPress?()
  } else {
    failures.append("missing rectangle fill checkbox")
  }
  shot.style.rectangleColor = .systemBlue
  await settle()
  if shot.pendingObject?.style.rectangleWidth != 8
    || shot.pendingObject?.style.rectangleFilled != true
  {
    failures.append("selected rectangle style did not update")
  }
  await screenshot(window, name: "screenshot-rectangle-filled")
  shot.finishObject()
  window.makeFirstResponder(canvas)
  key(6, .command, "я", window)
  await settle()
  if shot.marks.first?.style.rectangleFilled != false {
    failures.append("rectangle style undo failed")
  }
  key(6, .command, "я", window)
  await settle()
  if !shot.marks.isEmpty { failures.append("screenshot undo shortcut failed") }
  key(6, [.command, .shift], "Я", window)
  await settle()
  if shot.marks.count != 1 { failures.append("screenshot redo shortcut failed") }
  mouse(.leftMouseDown, a, window)
  mouse(.leftMouseUp, a, window)
  await settle()
  mouse(.leftMouseDown, point(210, 312), window)
  mouse(.leftMouseDragged, point(200, 322), window)
  mouse(.leftMouseUp, point(200, 322), window)
  await settle()
  if abs((shot.pendingObject?.start.x ?? 0) - 200) > 1
    || abs((shot.pendingObject?.end.y ?? 0) - 322) > 1
  {
    failures.append("rectangle upper-left handle did not resize independently")
  }
  key(6, .command, "я", window)
  await settle()
  mouse(.leftMouseDown, a, window)
  mouse(.leftMouseUp, a, window)
  await settle()
  mouse(.leftMouseDown, point(620, 275), window)
  mouse(.leftMouseDragged, point(630, 265), window)
  mouse(.leftMouseUp, point(630, 265), window)
  await settle()
  if abs((shot.pendingObject?.end.x ?? 0) - 630) > 1
    || abs((shot.pendingObject?.start.y ?? 0) - 265) > 1
  {
    failures.append("rectangle lower-right handle did not resize independently")
  }
  await screenshot(window, name: "screenshot-rectangle-four-corners")
  key(6, .command, "я", window)
  await settle()
  shot.style.arrowColor = .systemBlue
  shot.style.arrowWidth = 6
  key(18, .command, "1", window)
  await settle()
  mouse(.leftMouseDown, point(140, 140), window)
  mouse(.leftMouseDragged, point(300, 255), window)
  mouse(.leftMouseUp, point(300, 255), window)
  await settle()
  if shot.objectDraft?.id != shot.marks.last?.id {
    failures.append("new arrow did not remain selected")
  }
  await screenshot(window, name: "screenshot-arrow-options")
  key(53, [], "", window)
  await settle()
  if shot.objectDraft != nil || !window.isVisible || shot.marks.count != 2 {
    failures.append("Escape did not deselect new arrow and preserve capture")
  }
  shot.style.textColor = .white
  shot.style.textBackground = .systemBlue
  shot.style.textSize = 26
  key(19, .command, "2", window)
  await settle()
  mouse(.leftMouseDown, point(340, 155), window)
  mouse(.leftMouseUp, point(340, 155), window)
  await settle()
  if window.firstResponder !== canvas.textEditor || canvas.textEditor == nil {
    failures.append("clicking the image did not focus inline text input")
  }
  typeText("Review this field", in: window)
  await settle()
  if shot.label != "Review this field" { failures.append("inline typing did not enter text") }
  key(6, .command, "z", window)
  await settle()
  if shot.label == "Review this field" || shot.marks.count != 2 {
    failures.append(
      "inline text undo did not use text editing history: \(shot.label.debugDescription); canUndo=\(canvas.textEditor?.undoManager?.canUndo == true)"
    )
  }
  key(6, [.command, .shift], "Z", window)
  await settle()
  if shot.label != "Review this field" { failures.append("inline text redo failed") }
  key(36, [], "\r", window)
  typeText("Before sharing", in: window)
  await settle()
  if shot.label != "Review this field\nBefore sharing" {
    failures.append("inline Return did not insert a new line")
  }
  await screenshot(window, name: "screenshot-inline-text")
  key(36, .command, "\r", window)
  await settle()
  if canvas.textEditor != nil { failures.append("Command Return did not finish inline text") }
  // Escape commits text, and a click outside only finishes the active edit.
  mouse(.leftMouseDown, point(80, 80), window)
  mouse(.leftMouseUp, point(80, 80), window)
  await settle()
  typeText("Keep this", in: window)
  await settle()
  key(53, [], "\u{1b}", window)
  await settle()
  if canvas.textEditor != nil || shot.marks.last?.text != "Keep this" {
    failures.append("Escape did not preserve inline text")
  }
  mouse(.leftMouseDown, point(85, 70), window)
  mouse(.leftMouseUp, point(85, 70), window)
  await settle()
  key(36, [], "\r", window)
  await settle()
  mouse(.leftMouseDown, point(700, 70), window)
  mouse(.leftMouseUp, point(700, 70), window)
  await settle()
  if canvas.textEditor != nil || shot.marks.count != 4 {
    failures.append("clicking outside text created an unwanted text block")
  }
  mouse(.leftMouseDown, point(85, 70), window)
  mouse(.leftMouseUp, point(85, 70), window)
  await settle()
  key(36, [], "\r", window)
  await settle()
  key(0, .command, "a", window)
  key(51, [], "\u{7f}", window)
  await settle()
  key(53, [], "\u{1b}", window)
  await settle()
  if shot.marks.count != 3 { failures.append("emptying text did not delete its block") }
  if shot.marks.map(\.kind) != [.rectangle, .arrow, .text] {
    failures.append("screenshot annotation tools did not share keyboard and mouse state")
  }
  if shot.marks.last?.style.textSize != 26
    || shot.marks.last?.style.textBackground != .systemBlue
    || shot.marks.dropFirst().first?.style.arrowWidth != 6
  {
    failures.append("annotation gestures did not preserve chosen styles")
  }
  // Leave the Text tool, return later, and edit the same object through real input.
  let originalTextID = shot.marks.last?.id
  key(18, .command, "1", window)
  await settle()
  mouse(.leftMouseDown, point(350, 145), window)
  mouse(.leftMouseUp, point(350, 145), window)
  await settle()
  if shot.objectDraft?.id != originalTextID || canvas.textEditor != nil {
    failures.append("single-clicking text entered editing instead of selecting it")
  }
  mouse(.leftMouseDown, point(350, 145), window)
  mouse(.leftMouseDragged, point(380, 175), window)
  mouse(.leftMouseUp, point(380, 175), window)
  await settle()
  if shot.marks.last?.id != originalTextID || abs((shot.marks.last?.start.x ?? 0) - 370) > 1 {
    failures.append("dragging text did not move its existing object")
  }
  await screenshot(window, name: "screenshot-move-text")
  key(36, [], "\r", window)
  await settle()
  if shot.editingTextID != originalTextID
    || canvas.textEditor?.string != "Review this field\nBefore sharing"
  {
    failures.append("clicking placed text did not reopen its existing object")
  }
  key(0, .command, "a", window)
  typeText("Updated text", in: window)
  await settle()
  await typeNumber("30", field: "screenshot-text-size", in: window)
  if shot.style.textSize != 30 { failures.append("typed text size was not applied") }
  shot.style.textColor = .black
  shot.style.textBackground = .systemYellow
  await settle()
  await screenshot(window, name: "screenshot-edit-existing-text")
  key(36, .command, "\r", window)
  await settle()
  if shot.marks.count != 3 || shot.marks.last?.id != originalTextID
    || shot.marks.last?.text != "Updated text" || shot.marks.last?.style.textSize != 30
  {
    failures.append("editing placed text duplicated the block or lost its properties")
  }
  key(6, .command, "я", window)
  await settle()
  if shot.marks.last?.text != "Review this field\nBefore sharing" {
    failures.append("undo did not restore the previous text object")
  }
  key(6, [.command, .shift], "Я", window)
  await settle()
  if shot.marks.last?.text != "Updated text" { failures.append("redo did not restore text edits") }
  // Select an arrow while the Text creation tool is active, then move both endpoints.
  key(19, .command, "2", window)
  await settle()
  mouse(.leftMouseDown, point(220, 197.5), window)
  mouse(.leftMouseUp, point(220, 197.5), window)
  await settle()
  let arrowID = shot.marks[1].id
  if shot.objectDraft?.id != arrowID || shot.tool != .text {
    failures.append("arrow selection depended on the active creation tool")
  }
  shot.style.arrowColor = .systemPurple
  await typeNumber("12", field: "screenshot-arrow-width", in: window)
  if shot.style.arrowWidth != 12 { failures.append("typed arrow width was not applied") }
  await settle()
  mouse(.leftMouseDown, point(140, 140), window)
  mouse(.leftMouseDragged, point(110, 120), window)
  mouse(.leftMouseUp, point(110, 120), window)
  await settle()
  mouse(.leftMouseDown, point(300, 255), window)
  mouse(.leftMouseDragged, point(330, 265), window)
  mouse(.leftMouseUp, point(330, 265), window)
  await settle()
  if shot.marks[1].id != arrowID || abs(shot.marks[1].start.x - 110) > 1
    || abs(shot.marks[1].end.x - 330) > 1 || shot.marks[1].style.arrowWidth != 12
  {
    failures.append("arrow endpoint editing lost identity, geometry, or style")
  }
  key(48, [], "\t", window)
  key(124, [.shift], "", window)
  await settle()
  if abs((shot.pendingObject?.start.x ?? 0) - 120) > 1 {
    failures.append("selected arrow keyboard movement failed")
  }
  await screenshot(window, name: "screenshot-edit-arrow")
  _ = editor.finishText()
  await settle()
  key(6, .command, "я", window)
  await settle()
  if abs(shot.marks[1].start.x - 110) > 1 { failures.append("arrow move undo failed") }
  key(6, [.command, .shift], "Я", window)
  await settle()
  for mark in shot.marks {
    shot.selectObject(mark)
    window.makeFirstResponder(canvas)
    key(51, [], "\u{7f}", window)
    await settle()
    if shot.marks.contains(where: { $0.id == mark.id }) {
      failures.append("Backspace did not delete \(mark.kind)")
    }
    key(6, .command, "я", window)
    await settle()
    if !shot.marks.contains(where: { $0.id == mark.id }) {
      failures.append("undo did not restore deleted object")
    }
  }
  trace("direct capture resize")
  let originalArea = shot.area
  let originalMarks = shot.marks
  let edge = canvas.convert(CGPoint(x: canvas.imageRect.minX, y: canvas.imageRect.minY), to: nil)
  mouse(.leftMouseDown, edge, window)
  mouse(.leftMouseDragged, CGPoint(x: edge.x + 80, y: edge.y + 50), window)
  mouse(.leftMouseUp, CGPoint(x: edge.x + 80, y: edge.y + 50), window)
  await settle()
  if shot.area.width >= originalArea.width || window.attachedSheet != nil {
    failures.append("direct resize did not shrink area without a sheet")
  }
  let beforeMove = shot.area
  let side = canvas.convert(
    CGPoint(x: canvas.imageRect.minX, y: canvas.imageRect.minY + canvas.imageRect.height * 0.25),
    to: nil)
  if canvas.pointer(at: CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY)) != .arrow {
    failures.append("selected screenshot area did not use regular arrow cursor")
  }
  let localSide = canvas.convert(side, from: nil)
  if canvas.pointer(at: localSide) != .openHand {
    failures.append("selection border did not offer move cursor")
  }
  let handlePoints = NativeScreenshotArea(shot).points(canvas.imageRect)
  for (index, point) in handlePoints.enumerated() {
    if canvas.areaTarget(at: point) != index
      || canvas.pointer(at: point) == .openHand
    {
      failures.append("selection handle did not offer resize cursor")
    }
  }
  mouse(.leftMouseDown, side, window)
  await settle()
  if canvas.pointer(at: localSide) != .closedHand {
    failures.append("moving selection did not retain native closed-hand cursor")
  }
  mouse(.leftMouseDragged, CGPoint(x: side.x - 20, y: side.y - 15), window)
  mouse(.leftMouseUp, CGPoint(x: side.x - 20, y: side.y - 15), window)
  await settle()
  if shot.area.size != beforeMove.size || shot.area.origin == beforeMove.origin {
    failures.append("dragging selection border did not move area without resizing")
  }
  key(6, .command, "я", window)
  await settle()
  if shot.area != beforeMove { failures.append("undo did not restore moved screenshot area") }
  await screenshot(window, name: "screenshot-direct-resize")
  key(6, .command, "я", window)
  await settle()
  if shot.area != originalArea || shot.marks != originalMarks {
    failures.append("direct resize undo lost geometry")
  }
  key(6, [.command, .shift], "Я", window)
  await settle()
  let smaller = canvas.convert(CGPoint(x: canvas.imageRect.minX, y: canvas.imageRect.minY), to: nil)
  mouse(.leftMouseDown, smaller, window)
  mouse(.leftMouseDragged, edge, window)
  mouse(.leftMouseUp, edge, window)
  await settle()
  if shot.area != originalArea {
    failures.append("direct resize could not expand to original screen")
  }
  key(15, .command, "к", window)
  key(124, [], "", window)
  await settle()
  if shot.area == originalArea || window.attachedSheet != nil {
    failures.append("keyboard resize did not adjust area directly")
  }
  key(6, .command, "я", window)
  await settle()
  let resizedMarks = shot.marks
  key(53, [], "\u{1b}", window)
  await settle()
  guard window.isVisible, !canvas.areaKeyboard, shot.marks == resizedMarks else {
    return failures + ["Escape did not exit keyboard resize while preserving the screenshot"]
  }
  shot.adjustArea(shot.fullBounds.insetBy(dx: 100, dy: 100))
  await settle()
  await screenshot(window, name: "screenshot-compact-outside")
  shot.undo()
  await settle()
  await screenshot(window, name: "screenshot-compact-inside")
  shot.adjustArea(
    CGRect(
      x: 100, y: 100, width: shot.fullBounds.width - 200,
      height: shot.fullBounds.height - 135))
  await settle()
  await screenshot(window, name: "screenshot-toolbar-top-edge")
  shot.undo()
  await settle()
  trace("save")
  key(1, .command, "ы", window)
  if !(await wait { window.attachedSheet != nil }) {
    failures.append("screenshot save shortcut did not open save sheet")
  }
  editor.savePanel?.cancel(nil)
  _ = await wait { !shot.busy && window.attachedSheet == nil }
  await settle()
  if shot.marks.count != 3 { failures.append("canceling screenshot save discarded edits") }
  trace("save")
  key(1, .command, "ы", window)
  if await wait({ editor.savePanel != nil && window.attachedSheet != nil }),
    let panel = editor.savePanel
  {
    // Complete the real sheet through AppKit's modal-response API. Remote save
    // panels cannot reliably receive synthetic keys on hosted runners; opening
    // and cancelling the sheet above still exercise the keyboard path.
    let saveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-screenshot-save-" + UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: saveDirectory, withIntermediateDirectories: true)
    } catch { return failures + ["could not create screenshot save fixture: \(error)"] }
    defer { try? FileManager.default.removeItem(at: saveDirectory) }
    panel.directoryURL = saveDirectory
    await settle()
    trace("confirm save")
    window.endSheet(panel, returnCode: .OK)
    trace("save confirmed")
    if !(await wait { !shot.busy }) {
      panel.cancel(nil)
      return failures + ["saving screenshot did not finish"]
    }
    do {
      guard let saved = panel.url else {
        throw PolkaCoreError.invalid("Save panel returned no destination")
      }
      if shot.message != localized("Image Saved") {
        failures.append("screenshot save did not report success: \(shot.message)")
      }
      if try Data(contentsOf: saved) != shot.png() {
        failures.append("saved screenshot differed from flattened preview")
      }
      try FileManager.default.removeItem(at: saved)
    } catch { failures.append("screenshot save failed: \(error)") }
  } else {
    failures.append("cannot reopen screenshot save sheet")
  }
  trace("capture editor window")
  await screenshot(window, name: "screenshot-editor")
  trace("file shelf")
  key(1, [.command, .shift], "Ы", window)
  if !(await wait { model.destination == "files" && !model.files.isEmpty }) {
    failures.append("screenshot was not added to file shelf")
  }
  if let file = model.files.last {
    do {
      if try Data(contentsOf: URL(fileURLWithPath: file.path)) != shot.png() {
        failures.append("file shelf did not receive flattened screenshot")
      }
      _ = try platform.files.drag([file.id])
    } catch { failures.append("screenshot file shelf export failed: \(error)") }
    platform.files.remove([file.id])
  }
  if window.isVisible || !platform.screenshots.editors.isEmpty {
    failures.append("file shelf export did not close screenshot")
  }
  do {
    let copied = try platform.screenshots.insert(shot.rendered(includingDraft: true))
    if copied.style.arrowWidth != 12 || copied.style.rectangleWidth != 8
      || !copied.style.rectangleFilled || copied.style.textSize != 30
    {
      failures.append(
        "new screenshot did not remember the edited annotation widths, fill, and text size")
    }
    guard let copying = platform.screenshots.editors[copied.id], let copyWindow = copying.window
    else {
      return failures + ["missing copy fixture editor"]
    }
    await settle()
    await screenshot(copyWindow, name: "screenshot-remembered-style")
    key(8, .command, "с", copyWindow)
    await settle()
    if copyWindow.isVisible || !platform.screenshots.editors.isEmpty {
      failures.append("copy did not close screenshot")
    }
    if !platform.capture.syntheticTypes.contains("public.png")
      || !platform.history.snapshot().clips.contains(where: {
        $0.kind == .image && $0.content == (try? copied.png().base64EncodedString())
      })
    {
      failures.append("copied screenshot missing from clipboard or history")
    }
    let discarded = try platform.screenshots.insert(shot.source)
    guard let closing = platform.screenshots.editors[discarded.id], let closeWindow = closing.window
    else {
      return failures + ["missing discard fixture editor"]
    }
    await settle()
    key(53, [], "\u{1b}", closeWindow)
    await settle()
    if closeWindow.isVisible || !platform.screenshots.editors.isEmpty {
      failures.append("closing screenshot retained its capture")
    }
  } catch { failures.append("screenshot copy/close fixtures failed: \(error)") }
  await application.show("files")
  Task { await application.show("screenshots") }
  if !(await wait { NSApp.keyWindow?.contentView is NativeScreenshotSelectionView }) {
    failures.append("opening Screenshots did not start a fresh capture")
  } else {
    await settle()
    if !shelf.isVisible || !model.visible {
      failures.append("the menu bar screenshot action hid the open shelf")
    }
  }
  platform.screenshots.captureService.finish(nil)
  await settle()
  if !platform.screenshots.editors.isEmpty {
    failures.append("cancelled capture created an editor")
  }
  if ProcessInfo.processInfo.environment["POLKA_NATIVE_REAL_DISPLAY_CAPTURE"] == "1" {
    failures += await nativeScreenshotDisplaySmoke(captures: platform.screenshots) {
      await screenshot($0, name: $1)
    }
  }
  platform.refresh()
  // Exercise the live overlay too: static preview fixtures cannot catch a
  // transparent WindowServer input surface or live coordinate regressions.
  do {
    let live = try platform.screenshots.insert(
      image, area: CGRect(x: 100, y: 100, width: 800, height: 400),
      screenFrame: desktop, desktopFrame: desktop)
    if let liveEditor = platform.screenshots.editors[live.id], let liveWindow = liveEditor.window {
      await settle()
      guard let liveCanvas = liveEditor.canvas else {
        return failures + ["live screenshot canvas missing"]
      }
      let center = liveWindow.convertPoint(
        toScreen: liveCanvas.convert(
          CGPoint(x: liveCanvas.imageRect.midX, y: liveCanvas.imageRect.midY), to: nil))
      if !(await wait({
        NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0)
          == liveWindow.windowNumber
      })) {
        let hit = NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0)
        failures.append(
          "live screenshot area does not receive WindowServer mouse input (hit \(hit), expected \(liveWindow.windowNumber))"
        )
      }
      var from = liveCanvas.convert(
        CGPoint(x: liveCanvas.imageRect.midX - 40, y: liveCanvas.imageRect.midY), to: nil)
      func heading(from start: CGPoint, to end: CGPoint) -> CGFloat {
        atan2(end.y - start.y, end.x - start.x) * 180 / .pi
      }
      for tool in [NativeScreenshotMark.Kind.arrow, .rectangle] {
        let to = CGPoint(x: from.x + 80, y: from.y + 30)
        live.finishObject()
        live.tool = tool
        mouse(.leftMouseDown, from, liveWindow)
        mouse(.leftMouseDragged, to, liveWindow, modifiers: .shift)
        mouse(.leftMouseUp, to, liveWindow, modifiers: .shift)
        await settle()
        // Leave room for the larger arrowhead from the remembered stroke width.
        from.y -= 140
      }
      if live.marks.count == 2 {
        let arrow = live.marks[0]
        let rectangle = live.marks[1]
        let square = NativeScreenshotDocument.rect(rectangle.start, rectangle.end)
        if abs(heading(from: arrow.start, to: arrow.end) - 15) > 0.01
          || abs(square.width - square.height) > 0.01
        {
          failures.append(
            "Shift drag did not snap the arrow to 15 degrees and the rectangle to a square")
        }
      } else {
        failures.append("live overlay did not create annotations")
      }
      await screenshot(liveWindow, name: "screenshot-live-interaction")

      key(21, .command, "4", liveWindow)
      if await wait({ live.tool == .line }) {
        await typeNumber("7", field: "screenshot-line-width", in: liveWindow)
        // Draw beside the other marks so the drag and endpoint edit fit on smaller displays.
        let selection = liveCanvas.imageRect
        let from = liveCanvas.convert(
          CGPoint(
            x: (selection.minX + selection.width * 0.65).rounded(), y: selection.midY.rounded()),
          to: nil)
        let end = CGPoint(x: from.x + 120, y: from.y + 30)
        let startPoint = liveCanvas.imagePoint(liveCanvas.convert(from, from: nil))
        let rawEnd = liveCanvas.imagePoint(liveCanvas.convert(end, from: nil))
        mouse(.leftMouseDown, from, liveWindow)
        mouse(.leftMouseDragged, end, liveWindow)
        if let startPoint, let rawEnd, await wait({ liveCanvas.drawingEnd == rawEnd }) {
          shift(true, in: liveWindow)
          if !(await wait {
            guard let preview = liveCanvas.drawingEnd else { return false }
            return abs(heading(from: startPoint, to: preview) - 15) < 0.01
          }) {
            failures.append("pressing Shift during a stationary drag did not snap the line preview")
          }
          shift(false, in: liveWindow)
          if !(await wait { liveCanvas.drawingEnd == rawEnd }) {
            failures.append(
              "releasing Shift during a stationary drag did not restore the line preview")
          }
        } else {
          failures.append("line drag did not show its unsnapped preview")
        }
        mouse(.leftMouseUp, end, liveWindow, modifiers: .shift)
        await settle()
        let lineAngle = live.marks.last.map { heading(from: $0.start, to: $0.end) }
        if live.marks.map(\.kind) != [.arrow, .rectangle, .line]
          || live.marks.last?.style.lineWidth != 7
          || abs((lineAngle ?? 0) - 15) > 0.01
        {
          failures.append("line tool did not commit a snapped annotation with the chosen width")
        }
        if let directory, let image = try? live.rendered() {
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
          try? png?.write(
            to: directory.appendingPathComponent("screenshot-snapped-annotations.png"))
        }
        await screenshot(liveWindow, name: "screenshot-line-tool")
        if let original = live.marks.last, original.kind == .line {
          let image = liveCanvas.imageRect
          let scale = image.width / live.size.width
          let handle = liveCanvas.convert(
            CGPoint(x: image.minX + original.end.x * scale, y: image.minY + original.end.y * scale),
            to: nil)
          let target = CGPoint(x: handle.x, y: handle.y - 90)
          mouse(.leftMouseDown, handle, liveWindow)
          mouse(.leftMouseDragged, target, liveWindow, modifiers: .shift)
          mouse(.leftMouseUp, target, liveWindow, modifiers: .shift)
          await settle()
          if let edited = live.marks.last, edited.id == original.id, edited.start == original.start,
            abs(heading(from: edited.start, to: edited.end) + 30) < 0.01
          {
            if let directory, let image = try? live.rendered() {
              let png = NSBitmapImageRep(cgImage: image).representation(
                using: .png, properties: [:])
              try? png?.write(to: directory.appendingPathComponent("screenshot-edited-snap.png"))
            }
            key(6, .command, "z", liveWindow)
            if !(await wait { live.marks.last == original }) {
              failures.append("undo did not restore the line after Shift-dragging its endpoint")
            }
          } else {
            failures.append(
              "Shift-dragging an existing line endpoint did not snap around the fixed end")
          }
        }
        key(6, .command, "z", liveWindow)
        if !(await wait { live.marks.map(\.kind) == [.arrow, .rectangle] }) {
          failures.append("undo did not remove the line annotation")
        }
      } else {
        failures.append("Command-4 did not select the line tool")
      }
      liveEditor.discard()
    }
  } catch { failures.append("live overlay interaction failed: \(error)") }
  await application.show("clipboard")
  return failures
}
