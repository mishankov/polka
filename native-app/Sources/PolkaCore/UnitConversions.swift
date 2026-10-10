import Foundation

public enum UnitConversions {
  private struct Unit {
    let dimension: String
    let symbol: String
    let scale: Double
    let offset: Double
    var aliases: [String]
  }
  private static let units: [Unit] = [
    Unit(
      dimension: "length", symbol: "mm", scale: 0.001, offset: 0,
      aliases: [
        "mm", "millimeter", "millimeters", "millimetre", "millimetres", "мм", "миллиметр",
        "миллиметра", "миллиметров", "миллиметры",
      ]),
    Unit(
      dimension: "length", symbol: "cm", scale: 0.01, offset: 0,
      aliases: [
        "cm", "centimeter", "centimeters", "centimetre", "centimetres", "см", "сантиметр",
        "сантиметра", "сантиметров", "сантиметры",
      ]),
    Unit(
      dimension: "length", symbol: "m", scale: 1, offset: 0,
      aliases: ["m", "meter", "meters", "metre", "metres", "м", "метр", "метра", "метров", "метры"]),
    Unit(
      dimension: "length", symbol: "km", scale: 1000, offset: 0,
      aliases: [
        "km", "kilometer", "kilometers", "kilometre", "kilometres", "км", "километр", "километра",
        "километров", "километры",
      ]),
    Unit(
      dimension: "length", symbol: "in", scale: 0.0254, offset: 0,
      aliases: ["in", "inch", "inches", "дюйм", "дюйма", "дюймов", "дюймы", "\"", "″"]),
    Unit(
      dimension: "length", symbol: "ft", scale: 0.3048, offset: 0,
      aliases: ["ft", "foot", "feet", "фут", "фута", "футов", "футы", "'", "′"]),
    Unit(
      dimension: "length", symbol: "yd", scale: 0.9144, offset: 0,
      aliases: ["yd", "yard", "yards", "ярд", "ярда", "ярдов", "ярды"]),
    Unit(
      dimension: "length", symbol: "mi", scale: 1609.344, offset: 0,
      aliases: ["mi", "mile", "miles", "миля", "мили", "миль"]),
    Unit(
      dimension: "mass", symbol: "mg", scale: 1e-06, offset: 0,
      aliases: [
        "mg", "milligram", "milligrams", "мг", "миллиграмм", "миллиграмма", "миллиграммов",
        "миллиграммы",
      ]),
    Unit(
      dimension: "mass", symbol: "g", scale: 0.001, offset: 0,
      aliases: ["g", "gram", "grams", "г", "грамм", "грамма", "граммов", "граммы"]),
    Unit(
      dimension: "mass", symbol: "kg", scale: 1, offset: 0,
      aliases: [
        "kg", "kilogram", "kilograms", "кг", "килограмм", "килограмма", "килограммов", "килограммы",
      ]),
    Unit(
      dimension: "mass", symbol: "t", scale: 1000, offset: 0,
      aliases: ["t", "tonne", "tonnes", "metric ton", "metric tons", "т", "тонна", "тонны", "тонн"]),
    Unit(
      dimension: "mass", symbol: "oz", scale: 0.028349523125, offset: 0,
      aliases: ["oz", "ounce", "ounces", "унция", "унции", "унций"]),
    Unit(
      dimension: "mass", symbol: "lb", scale: 0.45359237, offset: 0,
      aliases: ["lb", "lbs", "pound", "pounds", "фунт", "фунта", "фунтов", "фунты"]),
    Unit(
      dimension: "duration", symbol: "ms", scale: 0.001, offset: 0,
      aliases: [
        "ms", "millisecond", "milliseconds", "мс", "миллисекунда", "миллисекунды", "миллисекунд",
      ]),
    Unit(
      dimension: "duration", symbol: "s", scale: 1, offset: 0,
      aliases: [
        "s", "sec", "secs", "second", "seconds", "с", "сек", "секунда", "секунды", "секунд",
      ]),
    Unit(
      dimension: "duration", symbol: "min", scale: 60, offset: 0,
      aliases: ["min", "mins", "minute", "minutes", "мин", "минута", "минуты", "минут"]),
    Unit(
      dimension: "duration", symbol: "h", scale: 3600, offset: 0,
      aliases: ["h", "hr", "hrs", "hour", "hours", "ч", "час", "часа", "часов", "часы"]),
    Unit(
      dimension: "duration", symbol: "d", scale: 86400, offset: 0,
      aliases: ["d", "day", "days", "д", "день", "дня", "дней", "дни", "сутки", "суток"]),
    Unit(
      dimension: "duration", symbol: "wk", scale: 604800, offset: 0,
      aliases: ["wk", "week", "weeks", "нед", "неделя", "недели", "недель"]),
    Unit(
      dimension: "temperature", symbol: "°C", scale: 1, offset: 273.15,
      aliases: [
        "°C", "c", "°c", "celsius", "degree celsius", "degrees celsius", "цельсий", "цельсия", "°с",
        "с",
      ]),
    Unit(
      dimension: "temperature", symbol: "°F", scale: 5.0 / 9.0, offset: 273.15 - (32.0 * 5.0) / 9.0,
      aliases: [
        "°F", "f", "°f", "fahrenheit", "degree fahrenheit", "degrees fahrenheit", "фаренгейт",
        "фаренгейта",
      ]),
    Unit(
      dimension: "temperature", symbol: "K", scale: 1, offset: 0,
      aliases: ["K", "kelvin", "kelvins", "к", "кельвин", "кельвина", "кельвинов"]),
  ]
  private static func normalize(_ text: String) -> String {
    regexReplace(
      "\\.$",
      regexReplace("\\s+", text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), " "),
      "")
  }
  private static let aliases: [String: [Int]] = {
    var cases: [String: [String]] = [:]
    func noun(_ symbol: String, _ stem: String, _ endings: String) {
      cases[symbol, default: []] += endings.components(separatedBy: "|").map { stem + $0 }
    }
    let masculine = "|а|у|ом|е|ы|ов|ам|ами|ах"
    for (symbol, stem) in [
      ("mm", "миллиметр"), ("cm", "сантиметр"), ("m", "метр"), ("km", "километр"), ("in", "дюйм"),
      ("ft", "фут"), ("yd", "ярд"), ("mg", "миллиграмм"), ("g", "грамм"), ("kg", "килограмм"),
      ("lb", "фунт"), ("h", "час"), ("K", "кельвин"), ("°F", "фаренгейт"),
    ] { noun(symbol, stem, masculine) }
    for (symbol, stem) in [("t", "тонн"), ("ms", "миллисекунд"), ("s", "секунд"), ("min", "минут")]
    { noun(symbol, stem, "а|ы|е|у|ой|ою||ам|ами|ах") }
    noun("mi", "мил", "я|и|е|ю|ей|ею|ь|ям|ями|ях")
    noun("oz", "унци", "я|и|ю|ей|ею|й|ям|ями|ях")
    noun("wk", "недел", "я|и|е|ю|ей|ею|ь|ям|ями|ях")
    noun(
      "d", "",
      "день|дня|дню|днём|днем|дне|дни|дней|дням|днями|днях|сутки|суток|суткам|сутками|сутках")
    noun("°C", "цельси", "й|я|ю|ем|и")
    for (symbol, scale) in [("°C", "цельсия"), ("°F", "фаренгейта")] {
      noun(
        symbol, "",
        masculine.components(separatedBy: "|").map { "градус" + $0 + " " + scale }.joined(
          separator: "|"))
    }
    var result: [String: [Int]] = [:]
    for (index, unit) in units.enumerated() {
      for alias in Set((unit.aliases + (cases[unit.symbol] ?? [])).map(normalize)) {
        result[alias, default: []].append(index)
      }
    }
    return result
  }()
  private static let ambiguous: Set<String> = [
    "ton", "tons", "тн", "month", "months", "месяц", "месяца", "месяцев",
  ]
  public static func convert(_ expression: String) -> Calculation? {
    if expression.count > 512 {
      return regexGroups("^[+−-]?(?:\\d|[.,]\\d)", expression) != nil
        && regexGroups("\\s(?:in|to|в)(?:\\s|$)", expression, insensitive: true) != nil
        ? Calculation(
          status: .error, expression: expression, message: localized("Expression is too long"))
        : nil
    }
    guard
      let match = regexGroups(
        "^([+−-]?(?:\\d+(?:[.,]\\d*)?|[.,]\\d+)(?:e[+-]?\\d+)?)\\s*(.+?)\\s+(?:in|to|в)(?:\\s+|$)(.*)$",
        expression, insensitive: true)
    else { return nil }
    let rawValue = match[1]
    let rawSource = match[2]
    let rawTarget = match[3]
    let sourceName = normalize(rawSource)
    let targetName = normalize(rawTarget)
    var source = aliases[sourceName]
    var target = aliases[targetName]
    guard
      source != nil || target != nil || ambiguous.contains(sourceName)
        || ambiguous.contains(targetName)
    else { return nil }
    func error(_ message: String) -> Calculation {
      Calculation(status: .error, expression: expression, message: message)
    }
    if targetName.isEmpty {
      return Calculation(
        status: .incomplete, expression: expression,
        message: localized("Enter the result unit, for example: 10 inches in cm"))
    }
    if let from = source, let to = target {
      let pairs = from.flatMap { a in
        to.filter { units[$0].dimension == units[a].dimension }.map { (a, $0) }
      }
      if pairs.count == 1 {
        source = [pairs[0].0]
        target = [pairs[0].1]
      }
    }
    if ambiguous.contains(sourceName) || ambiguous.contains(targetName) || (source?.count ?? 0) > 1
      || (target?.count ?? 0) > 1
    {
      return error(
        localized(
          "Ambiguous unit. Specify: m for meters, s for seconds, °C for temperature, tonne for metric tons. Months do not have a fixed duration."
        )
      )
    }
    guard let fromIndex = source?.first, let toIndex = target?.first else {
      return error(
        localized(
          "Unknown unit: {0}. Length, mass, temperature, and duration are supported.",
          String(describing: source == nil ? rawSource : rawTarget))
      )
    }
    let from = units[fromIndex]
    let to = units[toIndex]
    guard from.dimension == to.dimension else {
      return error(localized("Choose units of the same quantity, such as length to length."))
    }
    let amount =
      Double(
        rawValue.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-"))
      ?? .infinity
    let absoluteZero = from.symbol == "°C" ? -273.15 : from.symbol == "°F" ? -459.67 : 0
    var base = amount * from.scale + from.offset
    if from.dimension == "temperature" && amount < absoluteZero {
      return error(localized("Temperature is below absolute zero"))
    }
    if from.dimension == "temperature" && base < 0 { base = 0 }
    let converted = fromIndex == toIndex ? amount : (base - to.offset) / to.scale
    guard amount.isFinite && converted.isFinite else {
      return error(localized("Result is out of range"))
    }
    return Calculation(
      status: .result, expression: expression,
      value: calculationNumber(converted, precision: 12) + " " + to.symbol, conversion: "unit",
      interpretation: calculationNumber(amount, precision: 17) + " " + from.symbol + " → "
        + to.symbol)
  }
}
