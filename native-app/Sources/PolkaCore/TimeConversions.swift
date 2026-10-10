import Foundation

public enum TimeConversions {
  private struct Zone {
    let id: String
    let label: String
    let offset: Int?
  }
  private static let cities: [String: Zone] = {
    var result: [String: Zone] = [:]
    func add(_ id: String, _ label: String, _ names: String) {
      for name in names.components(separatedBy: "|") {
        result[name] = Zone(id: id, label: label, offset: nil)
      }
    }
    add("Europe/Moscow", "Москва", "moscow|москва|москве|msk|мск")
    add("Europe/London", "Лондон", "london|лондон|лондоне")
    add("Europe/Paris", "Париж", "paris|париж|париже")
    add("Europe/Berlin", "Берлин", "berlin|берлин|берлине")
    add("Europe/Rome", "Рим", "rome|рим|риме")
    add("Europe/Madrid", "Мадрид", "madrid|мадрид|мадриде")
    add("Europe/Helsinki", "Хельсинки", "helsinki|хельсинки")
    add("Europe/Istanbul", "Стамбул", "istanbul|стамбул|стамбуле")
    add("Asia/Dubai", "Дубай", "dubai|дубай|дубае")
    add("Asia/Tbilisi", "Тбилиси", "tbilisi|тбилиси")
    add("Asia/Yerevan", "Ереван", "yerevan|ереван|ереване")
    add("Asia/Yekaterinburg", "Екатеринбург", "yekaterinburg|екатеринбург|екатеринбурге")
    add("Asia/Novosibirsk", "Новосибирск", "novosibirsk|новосибирск|новосибирске")
    add("Asia/Vladivostok", "Владивосток", "vladivostok|владивосток|владивостоке")
    add("America/New_York", "Нью-Йорк", "new york|new-york|nyc|нью-йорк|нью-йорке")
    add("America/Los_Angeles", "Лос-Анджелес", "los angeles|los-angeles|лос-анджелес|лос-анджелесе")
    add("America/Chicago", "Чикаго", "chicago|чикаго")
    add("America/Toronto", "Торонто", "toronto|торонто")
    add("America/Sao_Paulo", "Сан-Паулу", "sao paulo|são paulo|сан-паулу")
    add("Asia/Tokyo", "Токио", "tokyo|токио")
    add("Asia/Shanghai", "Шанхай", "shanghai|шанхай|шанхае")
    add("Asia/Hong_Kong", "Гонконг", "hong kong|гонконг|гонконге")
    add("Asia/Singapore", "Сингапур", "singapore|сингапур|сингапуре")
    add("Asia/Kolkata", "Калькутта", "kolkata|калькутта|калькутте")
    add("Australia/Sydney", "Сидней", "sydney|сидней|сиднее")
    add("Pacific/Auckland", "Окленд", "auckland|окленд|окленде")
    return result
  }()
  private static func offsetLabel(_ offset: Int) -> String {
    let seconds = abs(offset)
    let minutes = seconds / 60
    return "UTC" + (offset < 0 ? "−" : "+") + pad(minutes / 60) + ":" + pad(minutes % 60)
      + (seconds % 60 > 0 ? ":" + pad(seconds % 60) : "")
  }
  private static func pad(_ value: Int) -> String { String(format: "%02d", value) }
  private static func calendar(_ zone: Zone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone =
      zone.offset.flatMap(TimeZone.init(secondsFromGMT:)) ?? TimeZone(identifier: zone.id)
      ?? TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }
  private static let utc = Zone(id: "UTC", label: "UTC", offset: 0)
  private static func parts(_ instant: Date, _ zone: Zone) -> [Int] {
    let values = calendar(zone).dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: instant)
    return [values.year!, values.month!, values.day!, values.hour!, values.minute!, values.second!]
  }
  private static func stamp(_ values: [Int]) -> Date {
    var components = DateComponents()
    components.year = values[0]
    components.month = values[1]
    components.day = values[2]
    components.hour = values.count > 3 ? values[3] : 0
    components.minute = values.count > 4 ? values[4] : 0
    components.second = values.count > 5 ? values[5] : 0
    return calendar(utc).date(from: components)!
  }
  private static func dateLabel(_ values: [Int]) -> String {
    String(format: "%04d-%02d-%02d", values[0], values[1], values[2])
  }
  private static func timeLabel(_ values: [Int]) -> String {
    pad(values[3]) + ":" + pad(values[4]) + (values[5] != 0 ? ":" + pad(values[5]) : "")
  }
  private static func parseDate(_ input: String) -> [Int]? {
    let values: [Int]
    if let match = regexGroups("^(\\d{4})-(\\d{2})-(\\d{2})$", input) {
      values = match.dropFirst().compactMap(Int.init)
    } else if let match = regexGroups("^(\\d{2})\\.(\\d{2})\\.(\\d{4})$", input) {
      values = match.dropFirst().reversed().compactMap(Int.init)
    } else {
      return nil
    }
    guard values.count == 3, (1900...9999).contains(values[0]), (1...12).contains(values[1]),
      (1...31).contains(values[2]), Array(parts(stamp(values), utc).prefix(3)) == values
    else { return nil }
    return values
  }
  private enum ZoneResolution {
    case zone(Zone)
    case error(String)
  }
  private static func resolve(_ input: String) -> ZoneResolution {
    let name = input.replacingOccurrences(of: "−", with: "-")
    let normalized = regexReplace("\\s+", name.lowercased(), " ")
    if let city = cities[normalized] { return .zone(city) }
    if let match = regexGroups(
      "^(?:utc|gmt)(?:([+-])(\\d{1,2})(?::?(\\d{2}))?(?::(\\d{2}))?)?$", name, insensitive: true)
    {
      let hours = Int(match[2]) ?? 0
      let minutes = Int(match[3]) ?? 0
      let seconds = Int(match[4]) ?? 0
      if hours > 14 || minutes > 59 || seconds > 59
        || (hours == 14 && (minutes != 0 || seconds != 0))
      {
        return .error("Укажите смещение от UTC−14:00 до UTC+14:00")
      }
      let offset = (match[1] == "-" ? -1 : 1) * (hours * 3600 + minutes * 60 + seconds)
      let label = offsetLabel(offset)
      return .zone(Zone(id: label, label: label, offset: offset))
    }
    if regexGroups("^[a-zа-я]{2,5}$", name, insensitive: true) != nil {
      return .error(
        "Неоднозначный или неизвестный часовой пояс «\(name)». Укажите город, например London, Europe/London или UTC+01:00."
      )
    }
    if name.contains("/"), let zone = TimeZone(identifier: name) {
      return .zone(Zone(id: zone.identifier, label: name, offset: nil))
    }
    return .error("Неизвестный часовой пояс «\(name)». Укажите город, IANA-пояс или UTC±HH:MM.")
  }
  private static func instants(_ wall: [Int], _ zone: Zone) -> [Date] {
    let wanted = stamp(wall)
    if let offset = zone.offset { return [wanted.addingTimeInterval(Double(-offset))] }
    var offsets = Set<Int>()
    for hour in stride(from: -48, through: 48, by: 6) {
      let instant = wanted.addingTimeInterval(Double(hour * 3600))
      offsets.insert(Int(stamp(parts(instant, zone)).timeIntervalSince(instant)))
    }
    return offsets.map { wanted.addingTimeInterval(Double(-$0)) }.filter { parts($0, zone) == wall }
      .sorted()
  }
  public static func convert(
    _ expression: String, context: CalculationContext = CalculationContext()
  ) -> Calculation? {
    let datePattern = "(?:\\d{4}-\\d{2}-\\d{2}|\\d{2}\\.\\d{2}\\.\\d{4})"
    guard
      let match = regexGroups(
        "^(?:(" + datePattern + ")\\s+)?(\\d{1,2}):(\\d{2})\\s+(.+?)\\s+(?:in|to|в)(?:\\s+|$)(.*)$",
        expression, insensitive: true)
    else { return nil }
    func error(_ message: String) -> Calculation {
      Calculation(status: .error, expression: expression, message: message)
    }
    func incomplete(_ message: String) -> Calculation {
      Calculation(status: .incomplete, expression: expression, message: message)
    }
    guard expression.count <= 512 else { return error("Слишком длинное выражение") }
    let prefixDate = match[1]
    let rawSource = match[4]
    let rawDestination = match[5]
    guard !rawDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return incomplete("Укажите часовой пояс результата, например: 18:00 Moscow in London")
    }
    let suffixPattern = "\\s+(?:(?:on|на)\\s+)?(" + datePattern + ")$"
    let suffix = regexGroups(suffixPattern, rawDestination, insensitive: true)
    let destination = regexReplace(suffixPattern, rawDestination, "", insensitive: true)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !prefixDate.isEmpty && suffix != nil {
      return error("Укажите дату один раз: перед временем или в конце запроса")
    }
    guard !destination.isEmpty else { return incomplete("Укажите часовой пояс результата") }
    let source: Zone
    let target: Zone
    switch resolve(rawSource.trimmingCharacters(in: .whitespacesAndNewlines)) {
    case .zone(let zone): source = zone
    case .error(let message): return error(message)
    }
    switch resolve(destination) {
    case .zone(let zone): target = zone
    case .error(let message): return error(message)
    }
    let hour = Int(match[2])!
    let minute = Int(match[3])!
    guard hour <= 23 && minute <= 59 else { return error("Укажите время от 00:00 до 23:59") }
    let explicitDate = !prefixDate.isEmpty ? prefixDate : suffix?[1]
    let requestedDate = explicitDate ?? context.sourceDate
    let date: [Int]
    if let requestedDate {
      guard let parsed = parseDate(requestedDate) else {
        return error("Укажите существующую дату с 1900 по 9999 год: YYYY-MM-DD или DD.MM.YYYY")
      }
      date = parsed
    } else {
      guard context.now.timeIntervalSince1970.isFinite else {
        return error("Не удалось определить сегодняшнюю дату")
      }
      date = Array(parts(context.now, source).prefix(3))
      guard (1900...9999).contains(date[0]) else {
        return error("Дата вне поддерживаемого диапазона: 1900–9999")
      }
    }
    let wall = date + [hour, minute, 0]
    let matches = instants(date + [hour, minute, 0], source)
    guard !matches.isEmpty else {
      return error("Такого местного времени нет из-за перевода часов. Выберите другое время.")
    }
    if matches.count > 1 {
      let offsets = matches.map { offsetLabel(Int(stamp(wall).timeIntervalSince($0))) }.joined(
        separator: " или ")
      return error(
        "Это местное время встречается дважды из-за перевода часов. Вместо \(source.label) укажите \(offsets)."
      )
    }
    let instant = matches[0]
    let converted = parts(matches[0], target)
    guard (1900...9999).contains(converted[0]) else {
      return error("Дата результата вне поддерживаемого диапазона: 1900–9999")
    }
    let days = Int(
      (stamp(Array(converted.prefix(3))).timeIntervalSince(stamp(date)) / 86400).rounded())
    let dayOffset = days == 0 ? " · тот же день" : " · \(days > 0 ? "+" : "−")\(abs(days)) дн."
    let sourceDate = dateLabel(date)
    let targetOffset = target.offset ?? Int(stamp(converted).timeIntervalSince(instant))
    return Calculation(
      status: .result, expression: expression,
      value: timeLabel(converted) + " · " + dateLabel(converted) + " · " + target.label + " ("
        + offsetLabel(targetOffset) + ")",
      conversion: "time-zone",
      interpretation: sourceDate + (explicitDate == nil ? " (сегодня в исходном поясе)" : "")
        + " · " + pad(hour) + ":" + pad(minute) + " " + source.label + " → " + dateLabel(converted)
        + " " + target.label + " (" + offsetLabel(targetOffset) + ")" + dayOffset,
      displayValue: timeLabel(converted) + " " + target.label, sourceDate: sourceDate)
  }
}
