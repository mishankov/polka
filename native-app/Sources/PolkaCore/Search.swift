import Foundation

public struct NativeLauncherApp: Equatable, Codable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case mac, builtin }
  public var id: String
  public var name: String
  public var kind: Kind
  public var icon: String
  public var description: String
  public var searchTerms: [String]
  public var bundleIdentifier: String?
  public init(
    id: String, name: String, kind: Kind = .mac, icon: String = "", description: String = "",
    searchTerms: [String] = [], bundleIdentifier: String? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.icon = icon
    self.description = description
    self.searchTerms = searchTerms
    self.bundleIdentifier = bundleIdentifier
  }
}
public struct LauncherUsage: Equatable, Codable, Sendable {
  private static let recentWindow: Double = 7 * 24 * 60 * 60 * 1000
  public var count: Int
  public var lastLaunchedAt: Double
  private var recentLaunches: [Double]?

  public init(count: Int = 0, lastLaunchedAt: Double = 0) {
    self.count = count
    self.lastLaunchedAt = lastLaunchedAt
  }

  // All timestamps in the saved launcher statistics are Unix milliseconds.
  public mutating func recordLaunch(at date: Date) {
    let timestamp = date.timeIntervalSince1970 * 1000
    let cutoff = timestamp - Self.recentWindow
    // Keep already recorded launches if the system clock moved backward.
    recentLaunches = recordedLaunches.filter { $0 >= cutoff } + [timestamp]
    lastLaunchedAt = count > 0 ? max(lastLaunchedAt, timestamp) : timestamp
    count += 1
  }

  fileprivate func recentScore(at timestamp: Double) -> (Int, Double) {
    let cutoff = timestamp - Self.recentWindow
    let recent = recordedLaunches.filter { $0 >= cutoff && $0 <= timestamp }
    return (recent.count, recent.max() ?? 0)
  }

  private var recordedLaunches: [Double] {
    // Older profiles only know the time of their last launch.
    recentLaunches ?? (count > 0 ? [lastLaunchedAt] : [])
  }
}
public enum LauncherSearch {
  public static var builtinApps: [NativeLauncherApp] {
    [
      NativeLauncherApp(
        id: "builtin:screenshots", name: localized("Screenshots"), kind: .builtin,
        icon: "screenshots", description: localized("Capture, mark up, and share"),
        searchTerms: ["screenshot", "capture", "screen", "скриншот", "снимок", "экран"]),
      NativeLauncherApp(
        id: "builtin:system-status", name: localized("System Status"), kind: .builtin,
        icon: "system-status",
        description: localized("Battery, memory, storage, and network at a glance"),
        searchTerms: [
          "System Status", "Состояние системы", "system", "resources", "система", "ресурсы",
          "battery", "power", "батарея", "аккумулятор", "заряд", "memory", "RAM", "память", "ОЗУ",
          "storage", "disk", "space", "диск", "место", "хранилище", "network", "Wi-Fi", "Ethernet",
          "VPN", "сеть", "интернет",
        ]),
      NativeLauncherApp(
        id: "builtin:snippets", name: localized("Snippets"), kind: .builtin, icon: "snippets",
        description: localized("Addresses, details, and ready-made replies — create and paste"),
        searchTerms: [
          "Snippets", "Сниппеты", "snippet", "snippets", "сниппет", "шаблоны", "готовые ответы",
        ]),
      NativeLauncherApp(
        id: "builtin:files", name: localized("Files on the Shelf"), kind: .builtin, icon: "files",
        description: localized("Temporarily keep files and drag them to another app"),
        searchTerms: [
          "Files on the Shelf", "Файлы на полке", "files", "shelf", "файлы", "перетащить",
        ]),
      NativeLauncherApp(
        id: "builtin:clipboard", name: localized("Clipboard History"), kind: .builtin,
        icon: "clipboard",
        description: localized("Copied text and images"),
        searchTerms: [
          "Clipboard History", "История буфера обмена", "clipboard", "history", "буфер",
          "копировать",
        ]),
      NativeLauncherApp(
        id: "builtin:emoji", name: localized("Emoji"), kind: .builtin, icon: "emoji",
        description: localized("Smileys, gestures, and symbols — find and paste"),
        searchTerms: ["Emoji", "Эмодзи", "emoji", "emojis", "эмоджи", "смайлик", "смайлики"]),
    ]
  }
  private struct Field {
    let text: String
    let length: Int
    let words: [String]
    let wordCharacters: [[Character]]
    let initials: String
  }
  private struct Term {
    let text: String
    let characters: [Character]
    let letters: Bool
    let alphanumeric: Bool
    var length: Int { characters.count }
    init(_ text: String) {
      self.text = text
      characters = Array(text)
      letters = regexGroups("^[\\p{L}]+$", text) != nil
      alphanumeric = characters.allSatisfy { $0.isLetter || $0.isNumber }
    }
  }
  private struct Query {
    let text: String
    let length: Int
    let terms: [Term]
    init(_ text: String) {
      self.text = text
      length = text.count
      terms = text.split(separator: " ").map { Term(String($0)) }
    }
  }
  private final class CachedFields {
    let names: [Field]
    let metadata: String
    init(_ app: NativeLauncherApp) {
      names = ([app.name] + app.searchTerms).map { name -> Field in
        let words = regexReplace(
          "[^\\p{L}\\p{N}]+", normalize(regexReplace("([\\p{Ll}\\d])(\\p{Lu})", name, "$1 $2")), " "
        ).split(separator: " ").map(String.init)
        let text = normalize(name)
        return Field(
          text: text, length: text.count, words: words, wordCharacters: words.map(Array.init),
          initials: words.count > 1 ? words.compactMap(\.first).map(String.init).joined() : "")
      }
      metadata = normalize([app.description, app.bundleIdentifier ?? ""].joined(separator: " "))
    }
  }
  // NSCache is thread safe and bounded; typing successive characters does not repeatedly
  // tokenize the full installed-app catalog. Content keys invalidate changed app metadata.
  private static let fieldCache: NSCache<NSString, CachedFields> = {
    let cache = NSCache<NSString, CachedFields>()
    cache.countLimit = 4096
    return cache
  }()
  private static func fields(_ app: NativeLauncherApp) -> CachedFields {
    let key =
      ([app.name, app.description, app.bundleIdentifier ?? ""] + app.searchTerms)
      .joined(separator: "\u{0}") as NSString
    if let value = fieldCache.object(forKey: key) { return value }
    let value = CachedFields(app)
    fieldCache.setObject(value, forKey: key)
    return value
  }
  private struct Match: Comparable {
    let tier: Int
    let distance: Int
    let corrected: Int
    var isDirect: Bool { tier <= 3 }
    // Rank names in the typed layout before trying the corrected layout.
    var rankingTier: Int { isDirect ? corrected : tier }
    static func < (a: Match, b: Match) -> Bool {
      (a.rankingTier, a.tier, a.distance, a.corrected)
        < (b.rankingTier, b.tier, b.distance, b.corrected)
    }
  }
  private static func normalize(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(
      of: "ё", with: "е")
  }
  private static let latin = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,.~{}:\"<>")
  private static let russian = Array("ёйцукенгшщзхъфывапролджэячсмитьбюёхъжэбю")
  private static func layout(_ input: String, from: [Character], to: [Character]) -> String {
    String(input.map { char in from.firstIndex(of: char).map { to[$0] } ?? char })
  }
  public static func apps(
    _ apps: [NativeLauncherApp], query: String, usage: [String: LauncherUsage] = [:],
    now: Date = Date()
  ) -> [NativeLauncherApp] {
    let input = regexReplace(
      "\\s+", query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), " ")
    var variants = [normalize(input)]
    if regexGroups("[а-яё]", input) != nil {
      variants.append(normalize(layout(input, from: russian, to: latin)))
    }
    if regexGroups("[a-z]", input) != nil {
      variants.append(normalize(layout(input, from: latin, to: russian)))
    }
    var seen = Set<String>()
    variants = variants.filter { seen.insert($0).inserted }
    let queries = variants.map(Query.init)
    let timestamp = now.timeIntervalSince1970 * 1000
    let matches: [(app: NativeLauncherApp, match: Match, recent: (Int, Double))] = apps.compactMap {
      app in
      if input.isEmpty { return (app, Match(tier: 0, distance: 0, corrected: 0), (0, 0)) }
      let fields = fields(app)
      let candidates = queries.enumerated().compactMap { index, query in
        match(fields.names, metadata: fields.metadata, query: query, corrected: index > 0 ? 1 : 0)
      }
      guard let best = candidates.min() else { return nil }
      let recent = best.isDirect ? usage[app.id]?.recentScore(at: timestamp) : nil
      return (app, best, recent ?? (0, 0))
    }
    return matches.sorted { a, b in
      if input.isEmpty && a.app.kind != b.app.kind { return a.app.kind == .builtin }
      if a.match.rankingTier != b.match.rankingTier {
        return a.match.rankingTier < b.match.rankingTier
      }
      if a.recent != b.recent { return a.recent > b.recent }
      if a.match != b.match { return a.match < b.match }
      let au = usage[a.app.id] ?? LauncherUsage()
      let bu = usage[b.app.id] ?? LauncherUsage()
      if au.count != bu.count { return au.count > bu.count }
      if au.lastLaunchedAt != bu.lastLaunchedAt { return au.lastLaunchedAt > bu.lastLaunchedAt }
      let order = a.app.name.compare(b.app.name, options: [], locale: Locale(identifier: "ru"))
      return order == .orderedSame ? a.app.id < b.app.id : order == .orderedAscending
    }.map(\.app)
  }
  private static func match(_ names: [Field], metadata: String, query: Query, corrected: Int)
    -> Match?
  {
    if names.contains(where: { $0.length == query.length && $0.text == query.text }) {
      return Match(tier: 0, distance: 0, corrected: corrected)
    }
    if names.contains(where: { $0.length >= query.length && $0.text.hasPrefix(query.text) }) {
      return Match(tier: 1, distance: 0, corrected: corrected)
    }
    let terms = query.terms
    var tier = 0
    var distance = 0
    for term in terms {
      if names.contains(where: { field in
        field.words.enumerated().contains(where: {
          field.wordCharacters[$0.offset].count >= term.length && $0.element.hasPrefix(term.text)
        })
      }) {
        tier = max(tier, 2)
      } else if names.contains(where: { $0.length >= term.length && $0.text.contains(term.text) }) {
        tier = max(tier, 3)
      } else if metadata.count >= term.length && metadata.contains(term.text) {
        tier = max(tier, 4)
      } else if term.length >= 2
        && names.contains(where: {
          $0.initials.count >= term.length && $0.initials.hasPrefix(term.text)
        })
      {
        tier = max(tier, 5)
      } else if terms.count <= 16, let typo = prefixTypoDistance(term, in: names) {
        tier = 6
        distance += typo
      } else if terms.count == 1, (3...64).contains(term.length), term.alphanumeric,
        let displayName = names.first,
        matchesScattered(term.characters, in: displayName.wordCharacters)
      {
        tier = 7
      } else {
        return nil
      }
    }
    return Match(tier: tier, distance: distance, corrected: corrected)
  }
  private static func matchesScattered(_ query: [Character], in words: [[Character]]) -> Bool {
    var matched = 0
    for word in words {
      // Starting at a word boundary keeps unrelated names such as Terminal
      // out of the results for common transposed queries such as "mial".
      if matched == 0 && word.first != query[0] { continue }
      for letter in word where letter == query[matched] {
        matched += 1
        if matched == query.count { return true }
      }
    }
    return false
  }
  private static func prefixTypoDistance(_ term: Term, in names: [Field]) -> Int? {
    guard (3...64).contains(term.length), term.letters else { return nil }
    let limit = term.length < 6 ? 1 : 2
    var best = limit + 1
    for field in names {
      for word in field.wordCharacters {
        let first = max(3, term.length - limit)
        let last = min(word.count, term.length + limit)
        if first <= last {
          for length in first...last {
            best = min(
              best, typoDistance(term.characters, Array(word.prefix(length)), limit: limit))
            if best == 0 { break }
          }
        }
      }
    }
    return best <= limit ? best : nil
  }
  private static func typoDistance(_ query: [Character], _ word: [Character], limit: Int) -> Int {
    guard abs(query.count - word.count) <= limit else { return limit + 1 }
    var previous = Array(0...word.count)
    var beforePrevious = previous
    for i in 1...query.count {
      var row = Array(repeating: limit + 1, count: word.count + 1)
      row[0] = i
      var minimum = i
      let first = max(1, i - limit)
      let last = min(word.count, i + limit)
      if first <= last {
        for j in first...last {
          row[j] = min(
            row[j - 1] + 1, previous[j] + 1, previous[j - 1] + (query[i - 1] == word[j - 1] ? 0 : 1)
          )
          if i > 1 && j > 1 && query[i - 1] == word[j - 2] && query[i - 2] == word[j - 1] {
            row[j] = min(row[j], beforePrevious[j - 2] + 1)
          }
          minimum = min(minimum, row[j])
        }
      }
      if minimum > limit { return limit + 1 }
      beforePrevious = previous
      previous = row
    }
    return previous[word.count]
  }
}
