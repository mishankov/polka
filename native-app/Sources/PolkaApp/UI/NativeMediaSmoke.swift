import AppKit
import SwiftUI

/// Exercise the real panels on the reported displays, while only this fixture
/// receives keyboard/mouse events. The active overlay stays up for the core
/// suite's shelf/menu/settings, IME, repeat and draft-preservation checks.
@MainActor func nativeMediaSmokeOverlay(
  application: NativeApplication, shelf: NSWindow, monitor: NativeMediaMonitor
) async -> [String] {
  guard NativeProfile.isolatedFixture else { return ["media smoke requires an isolated profile"] }
  var failures: [String] = []
  let states: [NativeMediaPresentation] = [
    .init(camera: "active", microphone: "inactive"),
    .init(camera: "inactive", microphone: "active"),
    .init(camera: "active", microphone: "active"),
    .init(camera: "unknown", microphone: "unknown"),
  ]
  for state in states {
    let keyWindow = NSApp.keyWindow
    let panels = monitor.showFixture(state)
    if panels.count != NSScreen.screens.count {
      failures.append("missing media panel for a display")
    }
    for panel in panels {
      if panel.canBecomeKey || panel.canBecomeMain || !panel.ignoresMouseEvents
        || panel.sharingType != .none || !panel.isVisible
      {
        failures.append("media panel is hidden, focusable, interactive or shareable")
      }
      if !NSScreen.screens.contains(where: {
        NativeMediaIndicatorGeometry(screen: $0).panelFrame == panel.frame
      }) {
        failures.append(
          "media panel is misaligned with reported screen bounds: \(NSStringFromRect(panel.frame))")
      }
    }
    monitor.refreshGeometry()
    if NSApp.keyWindow !== keyWindow { failures.append("media update stole keyboard focus") }
  }
  let panels = monitor.showFixture(.init(camera: "inactive", microphone: "disabled"))
  if panels.contains(where: { $0.isVisible }) {
    failures.append("inactive media panel stayed visible")
  }
  _ = monitor.showFixture(.init(camera: "active", microphone: "active"))
  monitor.suspend("media-smoke")
  if panels.contains(where: { $0.isVisible }) {
    failures.append("suspended media panel stayed visible")
  }
  monitor.refreshGeometry()
  if panels.contains(where: { $0.isVisible }) {
    failures.append("display update revived suspended media")
  }
  monitor.resume("media-smoke")
  _ = monitor.showFixture(.init(camera: "active", microphone: "active"))
  application.hide()
  await application.show("clipboard")
  try? await Task.sleep(nanoseconds: 250_000_000)
  if !shelf.isKeyWindow || !shelf.isVisible {
    failures.append("active media overlay blocked shelf reopening or keyboard focus")
  }
  // Capture only public geometry diagnostics, never a whole-desktop image.
  if let directory = ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_SCREENSHOT_DIR"] {
    let screens: [[String: Any]] = NSScreen.screens.map { screen in
      let geometry = NativeMediaIndicatorGeometry(screen: screen)
      return [
        "screenFrame": NSStringFromRect(screen.frame),
        "panelFrame": NSStringFromRect(geometry.panelFrame),
        "notch": NSStringFromRect(geometry.notch), "scale": screen.backingScaleFactor,
        "strokeWidth": geometry.strokeWidth, "gap": geometry.gap,
        "hardwareOverlap": geometry.hardwareOverlap,
      ]
    }
    do {
      try JSONSerialization.data(withJSONObject: screens, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("media-displays.json"))
    } catch { failures.append("cannot save media display diagnostics: \(error)") }
  }
  return failures
}

/// Raster captures use only the fixture's views, never a screen/clipboard capture.
@MainActor func nativeMediaSmokeScreenshots(shelf: NSWindow) -> [String] {
  guard NativeProfile.isolatedFixture,
    let directory = ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_SCREENSHOT_DIR"]
  else { return ["media captures require an isolated desktop fixture"] }
  var failures: [String] = []
  let reference: NativeMediaPhotoReference
  do {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tests/fixtures/media-indicator/macbook-photo.json")
    reference = try JSONDecoder().decode(
      NativeMediaPhotoReference.self, from: Data(contentsOf: path))
  } catch { return ["cannot load independent hardware photo fixture: \(error)"] }
  guard let content = shelf.contentView,
    let shelfBitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
  else { return ["cannot capture fixture shelf for media screenshots"] }
  content.layoutSubtreeIfNeeded()
  content.cacheDisplay(in: content.bounds, to: shelfBitmap)
  let shelfImage = NSImage(size: content.bounds.size)
  shelfImage.addRepresentation(shelfBitmap)
  let states: [(String, NativeMediaPresentation)] = [
    ("camera", .init(camera: "active", microphone: "inactive")),
    ("microphone", .init(camera: "inactive", microphone: "active")),
    ("both", .init(camera: "active", microphone: "active")),
    ("unavailable", .init(camera: "unknown", microphone: "unknown")),
  ]
  var fixtures: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("", 180, 32, 2), ("narrow", 140, 28, 2), ("wide", 240, 40, 2),
    ("scaled-small", 144, 25.6, 2), ("scaled-large", 225, 40, 2),
    ("non-retina", 180, 32, 1), ("no-notch", 0, 0, 2),
  ]
  if let screen = NSScreen.screens.first(where: {
    NativeMediaIndicatorGeometry(screen: $0).hasNotch
  }) {
    let geometry = NativeMediaIndicatorGeometry(screen: screen)
    fixtures.append(
      ("reported-display", geometry.notch.width, geometry.notch.height, screen.backingScaleFactor))
  }
  for (fixture, width, height, scale) in fixtures {
    for (name, state) in states {
      for open in [false, true] {
        let size = NSSize(width: 620, height: open ? 280 : 100)
        let geometry = NativeMediaIndicatorGeometry(
          screenFrame: CGRect(
            origin: .zero,
            size: CGSize(width: 620, height: 900)),
          leftArea: CGRect(x: 0, y: 900 - height, width: (620 - width) / 2, height: height),
          rightArea: CGRect(
            x: (620 + width) / 2, y: 900 - height,
            width: (620 - width) / 2, height: height), safeTop: height, scale: scale)
        let view = NSHostingView(
          rootView: NativeMediaSmokePreview(
            state: state, geometry: geometry, reference: reference,
            shelf: open ? shelfImage : nil
          ).frame(width: size.width, height: size.height, alignment: .top))
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard
          let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
          failures.append("cannot allocate media screenshot")
          continue
        }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
          guard let png = bitmap.representation(using: .png, properties: [:]) else {
            failures.append("cannot encode media screenshot")
            continue
          }
          try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(
              "media-\(fixture.isEmpty ? "" : fixture + "-")\(name)-\(open ? "open" : "closed").png"
            ))
        } catch { failures.append("cannot save media screenshot: \(error)") }
      }
    }
  }
  return failures
}

private struct NativeMediaSmokePreview: View {
  let state: NativeMediaPresentation
  let geometry: NativeMediaIndicatorGeometry
  let reference: NativeMediaPhotoReference
  let shelf: NSImage?
  var body: some View {
    GeometryReader { container in
      ZStack(alignment: .top) {
        LinearGradient(
          colors: [
            Color(red: 0.24, green: 0.32, blue: 0.43),
            Color(red: 0.12, green: 0.18, blue: 0.25),
          ], startPoint: .topLeading, endPoint: .bottomTrailing)
        if let shelf {
          Image(nsImage: shelf).resizable().frame(width: 560, height: shelf.size.height)
        }
        NativeMediaIndicatorView(state: state, geometry: geometry)
          .frame(width: geometry.panelFrame.width, height: geometry.panelFrame.height)
        // This mask is traced from the user's hardware photo independently of
        // the renderer. Do not replace it with the production circle formula.
        if geometry.hasNotch {
          NativeMediaPhotoNotch(
            reference: reference, width: geometry.notch.width, height: geometry.notch.height
          ).fill(
            .black
          )
          .frame(
            width: geometry.notch.width + reference.shoulder * geometry.notch.height
              / reference.referenceHeight * 2,
            height: geometry.notch.height)
        }
      }.frame(width: container.size.width, height: container.size.height, alignment: .top).clipped()
    }
  }
}

private struct NativeMediaPhotoReference: Decodable {
  let referenceWidth: CGFloat
  let referenceHeight: CGFloat
  let leftEdge: [[CGFloat]]
  var shoulder: CGFloat { -(leftEdge.map { $0[0] }.min() ?? 0) }
}

private struct NativeMediaPhotoNotch: Shape {
  let reference: NativeMediaPhotoReference
  var width: CGFloat
  var height: CGFloat
  func path(in rect: CGRect) -> Path {
    let factor = height / reference.referenceHeight
    let left = reference.shoulder * factor
    let edge = reference.leftEdge.map { CGPoint(x: $0[0] * factor, y: $0[1] * factor) }
    var path = Path()
    for (index, point) in edge.enumerated() {
      let point = CGPoint(x: left + point.x, y: point.y)
      if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    for point in edge.reversed() {
      path.addLine(to: CGPoint(x: left + width - point.x, y: point.y))
    }
    path.closeSubpath()
    return path
  }
}
