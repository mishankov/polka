import XCTest

@testable import PolkaCore

final class LocalizationTests: XCTestCase {
  func testSystemDetectionUsesPrimaryLanguageAndFallsBackToEnglish() {
    for languages in [["ru"], ["ru-RU", "en-US"], ["RU_ru"]] {
      XCTAssertEqual(AppLanguagePreference.system.resolve(preferredLanguages: languages), .russian)
    }
    for languages in [[], ["en-GB"], ["de-DE", "ru-RU"], ["fr"], ["russian"]] {
      XCTAssertEqual(AppLanguagePreference.system.resolve(preferredLanguages: languages), .english)
    }
    XCTAssertEqual(AppLanguagePreference.english.resolve(preferredLanguages: ["ru"]), .english)
    XCTAssertEqual(AppLanguagePreference.russian.resolve(preferredLanguages: ["en"]), .russian)
  }

  func testPackagedCatalogsCoverTheSameKeysAndKeepPlaceholders() throws {
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/PolkaCore/Resources")
    func catalog(_ language: String) throws -> [String: String] {
      try XCTUnwrap(
        PropertyListSerialization.propertyList(
          from: Data(
            contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings")),
          format: nil) as? [String: String])
    }
    let english = try catalog("en")
    let russian = try catalog("ru")
    XCTAssertEqual(Set(english.keys), Set(russian.keys))
    XCTAssertGreaterThan(english.count, 400)
    let placeholders = try NSRegularExpression(pattern: "\\{[0-9]+\\}")
    func arguments(_ text: String) -> [String] {
      placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range, in: text)!])
      }.sorted()
    }
    for (key, value) in russian {
      XCTAssertFalse(value.isEmpty, key)
      XCTAssertEqual(arguments(english[key]!), arguments(value), key)
      // Exercise the copied resource bundle, rather than just the source files.
      XCTAssertEqual(AppLocalization.text(key, language: .russian), value, key)
      XCTAssertEqual(AppLocalization.text(key, language: .english), english[key], key)
    }
    // New interface copy must be added to both catalogs before it ships.
    let sources = resources.deletingLastPathComponent().deletingLastPathComponent()
    let files = try XCTUnwrap(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    let calls = try NSRegularExpression(pattern: #"\blocalized\(\s*"((?:[^"\\]|\\.)*)""#)
    for case let file as URL in files where file.pathExtension == "swift" {
      let source = try String(contentsOf: file, encoding: .utf8)
      for match in calls.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
        let key = try JSONDecoder().decode(
          String.self,
          from: Data(
            ("\"" + source[Range(match.range(at: 1), in: source)!] + "\"").utf8))
        XCTAssertNotNil(english[key], "Missing translation: \(key) in \(file.lastPathComponent)")
      }
    }
  }

  func testFallbackAndReorderedArgumentsDoNotInterpretUserText() {
    XCTAssertEqual(
      AppLocalization.text("A future untranslated label", language: .russian),
      "A future untranslated label")
    let key = "This local time occurs twice because of a clock change. Use {1} instead of {0}."
    XCTAssertEqual(
      AppLocalization.text(key, arguments: ["{1}", "$10"], language: .english),
      "This local time occurs twice because of a clock change. Use $10 instead of {1}.")
  }

  func testLanguageChangesRefreshCatalogsAndPreserveBilingualSearch() {
    defer { AppLocalization.configure(.system) }
    for (preference, name) in [
      (AppLanguagePreference.english, "Clipboard History"), (.russian, "История буфера обмена"),
    ] {
      AppLocalization.configure(preference)
      XCTAssertEqual(LauncherSearch.builtinApps.first { $0.id == "builtin:clipboard" }?.name, name)
      for query in ["Clipboard History", "История буфера обмена"] {
        XCTAssertEqual(
          LauncherSearch.apps(LauncherSearch.builtinApps, query: query).first?.id,
          "builtin:clipboard")
      }
      XCTAssertEqual(EmojiCatalog.categories.first?.label, localized("All emoji"))
    }
    AppLocalization.configure(.english)
    XCTAssertEqual(Calculator.calculate("1/0")?.message, "Cannot divide by zero")
    XCTAssertEqual(
      Calculator.calculate("2026-07-15 18:00 Moscow in London")?.displayValue, "16:00 London")
  }
}
