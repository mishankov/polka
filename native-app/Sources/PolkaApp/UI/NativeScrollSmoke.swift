import AppKit
import PolkaCore

/// Exercise the actual launcher and AppKit scroll view in a disposable profile.
/// Catalogs, icons and scroll events are synthetic; no installed app is opened.
@MainActor func nativeScrollSmoke(
  application: NativeApplication, shelf: NSWindow, model: NativeUIModel
) async -> [String: Any] {
  guard NativeProfile.isolatedFixture else {
    return ["ok": false, "failures": ["scroll smoke requires isolated profile"]]
  }
  var failures: [String] = []
  let icon = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
  for x in 0..<32 { for y in 0..<32 { icon.setColor(.systemBlue, atX: x, y: y) } }
  let iconURL =
    "data:image/png;base64,"
    + icon.representation(using: .png, properties: [:])!.base64EncodedString()
  let apps = (0..<300).map {
    NativeLauncherApp(
      id: "synthetic:\($0)", name: String(format: "Synthetic app %03d", $0), icon: iconURL,
      description: "Synthetic scroll catalog")
  }
  var searches = 0
  model.searchProvider = { query in
    searches += 1
    return LauncherSearch.apps(apps, query: query).map {
      NativeUISearchRow(
        id: $0.id, kind: "app", title: $0.name, detail: $0.description, icon: $0.icon)
    }
  }
  model.settings.introduced = true
  await application.show("apps")
  try? await Task.sleep(nanoseconds: 350_000_000)
  func findScroll(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for child in view.subviews { if let scroll = findScroll(child) { return scroll } }
    return nil
  }
  guard let view = shelf.contentView, let scroll = findScroll(view) else {
    return ["ok": false, "failures": ["native launcher scroll view not found"]]
  }
  searches = 0
  let initialOffset = scroll.contentView.bounds.origin.y
  var timings: [Double] = []
  for tick in 0..<60 {
    let started = ProcessInfo.processInfo.systemUptime
    guard
      let cg = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -45, wheel2: 0,
        wheel3: 0), let event = NSEvent(cgEvent: cg)
    else {
      failures.append("cannot create synthetic wheel event")
      break
    }
    scroll.scrollWheel(with: event)
    // Selection changes occur as content passes underneath the mouse too.
    let id = apps[tick].id
    if model.selectedID != id { model.selectedID = id }
    try? await Task.sleep(nanoseconds: 16_666_667)
    timings.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
  }
  if scroll.contentView.bounds.origin.y <= initialOffset {
    failures.append("wheel events did not scroll launcher content")
  }
  if searches > 2 { failures.append("scrolling repeated launcher search \(searches) times") }
  let scrollSearches = searches
  let savedOffset = scroll.contentView.bounds.origin.y
  if abs(model.listScrollOffset - savedOffset) > 1 {
    failures.append("launcher did not save native scroll position")
  }
  application.hide()
  try? await Task.sleep(nanoseconds: 230_000_000)
  await application.show(nil)
  try? await Task.sleep(nanoseconds: 350_000_000)
  if let current = shelf.contentView.flatMap(findScroll) {
    if abs(current.contentView.bounds.origin.y - savedOffset) > 1 {
      failures.append("launcher scroll position was not restored after fully closing")
    }
  } else {
    failures.append("restored launcher scroll view missing")
  }
  let sorted = timings.sorted()
  let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
  return [
    "ok": failures.isEmpty, "failures": failures, "nativeVisible": shelf.isVisible,
    "destination": model.destination, "catalogSize": apps.count, "scrollSearches": scrollSearches,
    "tickP95Milliseconds": p95, "scrollOffset": scroll.contentView.bounds.origin.y,
  ]
}
