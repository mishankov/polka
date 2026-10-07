// Isolated AppKit drag source/receiver and bounded mouse driver for desktop validation.
import AppKit
import ApplicationServices

func emit(_ value: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: value)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
}
if CommandLine.arguments.contains("--access") {
  print(AXIsProcessTrusted())
  exit(0)
}
if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--mouse" {
  let source = CGEventSource(stateID: .combinedSessionState)
  let a = CGPoint(x: Double(CommandLine.arguments[2])!, y: Double(CommandLine.arguments[3])!)
  let b = CGPoint(x: Double(CommandLine.arguments[4])!, y: Double(CommandLine.arguments[5])!)
  CGEvent(
    mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: a, mouseButton: .left)?
    .post(tap: .cgSessionEventTap)
  Thread.sleep(forTimeInterval: 0.1)
  CGEvent(
    mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)?
    .post(tap: .cgSessionEventTap)
  for step in 1...30 {
    Thread.sleep(forTimeInterval: 0.025)
    let p = CGPoint(
      x: a.x + (b.x - a.x) * Double(step) / 30, y: a.y + (b.y - a.y) * Double(step) / 30)
    CGEvent(
      mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p,
      mouseButton: .left)?.post(tap: .cgSessionEventTap)
  }
  Thread.sleep(forTimeInterval: 0.7)
  CGEvent(
    mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: b,
    mouseButton: .left)?.post(tap: .cgSessionEventTap)
  Thread.sleep(forTimeInterval: 0.15)
  CGEvent(
    mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left)?
    .post(tap: .cgSessionEventTap)

  exit(0)
}
let paths = Array(CommandLine.arguments.dropFirst())
class FilesView: NSView, NSDraggingSource {
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  var dragging = false
  override func mouseDown(with event: NSEvent) {}
  override func mouseDragged(with event: NSEvent) {
    if dragging { return }
    dragging = true
    emit(["type": "sourceDown"])
    let items = paths.map { path -> NSDraggingItem in
      let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
      item.setDraggingFrame(
        NSRect(x: 20, y: 20, width: 32, height: 32),
        contents: NSWorkspace.shared.icon(forFile: path))
      return item
    }
    let session = beginDraggingSession(with: items, event: event, source: self)
    emit([
      "type": "sourceSession", "board": session.draggingPasteboard.name.rawValue,
      "types": session.draggingPasteboard.types?.map { $0.rawValue } ?? [],
      "globalTypes": NSPasteboard(name: .drag).types?.map { $0.rawValue } ?? [],
    ])
  }
  func draggingSession(
    _ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation
  ) {
    dragging = false
    emit(["type": "sessionEnd", "operation": operation.rawValue])
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .copy }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls =
      sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    emit(["type": "received", "paths": urls.map { $0.path }])
    return true
  }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0]
let rect = NSRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 400, height: 180)
let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Polka synthetic file receiver"
let view = FilesView(frame: NSRect(origin: .zero, size: rect.size))
let label = NSTextField(labelWithString: "Synthetic local files — drag source / drop receiver")
label.frame = NSRect(x: 20, y: 80, width: 370, height: 30)
view.addSubview(label)
window.contentView = view
window.level = .floating
app.finishLaunching()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let primaryTop = NSScreen.screens[0].frame.maxY
let sourcePoint = window.convertPoint(toScreen: NSPoint(x: 40, y: 40))
emit([
  "type": "ready",
  "frame": [
    "x": window.frame.minX, "y": window.frame.minY, "w": window.frame.width,
    "h": window.frame.height,
  ], "source": ["x": sourcePoint.x, "y": primaryTop - sourcePoint.y],
  "target": [
    "x": screen.frame.midX, "y": primaryTop - screen.frame.maxY + screen.safeAreaInsets.top + 14,
  ],
])
DispatchQueue.global(qos: .utility).async {
  while readLine() != nil {}
  DispatchQueue.main.async { app.terminate(nil) }
}
app.run()
