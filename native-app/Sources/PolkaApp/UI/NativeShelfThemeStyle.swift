import AppKit
import SwiftUI

extension NativeShelfTheme {
  /// The original Polka theme continues to follow the system's accent and
  /// native dark control colors. Its catalog colors are a starting point for copies.
  var shelfColors: NativeThemeColors? {
    id == NativeThemeSettings.standard.id ? nil : colors
  }
}

private struct NativeShelfThemeKey: EnvironmentKey {
  static let defaultValue: NativeThemeColors? = nil
}

private struct NativeShelfSelectionKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var shelfColors: NativeThemeColors? {
    get { self[NativeShelfThemeKey.self] }
    set { self[NativeShelfThemeKey.self] = newValue }
  }
  fileprivate var shelfRowSelected: Bool {
    get { self[NativeShelfSelectionKey.self] }
    set { self[NativeShelfSelectionKey.self] = newValue }
  }
}

private struct ThemeRGB {
  let red: Double
  let green: Double
  let blue: Double

  init(_ hex: String) {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    red = Double((value >> 16) & 0xff) / 255
    green = Double((value >> 8) & 0xff) / 255
    blue = Double(value & 0xff) / 255
  }

  private init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  var appKit: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
  var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue) }

  private var luminance: Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  func contrast(with other: ThemeRGB) -> Double {
    let first = luminance
    let second = other.luminance
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }

  func mixed(with other: ThemeRGB, amount: Double) -> ThemeRGB {
    ThemeRGB(
      red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
      blue: blue + (other.blue - blue) * amount)
  }

  var legibleText: ThemeRGB {
    let black = ThemeRGB("#000000")
    let white = ThemeRGB("#FFFFFF")
    return contrast(with: black) >= contrast(with: white) ? black : white
  }
}

extension NativeThemeColors {
  private var selectionInk: ThemeRGB {
    let fill = ThemeRGB(selection)
    let primary = ThemeRGB(text)
    return primary.contrast(with: fill) >= 4.5 ? primary : fill.legibleText
  }

  private func mutedInk(selected: Bool) -> ThemeRGB {
    let primary = selected ? selectionInk : ThemeRGB(text)
    let base = ThemeRGB(selected ? selection : background)
    let muted = primary.mixed(with: base, amount: 0.21)
    let surface = selected ? base : ThemeRGB(surface)
    return muted.contrast(with: base) >= 4.5 && muted.contrast(with: surface) >= 4.5
      ? muted : primary
  }

  var backgroundColor: Color { ThemeRGB(background).swiftUI }
  var surfaceColor: Color { ThemeRGB(surface).swiftUI }
  var searchHeaderColor: Color {
    ThemeRGB(background).mixed(with: ThemeRGB(surface), amount: 0.6).swiftUI
  }
  var textColor: Color { ThemeRGB(text).swiftUI }
  var secondaryTextColor: Color { mutedInk(selected: false).swiftUI }
  var accentColor: Color { ThemeRGB(accent).swiftUI }
  var accentTextColor: Color { ThemeRGB(accent).legibleText.swiftUI }
  var selectionColor: Color { ThemeRGB(selection).swiftUI }
  var selectionTextColor: Color { selectionInk.swiftUI }

  // A low-contrast fill needs an outline to expose the keyboard selection.
  var selectionOutlineColor: Color? {
    let fill = ThemeRGB(selection)
    let base = ThemeRGB(background)
    guard fill.contrast(with: base) < 3 else { return nil }
    let color = ThemeRGB(accent)
    return (color.contrast(with: base) >= 3 ? color : base.legibleText).swiftUI
  }

  var focusColor: Color {
    let fill = ThemeRGB(surface)
    let color = ThemeRGB(accent)
    return (color.contrast(with: fill) >= 3 ? color : fill.legibleText).swiftUI
  }

  var textContrastRatio: Double {
    let primary = ThemeRGB(text)
    return min(
      primary.contrast(with: ThemeRGB(background)), primary.contrast(with: ThemeRGB(surface)))
  }

  var colorScheme: ColorScheme {
    let color = ThemeRGB(background)
    return color.contrast(with: ThemeRGB("#000000")) >= color.contrast(with: ThemeRGB("#FFFFFF"))
      ? .light : .dark
  }

  func foreground(selected: Bool = false, muted: Bool = false) -> Color {
    if muted { return mutedInk(selected: selected).swiftUI }
    return (selected ? selectionInk : ThemeRGB(text)).swiftUI
  }

  func detailForeground(selected: Bool = false) -> Color {
    if let detailAccent {
      let ink = ThemeRGB(detailAccent)
      let fill = ThemeRGB(selected ? selection : background)
      if ink.contrast(with: fill) >= 4.5 { return ink.swiftUI }
    }
    return mutedInk(selected: selected).swiftUI
  }

  func appKitForeground(selected: Bool = false, muted: Bool = false) -> NSColor {
    if muted { return mutedInk(selected: selected).appKit }
    return (selected ? selectionInk : ThemeRGB(text)).appKit
  }

  static func appKitColor(_ hex: String) -> NSColor { ThemeRGB(hex).appKit }

  func statusColor(error: Bool = false) -> Color {
    let light = colorScheme == .light
    let ink = ThemeRGB(error ? (light ? "#9D2635" : "#FFA1A6") : (light ? "#90350A" : "#FFC27A"))
    return ink.contrast(with: ThemeRGB(surface)) >= 4.5
      && ink.contrast(with: ThemeRGB(background)) >= 4.5 ? ink.swiftUI : textColor
  }
}

private struct NativeShelfRowStyle: ViewModifier {
  @Environment(\.shelfColors) private var colors
  let selected: Bool
  let defaultOpacity: Double
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let primary = colors?.foreground(selected: selected) ?? .primary
    let secondary = colors?.foreground(selected: selected, muted: true) ?? .secondary
    content
      .foregroundStyle(
        AnyShapeStyle(primary), AnyShapeStyle(secondary),
        colors == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(secondary)
      )
      .environment(\.shelfRowSelected, selected)
      .background(
        selected ? (colors?.selectionColor ?? Color.accentColor.opacity(defaultOpacity)) : .clear,
        in: RoundedRectangle(cornerRadius: cornerRadius)
      )
      .overlay {
        if selected, let outline = colors?.selectionOutlineColor {
          RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(outline)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
  }
}

private struct NativeShelfSecondaryStyle: ViewModifier {
  @Environment(\.shelfColors) private var colors
  @Environment(\.shelfRowSelected) private var selected
  let fallback: HierarchicalShapeStyle
  var usesDetailAccent = false

  func body(content: Content) -> some View {
    content.foregroundStyle(
      colors.map { colors in
        let ink =
          usesDetailAccent
          ? colors.detailForeground(selected: selected)
          : colors.foreground(selected: selected, muted: true)
        return AnyShapeStyle(ink)
      } ?? AnyShapeStyle(fallback))
  }
}

extension View {
  func nativeShelfSecondary(_ fallback: HierarchicalShapeStyle = .secondary) -> some View {
    modifier(NativeShelfSecondaryStyle(fallback: fallback))
  }
  func nativeShelfDetail(_ fallback: HierarchicalShapeStyle = .secondary) -> some View {
    modifier(NativeShelfSecondaryStyle(fallback: fallback, usesDetailAccent: true))
  }
  func nativeShelfRow(selected: Bool, defaultOpacity: Double, cornerRadius: CGFloat = 7)
    -> some View
  {
    modifier(
      NativeShelfRowStyle(
        selected: selected, defaultOpacity: defaultOpacity, cornerRadius: cornerRadius))
  }
}
