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
    add("Europe/Moscow", "Moscow", "moscow|москва|москве|msk|мск")
    add("Europe/London", "London", "london|лондон|лондоне")
    add("Europe/Paris", "Paris", "paris|париж|париже")
    add("Europe/Berlin", "Berlin", "berlin|берлин|берлине")
    add("Europe/Rome", "Rome", "rome|рим|риме")
    add("Europe/Madrid", "Madrid", "madrid|мадрид|мадриде")
    add("Europe/Helsinki", "Helsinki", "helsinki|хельсинки")
    add("Europe/Istanbul", "Istanbul", "istanbul|стамбул|стамбуле")
    add("Asia/Dubai", "Dubai", "dubai|дубай|дубае")
    add("Asia/Tbilisi", "Tbilisi", "tbilisi|тбилиси")
    add("Asia/Yerevan", "Yerevan", "yerevan|ереван|ереване")
    add("Asia/Yekaterinburg", "Yekaterinburg", "yekaterinburg|екатеринбург|екатеринбурге")
    add("Asia/Novosibirsk", "Novosibirsk", "novosibirsk|новосибирск|новосибирске")
    add("Asia/Vladivostok", "Vladivostok", "vladivostok|владивосток|владивостоке")
    add("America/New_York", "New York", "new york|new-york|nyc|нью-йорк|нью-йорке")
    add("America/Los_Angeles", "Los Angeles", "los angeles|los-angeles|лос-анджелес|лос-анджелесе")
    add("America/Chicago", "Chicago", "chicago|чикаго")
    add("America/Toronto", "Toronto", "toronto|торонто")
    add("America/Sao_Paulo", "São Paulo", "sao paulo|são paulo|сан-паулу")
    add("Asia/Tokyo", "Tokyo", "tokyo|токио")
    add("Asia/Shanghai", "Shanghai", "shanghai|шанхай|шанхае")
    add("Asia/Hong_Kong", "Hong Kong", "hong kong|гонконг|гонконге")
    add("Asia/Singapore", "Singapore", "singapore|сингапур|сингапуре")
    add("Asia/Kolkata", "Kolkata", "kolkata|калькутта|калькутте")
    add("Australia/Sydney", "Sydney", "sydney|сидней|сиднее")
    add("Pacific/Auckland", "Auckland", "auckland|окленд|окленде")
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
        return .error(localized("Enter an offset from UTC−14:00 to UTC+14:00"))
      }
      let offset = (match[1] == "-" ? -1 : 1) * (hours * 3600 + minutes * 60 + seconds)
      let label = offsetLabel(offset)
      return .zone(Zone(id: label, label: label, offset: offset))
    }
    if regexGroups("^[a-zа-я]{2,5}$", name, insensitive: true) != nil {
      return .error(
        localized(
          "Ambiguous or unknown time zone “{0}”. Enter a city, such as London, Europe/London, or UTC+01:00.",
          String(describing: name))
      )
    }
    if name.contains("/"), let zone = TimeZone(identifier: name) {
      return .zone(Zone(id: zone.identifier, label: name, offset: nil))
    }
    return .error(
      localized(
        "Unknown time zone “{0}”. Enter a city, an IANA time zone, or UTC±HH:MM.",
        String(describing: name)))
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
    guard expression.count <= 512 else { return error(localized("Expression is too long")) }
    let prefixDate = match[1]
    let rawSource = match[4]
    let rawDestination = match[5]
    guard !rawDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return incomplete(
        localized("Enter the result time zone, for example: 18:00 Moscow in London"))
    }
    let suffixPattern = "\\s+(?:(?:on|на)\\s+)?(" + datePattern + ")$"
    let suffix = regexGroups(suffixPattern, rawDestination, insensitive: true)
    let destination = regexReplace(suffixPattern, rawDestination, "", insensitive: true)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !prefixDate.isEmpty && suffix != nil {
      return error(localized("Enter the date once: before the time or at the end of the query"))
    }
    guard !destination.isEmpty else { return incomplete(localized("Enter the result time zone")) }
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
    guard hour <= 23 && minute <= 59 else {
      return error(localized("Enter a time from 00:00 to 23:59"))
    }
    let explicitDate = !prefixDate.isEmpty ? prefixDate : suffix?[1]
    let requestedDate = explicitDate ?? context.sourceDate
    let date: [Int]
    if let requestedDate {
      guard let parsed = parseDate(requestedDate) else {
        return error(localized("Enter a valid date from 1900 to 9999: YYYY-MM-DD or DD.MM.YYYY"))
      }
      date = parsed
    } else {
      guard context.now.timeIntervalSince1970.isFinite else {
        return error(localized("Could not determine today's date"))
      }
      date = Array(parts(context.now, source).prefix(3))
      guard (1900...9999).contains(date[0]) else {
        return error(localized("Date is outside the supported range: 1900–9999"))
      }
    }
    let wall = date + [hour, minute, 0]
    let matches = instants(date + [hour, minute, 0], source)
    guard !matches.isEmpty else {
      return error(
        localized("This local time does not exist because of a clock change. Choose another time."))
    }
    if matches.count > 1 {
      let offsets = matches.map { offsetLabel(Int(stamp(wall).timeIntervalSince($0))) }.joined(
        separator: localized(" or "))
      return error(
        localized(
          "This local time occurs twice because of a clock change. Use {1} instead of {0}.",
          localized(source.label), String(describing: offsets))
      )
    }
    let instant = matches[0]
    let converted = parts(matches[0], target)
    guard (1900...9999).contains(converted[0]) else {
      return error(localized("Result date is outside the supported range: 1900–9999"))
    }
    let days = Int(
      (stamp(Array(converted.prefix(3))).timeIntervalSince(stamp(date)) / 86400).rounded())
    let dayOffset =
      days == 0
      ? localized(" · same day")
      : localized(" · {0} days", (days > 0 ? "+" : "−") + String(abs(days)))
    let sourceDate = dateLabel(date)
    let targetOffset = target.offset ?? Int(stamp(converted).timeIntervalSince(instant))
    return Calculation(
      status: .result, expression: expression,
      value: timeLabel(converted) + " · " + dateLabel(converted) + " · " + localized(target.label)
        + " ("
        + offsetLabel(targetOffset) + ")",
      conversion: "time-zone",
      interpretation: sourceDate
        + (explicitDate == nil ? localized(" (today in the source time zone)") : "")
        + " · " + pad(hour) + ":" + pad(minute) + " " + localized(source.label) + " → "
        + dateLabel(converted)
        + " " + localized(target.label) + " (" + offsetLabel(targetOffset) + ")" + dayOffset,
      displayValue: timeLabel(converted) + " " + localized(target.label), sourceDate: sourceDate)
  }
}
