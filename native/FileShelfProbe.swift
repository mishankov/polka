import AppKit

func emit(_ value: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
}
func files(_ pasteboard: NSPasteboard) -> [String] {
  (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    as? [URL] ?? [])
    .filter { $0.isFileURL }.map { $0.path }
}
class Target: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
    layer?.cornerRadius = 8

  }
  override func draw(_ dirtyRect: NSRect) {
    ("↓  Файлы на полку" as NSString).draw(
      at: NSPoint(x: 37, y: 7),
      withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12)])
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard !files(sender.draggingPasteboard).isEmpty else { return [] }
    emit(["type": "enter"])
    return .copy
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    files(sender.draggingPasteboard).isEmpty ? [] : .copy
  }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = files(sender.draggingPasteboard)
    guard !paths.isEmpty else { return false }
    emit(["type": "drop", "paths": paths])
    return true
  }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
var panels: [NSPanel] = []
var enabled = true
var outgoing = false
var completedChange = NSPasteboard(name: .drag).changeCount
var activeChange: Int?
var enteredChange: Int?
func rebuild() {
  panels.forEach { $0.close() }
  panels = NSScreen.screens.map { screen in
    let frame = screen.frame
    // The strip begins below the physical camera area, including on notchless displays.
    let inset = screen.safeAreaInsets.top
    let rect = NSRect(x: frame.midX - 100, y: frame.maxY - inset - 28, width: 200, height: 28)
    let panel = NSPanel(
      contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    // Keep the native strip above the revealed Electron shelf so a Finder drag
    // retains an AppKit destination throughout opening.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.setFrame(rect, display: true)
    panel.contentView = Target(frame: NSRect(origin: .zero, size: rect.size))
    return panel
  }
}
rebuild()
let observer = NotificationCenter.default.addObserver(
  forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
) { _ in rebuild() }
// Only the drag pasteboard is read. No clipboard writes or accessibility/event taps.
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
  let pressed = NSEvent.pressedMouseButtons & 1 != 0
  let board = NSPasteboard(name: .drag)
  if !pressed {
    if let active = activeChange {
      completedChange = active
      activeChange = nil
    }
    if outgoing {
      outgoing = false
      completedChange = board.changeCount
      emit(["type": "dragEnd"])
    }
  }
  let dragging = enabled && pressed && board.changeCount != completedChange && !files(board).isEmpty
  if dragging {
    activeChange = board.changeCount
    let point = NSEvent.mouseLocation
    if enteredChange != board.changeCount
      && panels.contains(where: { $0.frame.insetBy(dx: -12, dy: -16).contains(point) })
    {
      enteredChange = board.changeCount
      emit(["type": "enter"])
    }
  }

  for panel in panels {
    if dragging {
      if !panel.isVisible { panel.orderFrontRegardless() }
    } else {
      panel.orderOut(nil)
    }
  }
}
DispatchQueue.global(qos: .utility).async {
  while let line = readLine() {
    guard let data = line.data(using: .utf8),
      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let value = command["enabled"] as? Bool
    else { continue }
    DispatchQueue.main.async {
      enabled = value
      if command["outgoing"] as? Bool == true { outgoing = true }
    }
  }
  DispatchQueue.main.async { application.terminate(nil) }
}
application.run()
