import AppKit
import PolkaCore
import ScreenCaptureKit

struct NativeScreenshotCaptureResult {
  let image: CGImage
  let area: CGRect
  var screenFrame: CGRect? = nil
  var desktopFrame: CGRect? = nil
}

enum NativeScreenshotTarget {
  case region(CGRect)
  case window(CGWindowID, omitShadow: Bool, screenFrame: CGRect?)
}

/// No clipboard or temporary image file is used by capture.
@MainActor final class NativeScreenshotCapture {
  private var panels: [NSPanel] = []
  private(set) var cursorHidden = false
  private var continuation: CheckedContinuation<NativeScreenshotTarget?, Never>?
  func capture() async throws -> NativeScreenshotCaptureResult? {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      throw PolkaCoreError.invalid(
        localized(
          "Allow Polka in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        ))
    }
    guard let target = await selectTarget() else { return nil }
    try Task.checkCancellation()
    switch target {
    case .region(let rect):
      // Give WindowServer time to remove selection overlays before capture.
      try await Task.sleep(nanoseconds: 120_000_000)
      return try await captureDesktop(rect, includeAllDisplays: true)
    case .window(let id, let omitShadow, let screenFrame):
      let content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: true)
      let image = try await Self.captureWindow(id, omitShadow: omitShadow, in: content)
      return NativeScreenshotCaptureResult(
        image: image, area: CGRect(x: 0, y: 0, width: image.width, height: image.height),
        screenFrame: screenFrame)
    }
  }
  func captureDesktop(_ rect: CGRect, includeAllDisplays: Bool = false) async throws
    -> NativeScreenshotCaptureResult?
  {
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let displays = NSScreen.screens.map {
      NativeScreenshotDisplay(
        frame: $0.frame, scale: $0.backingScaleFactor,
        id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
          .uint32Value)
    }
    guard
      let layout = NativeScreenshotCaptureLayout(
        selection: rect, displays: displays, desktopTop: top, includeAllDisplays: includeAllDisplays
      )
    else { return nil }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    var images: [CGImage] = []
    for display in layout.displays {
      try Task.checkCancellation()
      guard let source = content.displays.first(where: { $0.displayID == display.id }) else {
        throw PolkaCoreError.invalid(localized("Could not render the screenshot"))
      }
      let configuration = SCStreamConfiguration()
      configuration.width = max(1, Int((display.frame.width * display.scale).rounded()))
      configuration.height = max(1, Int((display.frame.height * display.scale).rounded()))
      configuration.showsCursor = false
      images.append(
        try await SCScreenshotManager.captureImage(
          contentFilter: SCContentFilter(display: source, excludingWindows: []),
          configuration: configuration))
    }
    let image = try layout.composite(images)
    return NativeScreenshotCaptureResult(
      image: image,
      area: layout.pixelArea(imageSize: CGSize(width: image.width, height: image.height)),
      screenFrame: layout.editorFrame, desktopFrame: layout.desktopFrame)
  }
  func selectTarget(screenFrames: [CGRect]? = nil) async -> NativeScreenshotTarget? {
    guard continuation == nil else { return nil }
    let frames = screenFrames ?? NSScreen.screens.map(\.frame)
    let desktop = frames.reduce(CGRect.null) { $0.union($1) }
    guard !desktop.isNull else { return nil }
    let selection = NativeScreenshotSelection(bounds: desktop)
    selection.changed = { [weak self] in
      for panel in self?.panels ?? [] { panel.contentView?.needsDisplay = true }
    }
    let top = NSScreen.screens.first?.frame.maxY ?? desktop.maxY
    selection.windowAtPoint = { [weak self] point, previous in
      guard let panel = self?.panels.first(where: { $0.frame.contains(point) }) else { return nil }
      return NativeScreenshotWindowTarget.below(
        panel.windowNumber, at: point, desktopTop: top, previous: previous)
    }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      NSApp.activate(ignoringOtherApps: true)
      for frame in frames {
        let panel = NativeScreenshotSelectionPanel(
          contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .screenSaver
        // Retain WindowServer input ownership even inside the undimmed region.
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        // Capture owns one cursor across every display. Automatic cursor-rect
        // resets otherwise race explicit tracking updates and flash the arrow.
        panel.disableCursorRects()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NativeScreenshotSelectionView(
          frame: CGRect(origin: .zero, size: frame.size))
        view.selection = selection
        view.finished = { [weak self] target in
          if case .region(let rect) = target {
            self?.finish(.region(Self.captureRect(rect, desktopTop: top)))
          } else {
            self?.finish(target)
          }
        }
        panel.contentView = view
        panels.append(panel)
        panel.orderFrontRegardless()
        if frame.contains(NSEvent.mouseLocation) {
          panel.makeKey()
          panel.makeFirstResponder(view)
        }
      }
      if !panels.contains(where: \.isKeyWindow), let panel = panels.first {
        panel.makeKey()
        panel.makeFirstResponder(panel.contentView)
      }
      selection.movePointer(NSEvent.mouseLocation)
      NSCursor.hide()
      cursorHidden = true
    }
  }
  static func captureRect(_ appKitRect: CGRect, desktopTop: CGFloat) -> CGRect {
    CGRect(
      x: appKitRect.minX, y: desktopTop - appKitRect.maxY,
      width: appKitRect.width, height: appKitRect.height)
  }
  func finish(_ target: NativeScreenshotTarget?) {
    for panel in panels { panel.orderOut(nil) }
    panels.removeAll()
    if cursorHidden {
      cursorHidden = false
      NSCursor.unhide()
    }
    NSCursor.arrow.set()
    let pending = continuation
    continuation = nil
    pending?.resume(returning: target)
  }
}

private final class NativeScreenshotSelectionPanel: NSPanel {
  override var canBecomeKey: Bool { true }

}

@MainActor final class NativeScreenshotSelectionView: NSView {
  var finished: ((NativeScreenshotTarget?) -> Void)?
  var selection: NativeScreenshotSelection?
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  private var cursorTracking: NSTrackingArea?
  private var hint: String {
    if selection?.selectsWindow == true {
      return localized("Click or press Return to capture · Space for region · Esc to cancel")
    }
    return localized("Drag to capture a region · Space for window · Esc to cancel")
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(localized("Screenshots"))
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func accessibilityHelp() -> String? { hint }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let cursorTracking { removeTrackingArea(cursorTracking) }
    let tracking = NSTrackingArea(
      rect: .zero, options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved],
      owner: self, userInfo: nil)
    cursorTracking = tracking
    addTrackingArea(tracking)
  }
  override func cursorUpdate(with event: NSEvent) { updatePointer(event) }
  override func mouseMoved(with event: NSEvent) { updatePointer(event) }
  private func updatePointer(_ event: NSEvent) {
    guard let window else { return }
    selection?.movePointer(window.convertPoint(toScreen: event.locationInWindow))
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.25).setFill()
    bounds.fill()
    let windowMode = selection?.selectsWindow == true
    if let global = windowMode ? selection?.targetWindow?.frame : selection?.rect, let window {
      let rect = convert(window.convertFromScreen(global), from: nil)
      NSColor.clear.setFill()
      rect.fill(using: .copy)
      if windowMode {
        NSColor.systemBlue.withAlphaComponent(0.25).setFill()
        rect.fill(using: .sourceOver)
      }
      NSColor.white.setStroke()
      let path = NSBezierPath(rect: rect)
      path.lineWidth = 1
      path.stroke()
    }
    // Drawing the pointer while the hardware cursor is hidden avoids AppKit
    // cursor resets and keeps the pointer out of the captured image.
    if let pointer = selection?.pointer, let window,
      let context = NSGraphicsContext.current?.cgContext
    {
      let point = convert(window.convertPoint(fromScreen: pointer), from: nil)
      NativeScreenshotPointer.draw(at: point, windowMode: windowMode, in: context)
    }
  }
  override func mouseDown(with event: NSEvent) {
    updatePointer(event)
    window?.makeKey()
    window?.makeFirstResponder(self)
    guard let window else { return }
    selection?.begin(window.convertPoint(toScreen: event.locationInWindow))
  }
  override func mouseDragged(with event: NSEvent) {
    updatePointer(event)
    guard let window else { return }
    // Drag events keep arriving at the starting panel after crossing a display edge.
    selection?.update(window.convertPoint(toScreen: event.locationInWindow))
  }
  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    if selection?.selectsWindow == true {
      captureWindow(omitShadow: event.modifierFlags.contains(.option))
      return
    }
    guard let rect = selection?.rect else { return }
    if rect.width >= 2 && rect.height >= 2 {
      finished?(.region(rect))
    } else {
      selection?.clear()
    }
  }
  override func keyDown(with event: NSEvent) {
    guard !event.isARepeat else { return }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    switch event.keyCode {
    case 53: finished?(nil)
    case 49 where modifiers.isEmpty: selection?.toggleMode()
    case 36, 76:
      if modifiers.isEmpty || modifiers == .option {
        captureWindow(omitShadow: modifiers.contains(.option))
      }
    default: break
    }
  }
  override func cancelOperation(_ sender: Any?) { finished?(nil) }
  private func captureWindow(omitShadow: Bool) {
    guard let selection, let point = selection.pointer, let target = selection.confirmWindow()
    else { return }
    let screenFrame = NSScreen.screens.first { $0.frame.contains(point) }?.frame
    finished?(.window(target.id, omitShadow: omitShadow, screenFrame: screenFrame))
  }
}

private enum NativeScreenshotPointer {
  // The open center and the camera lens both mark the exact pointer location.
  static let crosshair: CGPath = {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: -19, y: 0))
    path.addLine(to: CGPoint(x: -7, y: 0))
    path.move(to: CGPoint(x: 7, y: 0))
    path.addLine(to: CGPoint(x: 19, y: 0))
    path.move(to: CGPoint(x: 0, y: -19))
    path.addLine(to: CGPoint(x: 0, y: -7))
    path.move(to: CGPoint(x: 0, y: 7))
    path.addLine(to: CGPoint(x: 0, y: 19))
    return path
  }()

  static let camera: CGPath = {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: -15, y: -13))
    path.addQuadCurve(to: CGPoint(x: -19, y: -9), control: CGPoint(x: -19, y: -13))
    path.addLine(to: CGPoint(x: -19, y: 7))
    path.addQuadCurve(to: CGPoint(x: -15, y: 11), control: CGPoint(x: -19, y: 11))
    path.addLine(to: CGPoint(x: -10, y: 11))
    path.addLine(to: CGPoint(x: -6, y: 16))
    path.addLine(to: CGPoint(x: 6, y: 16))
    path.addLine(to: CGPoint(x: 10, y: 11))
    path.addLine(to: CGPoint(x: 15, y: 11))
    path.addQuadCurve(to: CGPoint(x: 19, y: 7), control: CGPoint(x: 19, y: 11))
    path.addLine(to: CGPoint(x: 19, y: -9))
    path.addQuadCurve(to: CGPoint(x: 15, y: -13), control: CGPoint(x: 19, y: -13))
    path.closeSubpath()
    path.addEllipse(in: CGRect(x: -6, y: -6, width: 12, height: 12))
    return path
  }()

  static func draw(at point: CGPoint, windowMode: Bool, in context: CGContext) {
    let shape = windowMode ? camera : crosshair
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: point.x, y: point.y)
    context.scaleBy(x: 0.73, y: 0.73)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(6)
    context.addPath(shape)
    context.strokePath()
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(3)
    context.addPath(shape)
    context.strokePath()
  }
}

struct NativeScreenshotDisplay {
  let frame: CGRect
  let scale: CGFloat
  var id: CGDirectDisplayID? = nil
}

/// ScreenCaptureKit uses one desktop coordinate space, including negative origins.
struct NativeScreenshotCaptureLayout {
  let captureFrame: CGRect
  let selection: CGRect
  let scale: CGFloat
  let editorFrame: CGRect
  let displays: [NativeScreenshotDisplay]
  let desktopFrame: CGRect

  init?(
    selection: CGRect, displays: [NativeScreenshotDisplay], desktopTop: CGFloat,
    includeAllDisplays: Bool = false
  ) {
    let involved = displays.filter {
      let frame = CGRect(
        x: $0.frame.minX, y: desktopTop - $0.frame.maxY,
        width: $0.frame.width, height: $0.frame.height)
      let intersection = frame.intersection(selection)
      return includeAllDisplays
        || (!intersection.isNull && intersection.width > 0 && intersection.height > 0)
    }
    guard
      let primary = involved.max(by: {
        func overlap(_ display: NativeScreenshotDisplay) -> CGFloat {
          let frame = CGRect(
            x: display.frame.minX, y: desktopTop - display.frame.maxY,
            width: display.frame.width, height: display.frame.height)
          let part = frame.intersection(selection)
          return part.width * part.height
        }
        return overlap($0) < overlap($1)
      })
    else { return nil }
    self.displays = involved
    let full = involved.reduce(CGRect.null) { $0.union($1.frame) }
    desktopFrame = full
    captureFrame = CGRect(
      x: full.minX, y: desktopTop - full.maxY,
      width: full.width, height: full.height)
    self.selection = selection.intersection(captureFrame)
    scale = involved.map(\.scale).max() ?? 1
    // Keep the whole combined image and controls visible even with separate Spaces.
    editorFrame = primary.frame
  }

  func composite(_ images: [CGImage]) throws -> CGImage {
    let width = Int((desktopFrame.width * scale).rounded())
    let height = Int((desktopFrame.height * scale).rounded())
    guard images.count == displays.count, width > 0, height > 0,
      Double(width) * Double(height) * 4 <= 256 * 1024 * 1024,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw PolkaCoreError.invalid(localized("Could not render the screenshot")) }
    context.interpolationQuality = .high
    for (display, image) in zip(displays, images) {
      // Explicitly resample each display into the shared pixel grid. The rect capture
      // API can pad the output instead of scaling its contents on mixed-DPI desktops.
      context.draw(
        image,
        in: CGRect(
          x: (display.frame.minX - desktopFrame.minX) * scale,
          y: (display.frame.minY - desktopFrame.minY) * scale,
          width: display.frame.width * scale, height: display.frame.height * scale))
    }
    guard let image = context.makeImage() else {
      throw PolkaCoreError.invalid(localized("Could not render the screenshot"))
    }
    return image
  }

  func pixelArea(imageSize: CGSize) -> CGRect {
    let sx = imageSize.width / captureFrame.width
    let sy = imageSize.height / captureFrame.height
    return CGRect(
      x: (selection.minX - captureFrame.minX) * sx,
      y: (captureFrame.maxY - selection.maxY) * sy,
      width: selection.width * sx, height: selection.height * sy)
  }
}

/// All display panels share one drag or window target.
@MainActor final class NativeScreenshotSelection {
  let bounds: CGRect
  var changed: (() -> Void)?
  var windowAtPoint: ((CGPoint, NativeScreenshotWindowTarget?) -> NativeScreenshotWindowTarget?)?
  private(set) var selectsWindow = false
  private(set) var targetWindow: NativeScreenshotWindowTarget?
  private var start: CGPoint?
  private var end: CGPoint?
  private(set) var pointer: CGPoint?
  func movePointer(_ point: CGPoint) {
    pointer = point
    if selectsWindow { targetWindow = windowAtPoint?(point, targetWindow) }
    changed?()
  }
  func toggleMode() {
    guard start == nil else { return }
    selectsWindow.toggle()
    targetWindow = selectsWindow ? pointer.flatMap { windowAtPoint?($0, nil) } : nil
    changed?()
  }
  func confirmWindow() -> NativeScreenshotWindowTarget? {
    guard selectsWindow, let pointer, let highlighted = targetWindow else { return nil }
    targetWindow = windowAtPoint?(pointer, nil)
    changed?()
    return targetWindow?.id == highlighted.id ? targetWindow : nil
  }
  var rect: CGRect? {
    guard let start, let end else { return nil }
    return NativeScreenshotDocument.rect(start, end)
  }
  init(bounds: CGRect) { self.bounds = bounds }
  func begin(_ point: CGPoint) {
    guard !selectsWindow else { return }
    start = bounded(point)
    end = start
    changed?()
  }
  func update(_ point: CGPoint) {
    guard start != nil else { return }
    end = bounded(point)
    changed?()
  }
  func clear() {
    start = nil
    end = nil
    changed?()
  }
  private func bounded(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: min(bounds.maxX, max(bounds.minX, point.x)),
      y: min(bounds.maxY, max(bounds.minY, point.y)))
  }
}
