import Foundation

public struct Calculation: Equatable, Codable, Sendable {
  public enum Status: String, Codable, Sendable { case result, incomplete, error }
  public var status: Status
  public var expression: String
  public var value: String?
  public var message: String?
  public var conversion: String?
  public var interpretation: String?
  public var displayValue: String?
  public var sourceDate: String?
  public init(
    status: Status, expression: String, value: String? = nil, message: String? = nil,
    conversion: String? = nil, interpretation: String? = nil, displayValue: String? = nil,
    sourceDate: String? = nil
  ) {
    self.status = status
    self.expression = expression
    self.value = value
    self.message = message
    self.conversion = conversion
    self.interpretation = interpretation
    self.displayValue = displayValue
    self.sourceDate = sourceDate
  }
}
public struct CalculationContext: Sendable {
  public var now: Date
  public var sourceDate: String?
  public init(now: Date = Date(), sourceDate: String? = nil) {
    self.now = now
    self.sourceDate = sourceDate
  }
}

// Foundation regular expressions preserve the existing query grammar, including Cyrillic aliases.
func regexGroups(_ pattern: String, _ text: String, insensitive: Bool = false) -> [String]? {
  guard
    let regex = try? NSRegularExpression(
      pattern: pattern, options: insensitive ? [.caseInsensitive] : []),
    let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
  else { return nil }
  return (0..<match.numberOfRanges).map { index in
    guard let range = Range(match.range(at: index), in: text) else { return "" }
    return String(text[range])
  }
}
func regexReplace(
  _ pattern: String, _ text: String, _ replacement: String, insensitive: Bool = false
) -> String {
  guard
    let regex = try? NSRegularExpression(
      pattern: pattern, options: insensitive ? [.caseInsensitive] : [])
  else { return text }
  return regex.stringByReplacingMatches(
    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
}
// Round decimal noise, then follow JavaScript's number formatting thresholds.
func calculationNumber(_ number: Double, precision: Int = 15) -> String {
  if number == 0 { return "0" }
  // The locale-taking formatter uses ICU rounding, which differs from the binary
  // toPrecision rounding at decimal ties. C printf gives the shipping JS result.
  let rounded = Double(String(format: "%.*g", precision, number)) ?? number
  var text = String(rounded)
  if abs(rounded) >= 1e-6 && abs(rounded) < 1e21 {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.maximumFractionDigits = 32
    formatter.maximumSignificantDigits = precision
    formatter.usesSignificantDigits = true
    text = formatter.string(from: NSNumber(value: rounded)) ?? text
  }
  text = regexReplace("\\.0(?=e|$)", text, "")
  text = regexReplace("e([+-])0+(\\d+)", text, "e$1$2")
  return text
}

public enum Calculator {
  public static func calculate(_ query: String, context: CalculationContext = CalculationContext())
    -> Calculation?
  {
    let expression = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if let result = TimeConversions.convert(expression, context: context)
      ?? UnitConversions.convert(expression)
    {
      return result
    }
    var source = regexReplace("^=\\s*", expression, "")
    source = regexReplace("[×хx]", source, "*")
    source = source.replacingOccurrences(of: "÷", with: "/").replacingOccurrences(
      of: "−", with: "-"
    ).replacingOccurrences(of: ",", with: ".")
    source = regexReplace("%\\s*(?:of|от)\\s*", source, "% * ", insensitive: true)
    guard !source.isEmpty, regexGroups("^[\\d\\s.eE+\\-*/^()%]+$", source) != nil,
      expression.hasPrefix("=") || regexGroups("[+\\-*/^%]", source) != nil
    else { return nil }
    guard source.count <= 512 else {
      return Calculation(
        status: .error, expression: expression, message: "Слишком длинное выражение")
    }
    let regex = try! NSRegularExpression(
      pattern: "(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][+-]?\\d+)?|[^\\s]")
    let tokens = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
      String(source[Range($0.range, in: source)!])
    }
    var parser = ArithmeticParser(tokens: tokens)
    do {
      let value = try parser.sum()
      guard parser.position == tokens.count else {
        throw ArithmeticFailure.message("Проверьте выражение")
      }
      guard value.isFinite else {
        throw ArithmeticFailure.message("Результат вне допустимого диапазона")
      }
      return Calculation(status: .result, expression: expression, value: calculationNumber(value))
    } catch ArithmeticFailure.incomplete {
      return Calculation(status: .incomplete, expression: expression)
    } catch ArithmeticFailure.message(let message) {
      return Calculation(status: .error, expression: expression, message: message)
    } catch {
      return Calculation(status: .error, expression: expression, message: "Проверьте выражение")
    }
  }
}
private enum ArithmeticFailure: Error {
  case incomplete
  case message(String)
}
private struct ArithmeticParser {
  var tokens: [String]
  var position = 0
  var peek: String? { position < tokens.count ? tokens[position] : nil }
  mutating func take(_ token: String) -> Bool {
    guard peek == token else { return false }
    position += 1
    return true
  }
  mutating func primary() throws -> Double {
    guard peek != nil else { throw ArithmeticFailure.incomplete }
    if take("(") {
      let value = try sum()
      if !take(")") {
        if peek == nil { throw ArithmeticFailure.incomplete }
        throw ArithmeticFailure.message("Проверьте скобки")
      }
      return value
    }
    let token = tokens[position]
    position += 1
    guard regexGroups("^(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][+-]?\\d+)?$", token) != nil,
      let value = Double(token)
    else {
      throw ArithmeticFailure.message("Проверьте выражение")
    }
    return value
  }
  mutating func power() throws -> Double {
    var value = try primary()
    if take("%") { value /= 100 }
    if take("^") { value = pow(value, try unary()) }
    return value
  }
  mutating func unary() throws -> Double {
    if take("+") { return try unary() }
    if take("-") { return -(try unary()) }
    return try power()
  }
  mutating func product() throws -> Double {
    var value = try unary()
    while peek == "*" || peek == "/" {
      let operation = tokens[position]
      position += 1
      let right = try unary()
      if operation == "/" && right == 0 { throw ArithmeticFailure.message("На ноль делить нельзя") }
      value = operation == "*" ? value * right : value / right
    }
    return value
  }
  mutating func sum() throws -> Double {
    var value = try product()
    while peek == "+" || peek == "-" {
      let operation = tokens[position]
      position += 1
      let right = try product()
      value = operation == "+" ? value + right : value - right
    }
    return value
  }
}
