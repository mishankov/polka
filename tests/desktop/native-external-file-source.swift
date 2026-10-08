// Separate AppKit source for native shelf regression. Private drag pasteboard only.
import AppKit
import Darwin

func emit(_ value: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
}
final class SourceWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}
final class SourceView: NSView, NSDraggingSource {
  var urls: [URL] = []
  var active = false
  var down: NSEvent?
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.darkGray.setFill()
    bounds.fill()
    "External synthetic file source".draw(
      at: NSPoint(x: 20, y: 75),
      withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white])
  }
  override func mouseDown(with event: NSEvent) { down = event }
  override func mouseDragged(with event: NSEvent) {
    guard !active, down != nil, !urls.isEmpty else { return }
    active = true
    let items = urls.enumerated().map { index, url in
      let item = NSDraggingItem(pasteboardWriter: url as NSURL)
      let point = convert(event.locationInWindow, from: nil)
      item.setDraggingFrame(
        NSRect(x: point.x + CGFloat(index) * 3, y: point.y, width: 32, height: 32),
        contents: NSWorkspace.shared.icon(forFile: url.path))
      return item
    }
    let session = beginDraggingSession(with: items, event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = false
    emit([
      "type": "sessionStart", "t": ProcessInfo.processInfo.systemUptime, "pid": getpid(),
      "board": session.draggingPasteboard.name.rawValue, "paths": urls.map(\.path),
    ])
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    let mask: NSDragOperation = [.copy, .move, .link]
    emit([
      "type": "mask", "t": ProcessInfo.processInfo.systemUptime,
      "context": context == .outsideApplication ? "outside" : "inside", "mask": mask.rawValue,
    ])
    return mask
  }
  func draggingSession(
    _ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation
  ) {
    active = false
    down = nil
    emit([
      "type": "sessionEnd", "t": ProcessInfo.processInfo.systemUptime,
      "operation": operation.rawValue, "x": point.x, "y": point.y,
    ])
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls =
      sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    emit(["type": "selfDrop", "t": ProcessInfo.processInfo.systemUptime, "paths": urls.map(\.path)])
    return !urls.isEmpty
  }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = SourceWindow(
  contentRect: NSRect(x: 20, y: 50, width: 400, height: 200), styleMask: [.borderless],
  backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
// Cover the gesture corridor above Dock's transient overview (layer 20), while
// remaining below the real shelf's status-bar level and its incoming probe.
window.level = .mainMenu
window.hidesOnDeactivate = false
let view = SourceView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
window.contentView = view
app.finishLaunching()
emit(["type": "boot", "pid": getpid()])
DispatchQueue.global(qos: .utility).async {
  while let line = readLine() {
    guard let bytes = line.data(using: .utf8),
      let command = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    else { continue }
    DispatchQueue.main.async {
      if command["type"] as? String == "quit" {
        app.terminate(nil)
        return
      }
      guard let id = command["id"] as? String, let paths = command["paths"] as? [String],
        let rect = command["frame"] as? [String: Double], let x = rect["x"], let y = rect["y"],
        let w = rect["w"], let h = rect["h"]
      else { return }
      window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
      view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
      view.urls = paths.map { URL(fileURLWithPath: $0) }
      window.makeKeyAndOrderFront(nil)
      app.activate(ignoringOtherApps: true)
      // Begin well inside the source, away from Stage Manager's transient left
      // edge thumbnails when the source application first becomes active.
      let point = window.convertPoint(toScreen: NSPoint(x: view.bounds.midX, y: 45))
      let cgPoint = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
      let info =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
      let overlaps = info.filter {
        guard let bounds = $0[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return false }
        return rect.contains(cgPoint)
      }.map {
        [
          "window": $0[kCGWindowNumber as String] ?? -1,
          "pid": $0[kCGWindowOwnerPID as String] ?? -1, "layer": $0[kCGWindowLayer as String] ?? -1,
        ]
      }
      emit([
        "type": "ready", "id": id, "pid": getpid(), "window": window.windowNumber, "x": point.x,
        "y": point.y, "t": ProcessInfo.processInfo.systemUptime, "visible": window.isVisible,
        "overlapping": overlaps,
      ])
    }
  }
  DispatchQueue.main.async { app.terminate(nil) }
}
app.run()
