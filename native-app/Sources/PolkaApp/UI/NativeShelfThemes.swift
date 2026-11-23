import Foundation
import PolkaCore

struct NativeThemeColors: Codable, Equatable, Sendable {
  var background: String
  var surface: String
  var text: String
  var accent: String
  var selection: String
  var detailAccent: String? = nil

  static func normalizedHex(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = trimmed.hasPrefix("#") ? trimmed.dropFirst() : trimmed[...]
    guard digits.utf8.count == 6,
      digits.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { return nil }
    return "#" + digits.uppercased()
  }

  var normalized: Self? {
    guard let background = Self.normalizedHex(background),
      let surface = Self.normalizedHex(surface),
      let text = Self.normalizedHex(text), let accent = Self.normalizedHex(accent),
      let selection = Self.normalizedHex(selection)
    else { return nil }
    let detail = detailAccent.flatMap(Self.normalizedHex)
    guard detailAccent == nil || detail != nil else { return nil }
    return Self(
      background: background, surface: surface, text: text, accent: accent, selection: selection,
      detailAccent: detail)
  }

  var isValid: Bool { normalized != nil }
}

struct NativeShelfTheme: Identifiable, Codable, Equatable, Sendable {
  let id: String
  var name: String
  var colors: NativeThemeColors
}

enum NativeThemeCategory: String, CaseIterable {
  case neutral, vibrant, pastel, popular

  var themes: [NativeShelfTheme] {
    switch self {
    case .neutral: Self.neutralThemes
    case .vibrant: Self.vibrantThemes
    case .pastel: Self.pastelThemes
    case .popular: Self.popularThemes
    }
  }

  private static func preset(
    _ id: String, _ name: String, _ background: String, _ surface: String, _ text: String,
    _ accent: String, _ selection: String, detailAccent: String? = nil
  ) -> NativeShelfTheme {
    NativeShelfTheme(
      id: id, name: name,
      colors: NativeThemeColors(
        background: background, surface: surface, text: text, accent: accent, selection: selection,
        detailAccent: detailAccent))
  }

  static let polka = preset("polka", "Polka", "#080808", "#212123", "#F6F6F7", "#419FFF", "#132B44")

  private static let neutralThemes = [
    polka,
    preset("graphite", "Graphite", "#28292B", "#36383B", "#F1F1F0", "#AAB9CE", "#424752"),
    preset("paper", "Paper", "#F4EEE2", "#FFF9ED", "#29251D", "#826447", "#E6D7BE"),
    preset("slate", "Slate", "#293641", "#364654", "#EAFBFF", "#91BED6", "#435964"),
    preset("ink", "Ink", "#121820", "#1B2530", "#F5F5F4", "#93A2B7", "#2C3E4F"),
    preset("porcelain", "Porcelain", "#EDF2F4", "#FFFFFF", "#192C33", "#4B6974", "#CDDCE1"),
    preset("espresso", "Espresso", "#312723", "#4A3931", "#FFF0E6", "#C7A48D", "#5D4134"),
    preset("linen", "Linen", "#ECE5D9", "#FBF4E7", "#372F29", "#776350", "#DCD0C0"),
  ]
  private static let vibrantThemes = [
    preset("midnight", "Midnight", "#21174B", "#30245E", "#FBF5FF", "#B8A3FF", "#654CCC"),
    preset("electric", "Electric", "#163CB5", "#0D277E", "#F2F6FF", "#91E7FF", "#B2DDFF"),
    preset("sunset", "Sunset", "#60213C", "#773049", "#FFF0E8", "#FFC179", "#FFD18B"),
    preset("lagoon", "Lagoon", "#063F47", "#0D5357", "#E6FFFA", "#7CFBE2", "#1A726E"),
    preset("bloom", "Bloom", "#6F1645", "#871A54", "#FFF0F9", "#FF9DCB", "#FFC0DE"),
    preset("ultraviolet", "Ultraviolet", "#40218D", "#502DB0", "#FAF0FF", "#FFB9EB", "#E1BDFF"),
    preset("saffron", "Saffron", "#FFE15A", "#FFF19B", "#302612", "#795423", "#FFC15B"),
    preset("flare", "Flare", "#822923", "#661A1C", "#FFF1E9", "#FFC095", "#FFAE80"),
  ]
  private static let pastelThemes = [
    preset("lilac-mist", "Lilac Mist", "#E9DEF8", "#F7EFFF", "#352845", "#7556A3", "#D7C0EF"),
    preset("mint", "Mint", "#D7EEE3", "#EDFAF1", "#19392B", "#3A7959", "#B1DFC7"),
    preset("peach", "Peach", "#F8E1D6", "#FFF0E5", "#4D2B25", "#A35243", "#F5BDA8"),
    preset("haze", "Haze", "#DEEDF7", "#F0F9FF", "#26394F", "#456E93", "#BFD9EE"),
    preset("rosewater", "Rosewater", "#F4DFE8", "#FFF2F6", "#4C2B3B", "#9B5271", "#EBC0D4"),
    preset("buttercup", "Buttercup", "#F8ECBE", "#FFF8DC", "#443516", "#806A30", "#EBD593"),
    preset("sea-glass", "Sea Glass", "#D9EEED", "#F2FAF9", "#253C3C", "#447877", "#B9DEDB"),
    preset("dusk", "Dusk", "#413A56", "#524967", "#F4EBFF", "#D4B9F1", "#6A557D"),
  ]
  // Assign each source palette's colors to the shelf, search, selection and details.
  private static let popularThemes = [
    // https://github.com/dracula/visual-studio-code/blob/main/src/dracula.yml
    preset(
      "dracula", "Dracula", "#282A36", "#21222C", "#F8F8F2", "#BD93F9", "#FF79C6",
      detailAccent: "#8BE9FD"),
    // https://www.nordtheme.com/docs/colors-and-palettes/
    preset(
      "nord", "Nord", "#2E3440", "#3B4252", "#ECEFF4", "#88C0D0", "#434C5E",
      detailAccent: "#A3BE8C"),
    // https://github.com/ayu-theme/ayu-colors
    preset(
      "ayu-mirage", "Ayu Mirage", "#1F2430", "#2D3342", "#CCCAC2", "#FFCC66", "#65462F",
      detailAccent: "#BAE67E"),
    // https://github.com/catppuccin/palette/blob/main/palette.json
    preset(
      "catppuccin-mocha", "Catppuccin Mocha", "#1E1E2E", "#313244", "#CDD6F4", "#F5C2E7", "#684E77",
      detailAccent: "#94E2D5"),
    // https://github.com/tokyo-night/tokyo-night-vscode-theme/blob/master/themes/tokyo-night-color-theme.json
    preset(
      "tokyo-night", "Tokyo Night", "#1A1B26", "#202A42", "#C0CAF5", "#7AA2F7", "#3454AA",
      detailAccent: "#7DCFFF"),
    // https://github.com/morhetz/gruvbox/blob/master/colors/gruvbox.vim
    preset(
      "gruvbox-dark", "Gruvbox Dark", "#282828", "#3C3836", "#EBDBB2", "#FE8019", "#D79921",
      detailAccent: "#B8BB26"),
    // https://github.com/rose-pine/palette/blob/main/palette.json
    preset(
      "rose-pine-dawn", "Rosé Pine Dawn", "#FAF4ED", "#FFF8F6", "#464261", "#B4637A", "#EAD8D7",
      detailAccent: "#286983"),
    // https://github.com/altercation/solarized#the-values
    preset(
      "solarized-light", "Solarized Light", "#FDF6E3", "#EEE8D5", "#073642", "#2071A8", "#073642",
      detailAccent: "#16746D"),
  ]
}

struct NativeThemeSettings: Codable, Equatable, Sendable {
  static let settingsKey = "shelfThemes"
  static let standard = NativeThemeCategory.polka
  static let maxNameLength = 35
  static let builtIns = NativeThemeCategory.allCases.flatMap(\.themes)

  var activeID = standard.id
  var custom: [NativeShelfTheme] = []
  var active: NativeShelfTheme { theme(id: activeID) ?? Self.standard }

  func theme(id: String) -> NativeShelfTheme? {
    Self.builtIns.first { $0.id == id } ?? custom.first { $0.id == id }
  }

  func containsName(_ name: String, excluding id: String = "") -> Bool {
    (Self.builtIns + custom).contains {
      $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
    }
  }

  func canUseName(_ name: String, editingCustomTheme id: String) -> Bool {
    // New presets can share a name with an existing custom theme.
    if let theme = custom.first(where: { $0.id == id }),
      theme.name.caseInsensitiveCompare(name) == .orderedSame
    {
      return true
    }
    return !containsName(name, excluding: id)
  }

  func copyName(for source: NativeShelfTheme) -> String {
    var number = 1
    while true {
      let format = number == 1 ? "{0} Copy" : "{0} Copy {1}"
      let suffix = localized(format, "", String(number))
      let base = String(source.name.prefix(max(0, Self.maxNameLength - suffix.count)))
      let candidate = localized(format, base, String(number))
      if !containsName(candidate) { return candidate }
      number += 1
    }
  }

  static func load(_ value: Any?) -> Self {
    guard let object = value as? [String: Any] else { return Self() }
    let entries = object["custom"] as? [Any] ?? []
    let decoder = JSONDecoder()
    var ids = Set(builtIns.map(\.id))
    let custom = entries.compactMap { entry -> NativeShelfTheme? in
      guard let record = entry as? [String: Any],
        let data = try? JSONSerialization.data(withJSONObject: record),
        let theme = try? decoder.decode(NativeShelfTheme.self, from: data),
        !theme.id.isEmpty, let colors = theme.colors.normalized,
        !theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        theme.name.count <= maxNameLength, ids.insert(theme.id).inserted
      else { return nil }
      return NativeShelfTheme(id: theme.id, name: theme.name, colors: colors)
    }
    var settings = Self(activeID: object["activeID"] as? String ?? standard.id, custom: custom)
    settings.activeID = settings.active.id
    return settings
  }
}
