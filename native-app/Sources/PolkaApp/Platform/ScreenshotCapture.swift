import AppKit
import PolkaCore
import ScreenCaptureKit

struct NativeScreenshotCaptureResult {
  let image: CGImage
  let area: CGRect
  var screenFrame: CGRect? = nil
  var desktopFrame: CGRect? = nil
}

/// No clipboard or temporary image file is used by capture.
@MainActor final class NativeScreenshotCapture {
  private var panels: [NSPanel] = []
  private(set) var cursorHidden = false
  private var continuation: CheckedContinuation<CGRect?, Never>?
  func capture() async throws -> NativeScreenshotCaptureResult? {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      throw PolkaCoreError.invalid(
        localized(
          "Allow Polka in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        ))
    }
    guard let rect = await selectRegion() else { return nil }
    try Task.checkCancellation()
    // Give WindowServer time to remove selection overlays before capture.
    try await Task.sleep(nanoseconds: 120_000_000)
    return try await captureDesktop(rect, includeAllDisplays: true)
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
  func selectRegion(screenFrames: [CGRect]? = nil) async -> CGRect? {
    guard continuation == nil else { return nil }
    let frames = screenFrames ?? NSScreen.screens.map(\.frame)
    let desktop = frames.reduce(CGRect.null) { $0.union($1) }
    guard !desktop.isNull else { return nil }
    let selection = NativeScreenshotRegionSelection(bounds: desktop)
    selection.changed = { [weak self] in
      for panel in self?.panels ?? [] { panel.contentView?.needsDisplay = true }
    }
    let top = NSScreen.screens.first?.frame.maxY ?? desktop.maxY
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
        view.finished = { [weak self] rect in
          self?.finish(rect.map { Self.captureRect($0, desktopTop: top) })
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
  func finish(_ rect: CGRect?) {
    for panel in panels { panel.orderOut(nil) }
    panels.removeAll()
    if cursorHidden {
      cursorHidden = false
      NSCursor.unhide()
    }
    NSCursor.arrow.set()
    let pending = continuation
    continuation = nil
    pending?.resume(returning: rect)
  }
}

private final class NativeScreenshotSelectionPanel: NSPanel {
  override var canBecomeKey: Bool { true }

}

@MainActor final class NativeScreenshotSelectionView: NSView {
  var finished: ((CGRect?) -> Void)?
  var selection: NativeScreenshotRegionSelection?
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  private var cursorTracking: NSTrackingArea?
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
    if let global = selection?.rect, let window {
      let rect = convert(window.convertFromScreen(global), from: nil)
      NSColor.clear.setFill()
      rect.fill(using: .copy)
      NSColor.white.setStroke()
      let path = NSBezierPath(rect: rect)
      path.lineWidth = 1
      path.stroke()
    }
    let hint = localized("Drag to capture a region · Esc to cancel")
    (hint as NSString).draw(
      at: CGPoint(x: 24, y: bounds.height - 56),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
        .foregroundColor: NSColor.white, .backgroundColor: NSColor.black,
      ])
    // Use the system crosshair artwork, but draw it in our overlay while the
    // hardware pointer is hidden. AppKit/other-window cursor resets cannot flash
    // an arrow between input events. Never included in the captured image.
    if let pointer = selection?.pointer, let window {
      let point = convert(window.convertPoint(fromScreen: pointer), from: nil)
      let cursor = NSCursor.crosshair
      cursor.image.draw(
        in: CGRect(
          x: point.x - cursor.hotSpot.x,
          y: point.y - (cursor.image.size.height - cursor.hotSpot.y),
          width: cursor.image.size.width, height: cursor.image.size.height))
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
    guard let rect = selection?.rect else { return }
    if rect.width >= 2 && rect.height >= 2 {
      finished?(rect)
    } else {
      selection?.clear()
    }
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 && !event.isARepeat { finished?(nil) }
  }
  override func cancelOperation(_ sender: Any?) { finished?(nil) }
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

/// One global drag is shared by all display panels.
@MainActor final class NativeScreenshotRegionSelection {
  let bounds: CGRect
  var changed: (() -> Void)?
  private var start: CGPoint?
  private var end: CGPoint?
  private(set) var pointer: CGPoint?
  func movePointer(_ point: CGPoint) {
    pointer = point
    changed?()
  }
  var rect: CGRect? {
    guard let start, let end else { return nil }
    return NativeScreenshotDocument.rect(start, end)
  }
  init(bounds: CGRect) { self.bounds = bounds }
  func begin(_ point: CGPoint) {
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
