import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

private final class NativeDropDriverState: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func fail(_ value: String) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }
  var failures: [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

/// Read only window ownership/geometry. Never inspect another application's pixels.
private func nativeDropFixtureOwns(_ point: CGPoint, windows: Set<Int>, pid: pid_t) -> Bool {
  guard
    let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID) as? [[String: Any]]
  else { return false }
  let maximumLayer =
    info.filter { windows.contains(($0[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1) }
    .map { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 }.max() ?? -1
  for value in info {
    guard let number = value[kCGWindowNumber as String] as? NSNumber,
      let owner = value[kCGWindowOwnerPID as String] as? NSNumber,
      let layer = value[kCGWindowLayer as String] as? NSNumber,
      (value[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0.01,
      let dictionary = value[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
      bounds.contains(point)
    else { continue }
    // Only our process's transient drag-image windows may sit above the
    // fixed fixture pair. Foreign popups and system dialogs always block.
    if layer.intValue > maximumLayer && owner.int32Value == pid
      && !windows.contains(number.intValue)
    {
      continue
    }
    return owner.int32Value == pid && windows.contains(number.intValue)
  }
  return false
}

/// Fixture-only source and receiver; uses the session's private drag pasteboard.
@MainActor private final class NativeDropFixtureView: NSView, NSDraggingSource {
  var urls: [URL] = []
  var started = 0
  var ended = 0
  var operation: NSDragOperation = []
  var received: [String] = []
  var endedPoint = NSPoint.zero
  private var down: NSEvent?
  private var active = false
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError("fixture is programmatic") }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { down = event }
  override func mouseDragged(with event: NSEvent) {
    guard !active, down != nil else { return }
    active = true
    started += 1
    let items = urls.enumerated().map { index, url in
      let item = NSDraggingItem(pasteboardWriter: url as NSURL)
      item.setDraggingFrame(
        NSRect(x: 30 + index * 3, y: 30, width: 32, height: 32),
        contents: NSWorkspace.shared.icon(forFile: url.path))
      return item
    }
    let session = beginDraggingSession(with: items, event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = false
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { [.copy, .link] }
  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    self.operation = operation
    endedPoint = screenPoint
    ended += 1
    active = false
    down = nil
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let values =
      sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    received = values.map(\.path)
    return !received.isEmpty
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.darkGray.setFill()
    bounds.fill()
    "Synthetic drag source / receiver".draw(
      at: NSPoint(x: 15, y: 110),
      withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13)])
  }
}
@MainActor private final class NativeDropFixturePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor func nativeFileDropSmoke(
  application: NativeApplication, shelf: NSWindow, model: NativeUIModel
) async -> [String: Any] {
  guard NativeProfile.isolatedFixture else {
    return ["ok": false, "failures": ["file drop smoke requires isolated profile"]]
  }
  guard AXIsProcessTrusted() else {
    return [
      "ok": false,
      "failures": [
        "real drag fixture requires an already granted Accessibility permission; no grant was requested"
      ],
    ]
  }
  let driver = NativeDropDriverState()
  var failures: [String] = []
  var targets: [[String: Any]] = []
  let root = NativeProfile.path().appendingPathComponent("synthetic-file-drop", isDirectory: true)
  do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) } catch
  { return ["ok": false, "failures": ["cannot create synthetic files"]] }
  let originalCursor = CGEvent(source: nil)?.location
  defer { if let originalCursor { CGWarpMouseCursorPosition(originalCursor) } }
  let warpFailures = 0
  var serial = 0
  func files(_ count: Int) -> [URL] {
    (0..<count).map { _ in
      serial += 1
      let url = root.appendingPathComponent(String(format: "synthetic-%03d.txt", serial))
      do { try Data("Synthetic native file drop \(serial)".utf8).write(to: url) } catch {
        failures.append("cannot write synthetic file")
      }
      return url
    }
  }
  let screen = shelf.screen ?? NSScreen.main!
  // Cover the complete cursor path with this fixture-owned background window;
  // the shelf remains above it. No drag enters another application's window.
  let sourceRect = NSRect(
    x: screen.visibleFrame.minX + 20,
    y: max(screen.visibleFrame.minY, shelf.frame.minY - 10),
    width: max(270, shelf.frame.midX - screen.visibleFrame.minX + 10),
    height: max(
      200, screen.visibleFrame.maxY - max(screen.visibleFrame.minY, shelf.frame.minY - 10)))
  let source = NativeDropFixturePanel(
    contentRect: sourceRect,
    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
  source.isReleasedWhenClosed = false
  source.level = .floating
  source.hidesOnDeactivate = false
  source.title = "Polka synthetic file drag"
  let sourceView = NativeDropFixtureView(frame: NSRect(origin: .zero, size: sourceRect.size))
  source.contentView = sourceView
  source.orderFrontRegardless()
  defer { source.close() }
  func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }
  func wait(_ predicate: () -> Bool, seconds: Double = 4) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return predicate()
  }
  func event(
    _ type: NSEvent.EventType, window: NSWindow, point: NSPoint, flags: NSEvent.ModifierFlags = []
  ) {
    if let event = NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    {
      NSApp.postEvent(event, atStart: false)
    } else {
      failures.append("cannot construct synthetic mouse event")
    }
  }
  func drag(from window: NSWindow, point: NSPoint, to targetWindow: NSWindow, target: NSPoint) {
    let a = window.convertPoint(toScreen: point)
    let b = targetWindow.convertPoint(toScreen: target)
    let top = NSScreen.screens[0].frame.maxY
    let from = CGPoint(x: a.x, y: top - a.y)
    let to = CGPoint(x: b.x, y: top - b.y)
    let pid = getpid()
    let windows = Set([source.windowNumber, shelf.windowNumber])
    DispatchQueue.global(qos: .userInitiated).async {
      let source = CGEventSource(stateID: .combinedSessionState)
      func send(_ type: CGEventType, _ position: CGPoint) {
        CGEvent(
          mouseEventSource: source, mouseType: type,
          mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cgSessionEventTap)
      }
      guard nativeDropFixtureOwns(from, windows: windows, pid: pid) else {
        driver.fail("source window ownership changed before drag")
        return
      }
      send(.mouseMoved, from)
      Thread.sleep(forTimeInterval: 0.10)
      send(.leftMouseDown, from)
      defer {
        // Always release. If ownership changed, cancel into our still-owned source
        // instead of releasing test files over a foreign application.
        if nativeDropFixtureOwns(to, windows: windows, pid: pid) {
          send(.leftMouseUp, to)
        } else if nativeDropFixtureOwns(from, windows: windows, pid: pid) {
          send(.leftMouseDragged, from)
          send(.leftMouseUp, from)
        } else {
          driver.fail("fixture windows disappeared during drag")
          CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.postToPid(pid)
          CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.postToPid(pid)
          Thread.sleep(forTimeInterval: 0.05)
          send(.leftMouseUp, CGEvent(source: nil)?.location ?? from)
        }
      }
      for step in 1...30 {
        let fraction = Double(step) / 30
        let position = CGPoint(
          x: from.x + (to.x - from.x) * fraction,
          y: from.y + (to.y - from.y) * fraction)
        guard nativeDropFixtureOwns(position, windows: windows, pid: pid) else {
          driver.fail("window ownership changed during drag")
          return
        }
        send(.leftMouseDragged, position)
        Thread.sleep(forTimeInterval: 0.025)
      }
      Thread.sleep(forTimeInterval: 0.55)
    }
  }

  func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
  }
  func diagnose(_ point: NSPoint) -> [String: Any] {
    guard let content = shelf.contentView else { return ["hitView": "missing"] }
    let hit = content.hitTest(content.convert(point, from: nil))
    var chain: [[String: Any]] = []
    var current = hit
    while let view = current {
      chain.append([
        "class": String(describing: type(of: view)),
        "registeredDraggedTypes": view.registeredDraggedTypes.map(\.rawValue),
      ])
      current = view.superview
    }
    return [
      "windowClass": String(describing: type(of: shelf)),
      "hitView": hit.map { String(describing: type(of: $0)) } ?? "none",
      "viewChain": chain, "x": point.x, "y": point.y,
    ]
  }
  func clear() async {
    do { try await model.action?(NativeUICommand("shelf.files.clear")) } catch {
      failures.append("cannot clear synthetic shelf")
    }
    _ = await wait { model.files.isEmpty && !model.busy }
  }
  func incoming(_ label: String, point: NSPoint, count: Int = 1) async {
    let urls = files(count)
    sourceView.urls = urls
    sourceView.received = []
    let expected = shelf.convertPoint(toScreen: point)
    let started = sourceView.started
    let ended = sourceView.ended
    var record = diagnose(point)
    record["name"] = label
    var targeted = false
    drag(from: source, point: NSPoint(x: 45, y: 45), to: shelf, target: point)
    let completed = await wait {
      targeted = targeted || model.incomingFileDropTargeted
      return sourceView.ended > ended
    }
    let added = await wait(
      { Set(model.files.map(\.path)).isSuperset(of: urls.map(\.path)) }, seconds: 2)
    record["sessionStarted"] = sourceView.started > started
    record["sessionCompleted"] = completed
    record["operation"] = sourceView.operation.rawValue
    record["expectedEnd"] = ["x": expected.x, "y": expected.y]
    record["actualEnd"] = ["x": sourceView.endedPoint.x, "y": sourceView.endedPoint.y]
    record["sourceReceived"] = sourceView.received
    record["highlightObserved"] = targeted
    record["accepted"] = added
    record["highlightCleared"] = !model.incomingFileDropTargeted
    record["paths"] = urls.map(\.path)
    targets.append(record)
    if sourceView.started <= started {
      failures.append("\(label): real NSDraggingSession did not begin")
    }
    if !completed { failures.append("\(label): drag session did not finish") }
    if hypot(sourceView.endedPoint.x - expected.x, sourceView.endedPoint.y - expected.y) > 4 {
      failures.append("\(label): native drag ended away from requested target")
    }
    if !sourceView.received.isEmpty {
      failures.append("\(label): source received its own incoming files")
    }
    if !targeted { failures.append("\(label): incoming drop highlight was never routed") }
    if model.incomingFileDropTargeted {
      failures.append("\(label): incoming highlight stayed after drop")
    }
    if !added || sourceView.operation.isEmpty {
      failures.append("\(label): routed file drop rejected")
    }
    await settle()
  }
  await application.show("files")
  await settle()
  guard let content = shelf.contentView else {
    return ["ok": false, "failures": ["shelf content missing"]]
  }
  let bounds = content.convert(content.bounds, to: nil)
  let center = NSPoint(x: bounds.midX, y: bounds.midY)
  let bottom = NSPoint(x: bounds.midX, y: bounds.minY + 28)
  let header = NSPoint(x: bounds.midX, y: bounds.maxY - model.topInset - 26)
  // Each empty target uses a new real drag and distinct file identity.
  for (name, point) in [("empty-center", center), ("empty-bottom", bottom), ("header", header)] {
    await clear()
    await incoming(name, point: point)
  }
  await incoming("populated-center-two-files", point: center, count: 2)
  if let row = descendants(content, NativeFileDragView.self).first {
    let point = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
    await incoming("populated-row", point: point)
  } else {
    failures.append("no populated row for routing regression")
  }
  await incoming("scroll-populated-body", point: center, count: 20)
  var outgoingStarts = 0
  let originalStarted = model.fileDragStarted
  model.fileDragStarted = {
    outgoingStarts += 1
    originalStarted?()
  }
  defer { model.fileDragStarted = originalStarted }
  // Ordinary row clicks and wheel events must remain available under the drop target.
  var rows = descendants(content, NativeFileDragView.self).filter {
    !$0.isHidden && $0.visibleRect.height > 5
  }
  var clickWorks = false
  var scrollWorks = false
  var outgoingWorks = false
  if rows.count >= 2, let first = rows[0].file, let second = rows[1].file {
    let p1 = rows[0].convert(NSPoint(x: 90, y: rows[0].bounds.midY), to: nil)
    let p2 = rows[1].convert(NSPoint(x: 90, y: rows[1].bounds.midY), to: nil)
    event(.leftMouseDown, window: shelf, point: p1)
    event(.leftMouseUp, window: shelf, point: p1)
    _ = await wait { model.selectedFiles == [first.id] }
    event(.leftMouseDown, window: shelf, point: p2, flags: .command)
    event(.leftMouseUp, window: shelf, point: p2, flags: .command)
    clickWorks = await wait { model.selectedFiles == Set([first.id, second.id]) }
    if let scroll = descendants(content, NSScrollView.self).first {
      let before = scroll.contentView.bounds.origin
      if let cg = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
        wheel1: -120, wheel2: 0, wheel3: 0)
      {
        let position = shelf.convertPoint(toScreen: center)
        cg.location = CGPoint(x: position.x, y: NSScreen.screens[0].frame.maxY - position.y)
        cg.setIntegerValueField(
          .mouseEventWindowUnderMousePointer, value: Int64(shelf.windowNumber))
        if nativeDropFixtureOwns(
          cg.location, windows: Set([shelf.windowNumber, source.windowNumber]), pid: getpid())
        {
          cg.post(tap: .cgSessionEventTap)
        } else {
          failures.append("wheel target window ownership changed")
        }
        scrollWorks = await wait { scroll.contentView.bounds.origin != before }
      }
      scroll.contentView.scroll(to: before)
      scroll.reflectScrolledClipView(scroll.contentView)
      await settle()
    }
    if outgoingStarts != 0 { failures.append("click or scroll started an outgoing drag") }
    rows = descendants(content, NativeFileDragView.self).filter { $0.file?.id == first.id }
    if let row = rows.first {
      let p = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
      sourceView.received = []
      drag(from: shelf, point: p, to: source, target: NSPoint(x: 120, y: 80))
      outgoingWorks = await wait { Set(sourceView.received) == Set([first.path, second.path]) }
      if outgoingStarts != 1 {
        failures.append("outgoing multi-file drag did not start exactly one session")
      }
    }
  } else {
    failures.append("not enough visible real file rows for click/outgoing regression")
  }
  if !clickWorks { failures.append("drop target intercepted ordinary multi-select clicks") }
  if !scrollWorks { failures.append("drop target intercepted wheel scrolling") }
  if !outgoingWorks {
    failures.append("outgoing NSDraggingSession did not deliver both selected files")
  }
  failures += driver.failures
  return [
    "ok": failures.isEmpty, "failures": failures, "nativeVisible": shelf.isVisible,
    "destination": model.destination, "targets": targets, "clickWorks": clickWorks,
    "scrollWorks": scrollWorks, "outgoingWorks": outgoingWorks, "outgoingStarts": outgoingStarts,
    "driver": "CGEvent sessionTap with existing Accessibility + own-window checks",
    "accessibilityAlreadyGranted": AXIsProcessTrusted(), "warpFailures": warpFailures,
  ]
}

/// External-source regression keeps the actual file-probe and inactive auto-open
/// path. Its trace records production callbacks without substituting drop actions.
@MainActor func nativeExternalFileDropSmoke(
  application: NativeApplication, shelf: NSWindow,
  model: NativeUIModel, platform: NativePlatform
) async -> [String: Any] {
  guard NativeProfile.isolatedFixture, platform.fileProbe.running else {
    return [
      "ok": false,
      "failures": ["external regression requires isolated profile and running real file probe"],
    ]
  }
  var events: [[String: Any]] = []
  var failures: [String] = []
  var targets: [[String: Any]] = []
  func trace(_ kind: String, _ detail: [String: Any] = [:]) {
    var event = detail
    event["kind"] = kind
    event["t"] = ProcessInfo.processInfo.systemUptime
    event["visible"] = model.visible
    event["windowVisible"] = shelf.isVisible
    event["pending"] = model.incomingFileDropPending
    event["count"] = model.files.count
    event["destination"] = model.destination
    event["revision"] = model.sessionRevision
    event["appActive"] = NSApp.isActive
    events.append(event)
  }
  let panel = shelf as? ShelfPanel
  let originalDropTrace = panel?.dropTrace
  panel?.dropTrace = { stage, sender in
    trace(
      "native." + stage,
      [
        "mask": sender.draggingSourceOperationMask.rawValue,
        "sourceNil": sender.draggingSource == nil,
        "types": sender.draggingPasteboard.types?.map(\.rawValue) ?? [],
      ])
    originalDropTrace?(stage, sender)
  }
  var duplicateEnterArmed = false
  var duplicateEnterResult: [String: Any] = [:]
  let originalMessage = platform.fileProbe.onMessage
  platform.fileProbe.onMessage = { message in
    trace("helper." + (message["type"] as? String ?? "unknown"), message)
    originalMessage?(message)
    trace("helper.after." + (message["type"] as? String ?? "unknown"))
  }
  let originalEnd = platform.endIncomingFiles
  platform.endIncomingFiles = {
    trace("endIncoming.before")
    originalEnd?()
    trace("endIncoming.after")
  }
  let originalShow = platform.showIncomingFiles
  platform.showIncomingFiles = {
    trace("showIncoming.before")
    await originalShow?()
    trace("showIncoming.after")
  }
  let originalAction = model.action
  model.action = { command in
    trace("action.begin", ["command": command.name, "ids": command.ids])
    do {
      try await originalAction?(command)
      trace("action.end", ["command": command.name])
    } catch {
      trace("action.failed", ["command": command.name])
      throw error
    }
  }
  let visibleObservation = model.$visible.sink { trace("model.visible", ["newVisible": $0]) }
  let pendingObservation = model.$incomingFileDropPending.sink { value in
    trace("model.pending", ["newPending": value])
    if value && duplicateEnterArmed {
      duplicateEnterArmed = false
      Task { @MainActor in
        let revision = model.sessionRevision
        let pending = model.incomingFileDropPending
        trace("deterministic.duplicateEnter.before")
        await platform.showIncomingFiles?()
        duplicateEnterResult = [
          "before": revision, "after": model.sessionRevision, "wasPending": pending,
        ]
        trace("deterministic.duplicateEnter.after", duplicateEnterResult)
      }
    }
  }
  defer {
    visibleObservation.cancel()
    pendingObservation.cancel()
    panel?.dropTrace = originalDropTrace
    platform.fileProbe.onMessage = originalMessage
    platform.endIncomingFiles = originalEnd
    platform.showIncomingFiles = originalShow
    model.action = originalAction
  }
  func wait(_ predicate: () -> Bool, seconds: Double = 5) async -> Bool {
    let until = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < until {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
  }
  let environment = ProcessInfo.processInfo.environment
  let directory = NativeProfile.path().appendingPathComponent(
    "external-synthetic-files", isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  } catch { return ["ok": false, "failures": ["cannot create external synthetic files"]] }
  var serial = 0
  func files(_ prefix: String, count: Int = 1) -> [URL] {
    (0..<count).map { _ in
      serial += 1
      let url = directory.appendingPathComponent("\(prefix)-\(serial).txt")
      try? Data("Synthetic external file drop \(serial)".utf8).write(to: url)
      return url
    }
  }
  if environment["POLKA_NATIVE_EXTERNAL_DROP_MANUAL"] == "1" {
    let urls = files("finder", count: 3)
    await platform.showIncomingFiles?()
    try? await Task.sleep(nanoseconds: 300_000_000)
    if let path = environment["POLKA_NATIVE_DROP_READY"] {
      let ready: [String: Any] = [
        "ready": true, "pid": getpid(), "sourceDirectory": directory.path,
        "expectedFiles": urls.map(\.path),
        "shelfFrame": [
          "x": shelf.frame.minX, "y": shelf.frame.minY, "w": shelf.frame.width,
          "h": shelf.frame.height,
        ],
      ]
      if let data = try? JSONSerialization.data(withJSONObject: ready) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
      }
    }
    // Finder canonicalizes macOS's /var alias to /private/var when publishing
    // file URLs; compare identities rather than the profile's spelling.
    let expected = Set(urls.map { $0.resolvingSymlinksInPath().path })
    let accepted = await wait(
      {
        Set(model.files.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
          .isSuperset(of: expected)
      }, seconds: 180)
    return [
      "ok": accepted, "failures": accepted ? [] : ["manual Finder files were not accepted"],
      "manual": true, "events": events, "paths": model.files.map(\.path),
    ]
  }
  guard AXIsProcessTrusted(), let sourcePath = environment["POLKA_NATIVE_EXTERNAL_DRAG_SOURCE"]
  else {
    return [
      "ok": false,
      "failures": [
        "external regression requires existing Accessibility and compiled isolated source"
      ],
    ]
  }
  let source = HelperProcess()
  var ready: [String: Any] = [:]
  var starts = 0
  var ends = 0
  var selfDrops = 0
  var lastEnd: [String: Any] = [:]
  source.onMessage = { message in
    events.append(
      message.merging(["kind": "source." + (message["type"] as? String ?? "unknown")]) { _, new in
        new
      })
    switch message["type"] as? String {
    case "ready": ready = message
    case "sessionStart": starts += 1
    case "sessionEnd":
      ends += 1
      lastEnd = message
    case "selfDrop": selfDrops += 1
    default: break
    }
  }
  do { try source.start(URL(fileURLWithPath: sourcePath)) } catch {
    return ["ok": false, "failures": ["cannot start independent AppKit source"]]
  }
  defer { source.stop() }
  let originalCursor = CGEvent(source: nil)?.location
  defer { if let originalCursor { CGWarpMouseCursorPosition(originalCursor) } }
  // Seed rows only through the ordinary platform command; each routed drag uses
  // a new identity so fixture preparation cannot satisfy an acceptance assertion.
  let seed = files("seed", count: 2)
  do { try await platform.handle(NativeUICommand("shelf.files.add", ids: seed.map(\.path))) } catch
  { failures.append("cannot seed row references") }
  await application.show("files")
  try? await Task.sleep(nanoseconds: 300_000_000)
  let screen = shelf.screen ?? NSScreen.screens[0]
  let top = NSScreen.screens[0].frame.maxY
  let sourceRect = NSRect(
    x: screen.visibleFrame.minX + 20, y: max(screen.visibleFrame.minY, shelf.frame.minY - 10),
    width: max(270, shelf.frame.midX - screen.visibleFrame.minX + 10),
    height: screen.frame.maxY - max(screen.visibleFrame.minY, shelf.frame.minY - 10))
  let strip = CGPoint(
    x: screen.frame.midX, y: top - (screen.frame.maxY - screen.safeAreaInsets.top - 14))
  func row(_ view: NSView) -> NativeFileDragView? {
    if let row = view as? NativeFileDragView { return row }
    return view.subviews.lazy.compactMap(row).first
  }
  let rowPoint = shelf.contentView.flatMap(row).map {
    $0.convert(NSPoint(x: 90, y: $0.bounds.midY), to: nil)
  }
  let cases: [(String, NSPoint)] = [
    ("external-center", NSPoint(x: shelf.frame.width / 2, y: shelf.frame.height / 2)),
    ("external-bottom", NSPoint(x: shelf.frame.width / 2, y: 28)),
    ("external-row", rowPoint ?? NSPoint(x: 90, y: shelf.frame.height - model.topInset - 130)),
  ]
  let driver = NativeDropDriverState()
  let releasePoint = NSPoint(x: shelf.frame.width / 2, y: shelf.frame.height / 2)
  let allCases =
    cases + [("external-release-first", releasePoint), ("external-duplicate-enter", releasePoint)]
  for (name, point) in allCases {
    let urls = files(name)
    duplicateEnterArmed = name == "external-duplicate-enter"
    duplicateEnterResult = [:]
    application.hide(force: true)
    _ = await wait({ !model.visible && !shelf.isVisible })
    let id = UUID().uuidString
    _ = source.write([
      "id": id, "paths": urls.map(\.path),
      "frame": [
        "x": sourceRect.minX, "y": sourceRect.minY, "w": sourceRect.width, "h": sourceRect.height,
      ],
    ])
    guard await wait({ ready["id"] as? String == id }),
      let sourcePID = ready["pid"] as? Int32, let sourceWindow = ready["window"] as? Int,
      let x = ready["x"] as? Double, let y = ready["y"] as? Double
    else {
      failures.append("external source never became ready")
      break
    }
    let inactive = await wait({ !NSApp.isActive && !model.visible })
    let beforeStarts = starts
    let beforeEnds = ends
    let beforeSelf = selfDrops
    let traceStart = events.count
    trace("case.begin", ["name": name, "sourcePID": sourcePID, "inactive": inactive])
    let from = CGPoint(x: x, y: top - y)
    let screenEnd = shelf.convertPoint(toScreen: point)
    let to = CGPoint(x: screenEnd.x, y: top - screenEnd.y)
    let mainPID = getpid()
    let shelfWindow = shelf.windowNumber
    let probePath = NativeProfile.helper("file-shelf-probe").path
    // AppKit's source-ready IPC can precede WindowServer publishing a newly
    // ordered window. Require its actual point to remain owned before pressing
    // any button; a ready message alone is insufficient on the first case.
    var sourceOwnedSince: TimeInterval?
    let sourceOwned = await wait(
      {
        let now = ProcessInfo.processInfo.systemUptime
        guard
          nativeExternalDropOwns(
            from, mainPID: mainPID, sourcePID: sourcePID,
            windows: Set([shelfWindow, sourceWindow]), probePath: probePath)
        else {
          sourceOwnedSince = nil
          return false
        }
        if sourceOwnedSince == nil { sourceOwnedSince = now }
        return now - (sourceOwnedSince ?? now) >= 0.20
      }, seconds: 3)
    guard sourceOwned else {
      let windows =
        CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
      let atSource = windows.filter {
        guard let dictionary = $0[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        else { return false }
        return bounds.contains(from)
      }.map { value in
        [
          "window": value[kCGWindowNumber as String] ?? -1,
          "pid": value[kCGWindowOwnerPID as String] ?? -1,
          "layer": value[kCGWindowLayer as String] ?? -1,
          "alpha": value[kCGWindowAlpha as String] ?? -1,
          "bounds": value[kCGWindowBounds as String] ?? [:],
        ] as [String: Any]
      }
      trace(
        "source.ownershipTimeout",
        [
          "point": ["x": from.x, "y": from.y], "sourceWindow": sourceWindow,
          "sourcePID": sourcePID, "windows": atSource,
        ])
      failures.append("\(name): external source window never became owned")
      break
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let cgSource = CGEventSource(stateID: .combinedSessionState)
      func send(_ type: CGEventType, _ position: CGPoint) {
        CGEvent(
          mouseEventSource: cgSource, mouseType: type, mouseCursorPosition: position,
          mouseButton: .left)?.post(tap: .cgSessionEventTap)
      }
      func owned(_ p: CGPoint) -> Bool {
        nativeExternalDropOwns(
          p, mainPID: mainPID, sourcePID: sourcePID, windows: Set([shelfWindow, sourceWindow]),
          probePath: probePath)
      }
      guard owned(from) else {
        driver.fail("external source ownership changed")
        return
      }
      send(.mouseMoved, from)
      Thread.sleep(forTimeInterval: 0.10)
      send(.leftMouseDown, from)
      defer {
        if owned(to) {
          if name == "external-release-first" {
            DispatchQueue.main.sync {
              MainActor.assumeIsolated {
                trace("deterministic.releaseFirst")
                platform.endIncomingFiles?()
              }
            }
          }
          send(.leftMouseUp, to)
        } else {
          CGEvent(keyboardEventSource: cgSource, virtualKey: 53, keyDown: true)?.postToPid(
            sourcePID)
          CGEvent(keyboardEventSource: cgSource, virtualKey: 53, keyDown: false)?.postToPid(
            sourcePID)
          Thread.sleep(forTimeInterval: 0.05)
          send(.leftMouseUp, CGEvent(source: nil)?.location ?? from)
        }
      }
      func leg(_ a: CGPoint, _ b: CGPoint) -> Bool {
        for step in 1...30 {
          let f = Double(step) / 30
          let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
          guard owned(p) else {
            driver.fail("external drag crossed a foreign window")
            return false
          }
          send(.leftMouseDragged, p)
          Thread.sleep(forTimeInterval: 0.025)
        }
        return true
      }
      guard leg(from, strip) else { return }
      Thread.sleep(forTimeInterval: 0.65)
      guard leg(strip, to) else { return }
      Thread.sleep(forTimeInterval: 0.55)
    }
    var highlight = false
    var autoOpened = false
    let finished = await wait(
      {
        highlight = highlight || model.incomingFileDropTargeted
        autoOpened = autoOpened || model.visible
        return ends > beforeEnds
      }, seconds: 8)
    let accepted = await wait(
      { Set(model.files.map(\.path)).isSuperset(of: urls.map(\.path)) }, seconds: 1)
    let highlightCleared = await wait({ !model.incomingFileDropTargeted }, seconds: 1)
    let endX = lastEnd["x"] as? Double ?? 0
    let endY = lastEnd["y"] as? Double ?? 0
    let helperEntered = events.dropFirst(traceStart).contains {
      $0["kind"] as? String == "helper.enter"
    }
    targets.append([
      "name": name, "inactiveBeforeDrag": inactive, "sourcePID": sourcePID,
      "sessionStarted": starts > beforeStarts, "sessionCompleted": finished,
      "operation": lastEnd["operation"] ?? 0,
      "expectedEnd": ["x": screenEnd.x, "y": screenEnd.y], "actualEnd": ["x": endX, "y": endY],
      "accepted": accepted, "autoOpened": autoOpened, "helperEntered": helperEntered,
      "highlightObserved": highlight, "highlightCleared": highlightCleared,
      "selfDrop": selfDrops > beforeSelf, "paths": urls.map(\.path),
    ])
    trace("case.end", ["name": name, "accepted": accepted])
    if !inactive || !helperEntered || !autoOpened {
      failures.append("\(name): real helper did not auto-open inactive shelf")
    }
    if !finished || starts <= beforeStarts || selfDrops > beforeSelf
      || hypot(endX - screenEnd.x, endY - screenEnd.y) > 4
    {
      failures.append("\(name): external gesture did not finish at the shelf")
    }
    if !accepted { failures.append("\(name): external drop rejected after helper release") }
    if !highlight || !highlightCleared {
      failures.append("\(name): external drop highlight was missing or remained active")
    }
    if name == "external-duplicate-enter" {
      let before = duplicateEnterResult["before"] as? Int
      let after = duplicateEnterResult["after"] as? Int
      if duplicateEnterResult["wasPending"] as? Bool != true || before == nil || before != after {
        failures.append("external-duplicate-enter: pending provider presentation was reset")
      }
    }
  }
  failures += driver.failures
  return [
    "ok": failures.isEmpty, "failures": failures, "external": true, "targets": targets,
    "events": events, "fileProbeRunning": platform.fileProbe.running, "mainPID": getpid(),
    "driver": "external AppKit + real file probe + guarded sessionTap",
    "paths": model.files.map(\.path),
  ]
}

private func nativeExternalDropOwns(
  _ point: CGPoint, mainPID: pid_t, sourcePID: pid_t, windows: Set<Int>, probePath: String
) -> Bool {
  guard
    let values = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
  else { return false }
  let maximum =
    values.filter { windows.contains(($0[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1) }
    .map { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 }.max() ?? -1
  for value in values {
    guard let number = value[kCGWindowNumber as String] as? NSNumber,
      let owner = value[kCGWindowOwnerPID as String] as? NSNumber,
      let layer = value[kCGWindowLayer as String] as? NSNumber,
      (value[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0.01,
      let dictionary = value[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
      bounds.contains(point)
    else { continue }
    if owner.int32Value == mainPID || owner.int32Value == sourcePID {
      if layer.intValue > maximum && !windows.contains(number.intValue) { continue }
      return windows.contains(number.intValue)
    }
    // Permit only the real probe child of this fixture app, never another live
    // Polka instance or an arbitrary process using a similar window title.
    var process = proc_bsdinfo()
    var executable = [CChar](repeating: 0, count: 4096)
    if proc_pidinfo(
      owner.int32Value, PROC_PIDTBSDINFO, 0, &process, Int32(MemoryLayout<proc_bsdinfo>.size))
      == MemoryLayout<proc_bsdinfo>.size,
      process.pbi_ppid == UInt32(mainPID),
      proc_pidpath(owner.int32Value, &executable, UInt32(executable.count)) > 0,
      String(cString: executable) == probePath
    {
      return true
    }
    return false
  }
  return false
}
