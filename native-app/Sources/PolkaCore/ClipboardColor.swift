import Foundation

/// Display-only color parsing. Never normalize or replace the stored/copyable text.
public struct ClipboardColor: Equatable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public static func parse(_ original: String) -> ClipboardColor? {
    // A color value is tiny. Reject large records before allocating or parsing.
    guard original.utf8.prefix(257).count <= 256 else { return nil }
    let text = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.hasPrefix("#") {
      let digits = Array(text.dropFirst())
      guard [3, 4, 6, 8].contains(digits.count),
        digits.allSatisfy({ $0.isASCII && $0.isHexDigit })
      else { return nil }
      let expanded = digits.count <= 4 ? digits.flatMap { [$0, $0] } : digits
      var channels: [Double] = []
      for index in stride(from: 0, to: expanded.count, by: 2) {
        guard let byte = UInt8(String(expanded[index...index + 1]), radix: 16) else { return nil }
        channels.append(Double(byte) / 255)
      }
      return ClipboardColor(
        red: channels[0], green: channels[1], blue: channels[2],
        alpha: channels.count == 4 ? channels[3] : 1)
    }
    guard let opening = text.firstIndex(of: "("), text.last == ")" else { return nil }
    let function = String(text[..<opening])
    guard ["rgb", "rgba", "hsl", "hsla"].contains(function) else { return nil }
    let body = String(text[text.index(after: opening)..<text.index(before: text.endIndex)])
    let parts: [String]
    if body.contains(",") {
      guard !body.contains("/") else { return nil }
      parts = body.components(separatedBy: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard parts.count == (function.hasSuffix("a") ? 4 : 3) else { return nil }
    } else {
      let groups = body.components(separatedBy: "/")
      guard groups.count <= 2 else { return nil }
      let channels = groups[0].split(whereSeparator: \.isWhitespace).map(String.init)
      guard channels.count == 3 else { return nil }
      parts =
        channels
        + (groups.count == 2 ? [groups[1].trimmingCharacters(in: .whitespacesAndNewlines)] : [])
    }
    func number(_ token: String, maximum: Double) -> Double? {
      // Double also accepts infinities and exponents; color syntax here deliberately doesn't.
      guard
        token.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)$", options: .regularExpression)
          != nil,
        let value = Double(token), value.isFinite, (0...maximum).contains(value)
      else { return nil }
      return value / maximum
    }
    func component(_ token: String, maximum: Double) -> Double? {
      token.hasSuffix("%")
        ? number(String(token.dropLast()), maximum: 100) : number(token, maximum: maximum)
    }
    let alpha: Double
    if parts.count == 4 {
      guard let value = component(parts[3], maximum: 1) else { return nil }
      alpha = value
    } else {
      alpha = 1
    }
    if function.hasPrefix("rgb") {
      // Legacy comma syntax requires all three channels to use the same unit.
      if body.contains(","), Set(parts.prefix(3).map { $0.hasSuffix("%") }).count != 1 {
        return nil
      }
      guard let red = component(parts[0], maximum: 255),
        let green = component(parts[1], maximum: 255),
        let blue = component(parts[2], maximum: 255)
      else { return nil }
      return ClipboardColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    var hueText = parts[0]
    var factor = 1.0
    for (suffix, multiplier) in [
      ("grad", 0.9), ("turn", 360.0), ("rad", 180 / Double.pi), ("deg", 1.0),
    ] {
      if hueText.hasSuffix(suffix) {
        hueText = String(hueText.dropLast(suffix.count))
        factor = multiplier
        break
      }
    }
    guard
      hueText.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)$", options: .regularExpression)
        != nil,
      let hue = Double(hueText), hue.isFinite, abs(hue) <= 1_000_000,
      parts[1].hasSuffix("%"), parts[2].hasSuffix("%"),
      let saturation = component(parts[1], maximum: 100),
      let lightness = component(parts[2], maximum: 100)
    else { return nil }
    let h = (hue * factor).truncatingRemainder(dividingBy: 360) / 60
    let normalized = h < 0 ? h + 6 : h
    let c = (1 - abs(2 * lightness - 1)) * saturation
    let x = c * (1 - abs(normalized.truncatingRemainder(dividingBy: 2) - 1))
    let m = lightness - c / 2
    let rgb: (Double, Double, Double)
    switch normalized {
    case 0..<1: rgb = (c, x, 0)
    case 1..<2: rgb = (x, c, 0)
    case 2..<3: rgb = (0, c, x)
    case 3..<4: rgb = (0, x, c)
    case 4..<5: rgb = (x, 0, c)
    default: rgb = (c, 0, x)
    }
    return ClipboardColor(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: alpha)
  }
}
