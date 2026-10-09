import Foundation

public struct NativeEmoji: Equatable, Sendable, Identifiable {
  public let id: String
  public let value: String
  public let category: String
  public let name: String
  public let englishName: String
  public let keywords: String
  public let tones: [String]
}
public struct EmojiCategory: Equatable, Sendable, Identifiable {
  public let id: String
  public let label: String
  public let symbol: String
}
public struct EmojiTone: Equatable, Sendable, Identifiable {
  public let value: String
  public let label: String
  public var id: String { value }
}
public struct EmojiCatalog: Sendable {
  public static let categories: [EmojiCategory] = [
    EmojiCategory(id: "all", label: "Все эмодзи", symbol: "⌘"),
    EmojiCategory(id: "Smileys & Emotion", label: "Смайлы и эмоции", symbol: "😀"),
    EmojiCategory(id: "People & Body", label: "Люди и жесты", symbol: "👋"),
    EmojiCategory(id: "Animals & Nature", label: "Животные и природа", symbol: "🌿"),
    EmojiCategory(id: "Food & Drink", label: "Еда и напитки", symbol: "🍋"),
    EmojiCategory(id: "Travel & Places", label: "Места и транспорт", symbol: "🚀"),
    EmojiCategory(id: "Activities", label: "Занятия", symbol: "⚽"),
    EmojiCategory(id: "Objects", label: "Предметы", symbol: "💡"),
    EmojiCategory(id: "Symbols", label: "Символы", symbol: "❤️"),
    EmojiCategory(id: "Flags", label: "Флаги", symbol: "🏳️"),
  ]
  public static let tones: [EmojiTone] = [
    EmojiTone(value: "default", label: "✋ Стандартный"),
    EmojiTone(value: "🏻", label: "Очень светлый"), EmojiTone(value: "🏼", label: "Светлый"),
    EmojiTone(value: "🏽", label: "Средний"), EmojiTone(value: "🏾", label: "Тёмный"),
    EmojiTone(value: "🏿", label: "Очень тёмный"), EmojiTone(value: "all", label: "Все оттенки"),
  ]
  private static let aliases = [
    "😀": "смайл смайлик улыбка smile happy", "😂": "лол ржу смех lol laughing",
    "🤣": "лол ржу смех lol rofl",
    "👍": "лайк класс супер отлично like yes good", "👎": "дизлайк dislike no bad",
    "🙏": "спасибо пожалуйста благодарю thank thanks please",
    "❤️": "красное сердце любовь люблю love heart",
    "🎉": "ура праздник поздравляю party congratulations", "🔥": "огонь круто fire lit",
    "😢": "грустно грусть sad crying", "😭": "грустно грусть sad crying",
  ]
  static func packagedResourceURL(in resources: URL?) -> URL? {
    guard let resources,
      let bundle = Bundle(url: resources.appendingPathComponent("PolkaNative_PolkaCore.bundle"))
    else { return nil }
    return bundle.url(forResource: "emoji-data", withExtension: "json")
  }
  public static let shared: EmojiCatalog = {
    guard
      let url = packagedResourceURL(in: Bundle.main.resourceURL)
        ?? Bundle.module.url(forResource: "emoji-data", withExtension: "json"),
      let data = try? Data(contentsOf: url), let catalog = try? EmojiCatalog(data: data)
    else {
      fatalError("The complete bundled emoji-data.json resource is missing or invalid")
    }
    return catalog
  }()
  public let emojis: [NativeEmoji]
  private let index: [String: NativeEmoji]
  public enum CatalogError: Error { case invalidData }
  public init(data: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let groups = object["groups"] as? [String], let rows = object["entries"] as? [[Any]]
    else { throw CatalogError.invalidData }
    var emojis: [NativeEmoji] = []
    for row in rows {
      guard row.count == 6, let value = row[0] as? String, let group = row[1] as? Int,
        groups.indices.contains(group),
        let name = row[2] as? String, let englishName = row[3] as? String,
        let russianKeywords = row[4] as? String, let englishKeywords = row[5] as? String
      else { throw CatalogError.invalidData }
      let tones = value.unicodeScalars.filter { (0x1f3fb...0x1f3ff).contains($0.value) }.map(
        String.init)
      let id = value.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
      let keywords = Self.normalize(
        "\(name) \(englishName) \(russianKeywords) \(englishKeywords) \(Self.aliases[Self.withoutTones(value)] ?? "")"
      )
      emojis.append(
        NativeEmoji(
          id: id, value: value, category: groups[group], name: name, englishName: englishName,
          keywords: keywords, tones: tones))
    }
    guard Set(emojis.map(\.id)).count == emojis.count else { throw CatalogError.invalidData }
    self.emojis = emojis
    self.index = Dictionary(uniqueKeysWithValues: emojis.map { ($0.id, $0) })
  }
  public static func normalize(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased(with: Locale(identifier: "ru"))
      .replacingOccurrences(of: "ё", with: "е").trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private static func withoutTones(_ value: String) -> String {
    String(
      String.UnicodeScalarView(
        value.unicodeScalars.filter { !(0x1f3fb...0x1f3ff).contains($0.value) }))
  }
  public func byID(_ id: String) -> NativeEmoji? { index[id] }
  public func results(query: String, category: String = "all", tone: String = "default")
    -> [NativeEmoji]
  {
    let normalized = Self.normalize(query)
    let terms = Self.normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
    let exact = emojis.first { $0.value == query.trimmingCharacters(in: .whitespacesAndNewlines) }
    let matches = emojis.enumerated().filter { _, emoji in
      guard category == "all" || emoji.category == category else { return false }
      if exact == nil && tone != "all"
        && (tone == "default" ? !emoji.tones.isEmpty : emoji.tones.contains(where: { $0 != tone }))
      {
        return false
      }
      return terms.allSatisfy { emoji.keywords.contains($0) || emoji.value.contains($0) }
    }
    guard !normalized.isEmpty else { return matches.map { $0.element } }
    func score(_ emoji: NativeEmoji) -> Int {
      if emoji.id == exact?.id { return 0 }
      let names = [Self.normalize(emoji.name), Self.normalize(emoji.englishName)]
      if names.contains(normalized) { return 1 }
      if names.contains(where: { $0.hasPrefix(normalized) })
        || Self.normalize(Self.aliases[Self.withoutTones(emoji.value)] ?? "").contains(normalized)
      {
        return 2
      }
      return 3
    }
    return matches.sorted { a, b in
      let sa = score(a.element)
      let sb = score(b.element)
      return sa == sb ? a.offset < b.offset : sa < sb
    }.map { $0.element }
  }
  public static func gridIndex(index: Int, key: String, count: Int, columns: Int) -> Int {
    if key == "Home" { return 0 }
    if key == "End" { return max(0, count - 1) }
    let delta =
      ["ArrowRight": 1, "ArrowLeft": -1, "ArrowDown": columns, "ArrowUp": -columns][key] ?? 0
    return max(0, min(count - 1, index + delta))
  }
}
