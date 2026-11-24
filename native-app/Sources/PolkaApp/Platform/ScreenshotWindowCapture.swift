import AppKit
import PolkaCore
import ScreenCaptureKit

struct NativeScreenshotWindowTarget {
  let id: CGWindowID
  let frame: CGRect

  @MainActor static func below(
    _ overlay: Int, at point: CGPoint, desktopTop: CGFloat, previous: Self?
  ) -> Self? {
    // Use WindowServer hit testing so transparent and click-through windows do
    // not obscure the target. Only look up geometry when the target changes.
    let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: overlay)
    guard let id = CGWindowID(exactly: number), id != kCGNullWindowID else { return nil }
    if let previous, previous.id == id { return previous }
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let info = windows.first(where: { $0[kCGWindowNumber as String] as? CGWindowID == id }),
      let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
      let bounds = info[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), !rect.isEmpty
    else { return nil }
    return Self(id: id, frame: NativeScreenshotCapture.captureRect(rect, desktopTop: desktopTop))
  }
}

extension NativeScreenshotCapture {
  static func captureWindow(_ id: CGWindowID, omitShadow: Bool, in content: SCShareableContent)
    async throws -> CGImage
  {
    try Task.checkCancellation()
    guard let window = content.windows.first(where: { $0.windowID == id }) else {
      throw PolkaCoreError.invalid(
        localized("The selected window is no longer available for capture."))
    }
    let configuration = SCScreenshotConfiguration()
    configuration.showsCursor = false
    configuration.ignoreShadows = omitShadow
    configuration.includeChildWindows = false
    configuration.dynamicRange = .sdr
    let output = try await SCScreenshotManager.captureScreenshot(
      contentFilter: SCContentFilter(desktopIndependentWindow: window),
      configuration: configuration)
    guard let image = output.sdrImage else {
      throw PolkaCoreError.invalid(localized("Could not render the screenshot"))
    }
    return image
  }
}
