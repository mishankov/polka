import AppKit
import PolkaCore

@MainActor final class NativeScreenshotStylePreferences {
  static let settingsKey = "screenshotAnnotationStyle"
  private static let colors: [(String, WritableKeyPath<NativeScreenshotStyle, NSColor>)] = [
    ("arrowColor", \.arrowColor), ("lineColor", \.lineColor), ("rectangleColor", \.rectangleColor),
    ("textColor", \.textColor), ("textBackground", \.textBackground),
  ]
  private static let sizes:
    [(String, WritableKeyPath<NativeScreenshotStyle, CGFloat>, ClosedRange<CGFloat>)] = [
      ("arrowWidth", \.arrowWidth, 1...32), ("lineWidth", \.lineWidth, 1...32),
      ("rectangleWidth", \.rectangleWidth, 1...32),
      ("textSize", \.textSize, 8...160),
    ]
  private let settings: SettingsStore
  private var values: [String: Any]

  init(settings: SettingsStore) {
    self.settings = settings
    values = (try? settings.get(key: Self.settingsKey)) as? [String: Any] ?? [:]
  }

  func applying(to defaults: NativeScreenshotStyle) -> NativeScreenshotStyle {
    var style = defaults
    for (name, key) in Self.colors {
      if let rgba = values[name] as? [Double], rgba.count == 4,
        rgba.allSatisfy({ (0...1).contains($0) })
      {
        style[keyPath: key] = NSColor(
          srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
      }
    }
    for (name, key, range) in Self.sizes {
      if let value = values[name] as? Double, range.contains(CGFloat(value)) {
        style[keyPath: key] = CGFloat(value)
      }
    }
    if let filled = values["rectangleFilled"] as? Bool { style.rectangleFilled = filled }
    return style
  }

  func saveChanges(from previous: NativeScreenshotStyle, to style: NativeScreenshotStyle) throws {
    // Each editor can start with an older snapshot. Merge only the fields it changes.
    for (name, key) in Self.colors where style[keyPath: key] != previous[keyPath: key] {
      if let color = style[keyPath: key].usingColorSpace(.sRGB) {
        values[name] = [
          color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent,
        ].map(Double.init)
      }
    }
    for (name, key, range) in Self.sizes where style[keyPath: key] != previous[keyPath: key] {
      let value = style[keyPath: key]
      if range.contains(value) { values[name] = Double(value) }
    }
    if style.rectangleFilled != previous.rectangleFilled {
      values["rectangleFilled"] = style.rectangleFilled
    }
    try settings.set(key: Self.settingsKey, value: values)
  }
}
