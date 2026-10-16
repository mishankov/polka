import AppKit

/// Opt-in hardware check under the desktop runner's shared lock and disposable profile.
/// Solid fixture panels cover the displays; no clipboard or personal profile is used.
@MainActor func nativeScreenshotDisplaySmoke(
  captures: NativeScreenshots, screenshot: (NSWindow, String) async -> Void
) async -> [String] {
  guard NativeProfile.isolatedFixture, NSScreen.screens.count >= 2 else {
    return ["real display capture requires an isolated profile and two connected screens"]
  }
  let screens = NSScreen.screens
  let colors: [NSColor] = [
    NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
    NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
    NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
  ]
  var panels: [NSPanel] = []
  defer { for panel in panels { panel.orderOut(nil) } }
  NSApp.activate(ignoringOtherApps: true)
  for (index, screen) in screens.enumerated() {
    let panel = NSPanel(
      contentRect: screen.frame, styleMask: .borderless,
      backing: .buffered, defer: false)
    panel.backgroundColor = colors[index % colors.count]
    panel.hidesOnDeactivate = false
    panel.isOpaque = true
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.orderFrontRegardless()
    panels.append(panel)
  }
  do {
    try await Task.sleep(nanoseconds: 250_000_000)
    let top = screens[0].frame.maxY
    let a = CGPoint(x: screens[0].frame.midX, y: screens[0].frame.midY)
    let b = CGPoint(x: screens[1].frame.midX, y: screens[1].frame.midY)
    // Include a broad strip through both display centres, also for aligned displays.
    let region = NativeScreenshotDocument.rect(a, b).insetBy(dx: -100, dy: -100)
    let rect = NativeScreenshotCapture.captureRect(region, desktopTop: top)
    guard let capture = try await captures.captureService.captureDesktop(rect) else {
      return ["real multi-display capture returned no image"]
    }
    let union = screens.reduce(CGRect.null) { $0.union($1.frame) }
    let scale = CGFloat(capture.image.width) / union.width
    let pixels = NSBitmapImageRep(cgImage: capture.image)
    for (index, screen) in screens.enumerated() {
      let x = Int((screen.frame.midX - union.minX) * scale)
      let y = Int((union.maxY - screen.frame.midY) * scale)
      guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
        return ["real display capture has no pixel at screen centre"]
      }
      let expected = colors[index % colors.count].usingColorSpace(.sRGB)!
      // WindowServer applies the display's color profile (the laptop's red is not
      // literal sRGB red in a capture). Check the distinct fixture color identity
      // at the exact expected coordinate, rather than testing display calibration.
      let channels = [color.redComponent, color.blueComponent, color.greenComponent]
      let dominant = index % colors.count
      if channels[dominant] < 0.8
        || channels.enumerated().contains(where: {
          $0.offset != dominant && $0.element > channels[dominant] * 0.4
        })
      {
        let diagnostic = FileManager.default.temporaryDirectory.appendingPathComponent(
          "polka-display-mismatch.png")
        try? NSBitmapImageRep(cgImage: capture.image).representation(using: .png, properties: [:])?
          .write(to: diagnostic)
        return [
          "real display capture pixels do not match display positions: \(screen.localizedName), got \(color), expected \(expected), image \(capture.image.width)x\(capture.image.height), diagnostic \(diagnostic.path)"
        ]
      }
    }
    let shot = try captures.insert(
      capture.image, area: capture.area, screenFrame: capture.screenFrame,
      desktopFrame: capture.desktopFrame)
    guard let editor = captures.editors[shot.id], let window = editor.window else {
      return ["real multi-display capture did not open editor"]
    }
    // The desktop changes after selection; the overlay must show and export the new pixels.
    for panel in panels { panel.backgroundColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) }
    try await Task.sleep(nanoseconds: 250_000_000)
    await screenshot(window, "screenshot-live-desktop-main")
    if let other = editor.mirrors.first?.window {
      await screenshot(other, "screenshot-live-desktop-second")
    }
    var data: Data?
    editor.preparePNG { data = $0 }
    for _ in 0..<1000 where data == nil && shot.busy {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard let data, let exported = NSBitmapImageRep(data: data),
      let pixel = exported.colorAt(x: exported.pixelsWide / 2, y: exported.pixelsHigh / 2)?
        .usingColorSpace(.sRGB),
      pixel.greenComponent > 0.7, pixel.redComponent < 0.4, pixel.blueComponent < 0.4
    else {
      editor.discard()
      return ["live desktop export used stale pixels or included overlay chrome"]
    }
    editor.discard()
    return []
  } catch { return ["real display capture failed: \(error)"] }
}
