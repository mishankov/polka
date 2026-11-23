import Foundation

enum NumberBaseConversions {
  private enum Base: String {
    case bin, oct, dec, hex

    var notation: (prefix: String, radix: Int) {
      switch self {
      case .bin: ("0b", 2)
      case .oct: ("0o", 8)
      case .dec: ("", 10)
      case .hex: ("0x", 16)
      }
    }

    init(literal: String) {
      switch literal.prefix(2).lowercased() {
      case "0b": self = .bin
      case "0o": self = .oct
      case "0x": self = .hex
      default: self = .dec
      }
    }
  }

  static func convert(_ expression: String) -> Calculation? {
    guard
      let match = regexGroups(
        "^([+−-]?)([0-9][0-9a-z]*)\\s+(?:in|to|в)\\s+(bin|oct|dec|hex)$", expression,
        insensitive: true),
      let target = Base(rawValue: match[3].lowercased())
    else { return nil }
    guard expression.count <= 512 else {
      return Calculation(
        status: .error, expression: expression, message: localized("Expression is too long"))
    }
    let literal = match[2]
    let source = Base(literal: literal).notation
    let sign = match[1] == "−" ? "-" : match[1]
    guard let integer = Int64(sign + literal.dropFirst(source.prefix.count), radix: source.radix)
    else {
      return Calculation(
        status: .error, expression: expression, message: localized("Enter a valid 64-bit integer"))
    }
    let digits = String(integer.magnitude, radix: target.notation.radix, uppercase: true)
    return Calculation(
      status: .result, expression: expression,
      value: (integer < 0 ? "-" : "") + target.notation.prefix + digits,
      conversion: "number-base")
  }
}
