import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
  case english = "en"
  case russian = "ru"

  public var locale: Locale { Locale(identifier: rawValue) }
}

public enum AppLanguagePreference: String, CaseIterable, Sendable {
  case system
  case english = "en"
  case russian = "ru"

  public static let settingsKey = "appLanguage"

  /// Follow the primary macOS language, rather than its region or keyboard layout.
  /// Unsupported system languages fall back to English.
  public func resolve(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
    switch self {
    case .english: return .english
    case .russian: return .russian
    case .system:
      let primary = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-")
        .split(separator: "-").first?.lowercased()
      return primary == "ru" ? .russian : .english
    }
  }
}

/// Shared by AppKit, SwiftUI, and user-facing errors in the core services.
/// English source text is also the fallback for a missing translation.
public enum AppLocalization {
  private static let lock = NSLock()
  private static var selected = AppLanguagePreference.system.resolve()
  private static let argumentPattern = try? NSRegularExpression(pattern: "\\{([0-9]+)\\}")
  private static let bundles: [AppLanguage: Bundle] = Dictionary(
    uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
      Bundle.module.url(forResource: language.rawValue, withExtension: "lproj")
        .flatMap(Bundle.init(url:)).map { (language, $0) }
    })

  public static var language: AppLanguage {
    lock.lock()
    defer { lock.unlock() }
    return selected
  }

  public static func configure(
    _ preference: AppLanguagePreference, preferredLanguages: [String] = Locale.preferredLanguages
  ) {
    lock.lock()
    defer { lock.unlock() }
    selected = preference.resolve(preferredLanguages: preferredLanguages)
  }

  public static func text(_ key: String, language: AppLanguage) -> String {
    bundles[language]?.localizedString(forKey: key, value: key, table: nil) ?? key
  }

  public static func text(_ key: String, arguments: [String], language: AppLanguage) -> String {
    let template = text(key, language: language)
    // Replace in a single pass so user data containing "{1}" is never interpreted
    // as another argument. Translations may reorder the numbered placeholders.
    guard !arguments.isEmpty, let pattern = argumentPattern else { return template }
    let matches = pattern.matches(
      in: template, range: NSRange(template.startIndex..., in: template))
    var result = template
    for match in matches.reversed() {
      guard let numberRange = Range(match.range(at: 1), in: template),
        let index = Int(template[numberRange]), arguments.indices.contains(index),
        let range = Range(match.range, in: result)
      else { continue }
      result.replaceSubrange(range, with: arguments[index])
    }
    return result
  }
}

public func localized(_ key: String, _ arguments: String...) -> String {
  AppLocalization.text(key, arguments: arguments, language: AppLocalization.language)
}
