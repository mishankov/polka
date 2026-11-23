import XCTest

@testable import PolkaCore

final class SearchTests: XCTestCase {
  private func app(_ name: String, aliases: [String] = [], description: String = "")
    -> NativeLauncherApp
  {
    NativeLauncherApp(id: "mac:" + name, name: name, description: description, searchTerms: aliases)
  }
  func testTyposAndLayoutCorrection() {
    let apps = [
      app("Safari"), app("Calendar"), app("Mail"), app("Terminal"), app("Google Chrome"),
      app("Заметки"), app("Журнал"), app("Ёлка"),
    ]
    for query in ["saffari", "safri", "safaro", "safrai", "safra", "ЫФАФКШ", "ыфафк", "ыфакш"] {
      XCTAssertEqual(LauncherSearch.apps(apps, query: query).first?.name, "Safari", query)
    }
    for (query, expected) in [
      ("mial", "Mail"), ("calnedar", "Calendar"), ("termnal", "Terminal"),
      ("пщщпду сркщьу", "Google Chrome"), ("пс", "Google Chrome"), ("pfvtnrb", "Заметки"),
      (";ehyfk", "Журнал"), (":EHYFK", "Журнал"), ("`krf", "Ёлка"), ("~KRF", "Ёлка"),
      ("елка", "Ёлка"),
    ] { XCTAssertEqual(LauncherSearch.apps(apps, query: query).first?.name, expected, query) }
    for query in [
      "zx", "qqqqqq", String(repeating: "sa", count: 5000), "saf+ari",
      String(repeating: "x ", count: 1000),
    ] { XCTAssertTrue(LauncherSearch.apps(apps, query: query).isEmpty, String(query.prefix(30))) }
    XCTAssertTrue(LauncherSearch.apps([app("Safari")], query: "sx").isEmpty)
    XCTAssertTrue(LauncherSearch.apps([app("Clipboard")], query: "cal").isEmpty)
  }
  func testInitialsMetadataAndStableRanking() {
    let apps = [
      app("Visual Studio Code"), app("Google Chrome"), app("TextEdit"), app("Activity Monitor"),
      app("Code", aliases: ["Visual Studio Code"]), app("Disk-Utility"),
    ]
    for (query, expected) in [
      ("vsc", ["Code", "Visual Studio Code"]), ("vs", ["Code", "Visual Studio Code"]),
      ("gc", ["Google Chrome"]), ("te", ["TextEdit"]), ("am", ["Activity Monitor"]),
      ("du", ["Disk-Utility"]),
    ] { XCTAssertEqual(LauncherSearch.apps(apps, query: query).map(\.name), expected) }
    let code = app(
      "Code", aliases: ["com.microsoft.VSCode", "Visual Studio Code"],
      description: "macOS · /Applications")
    for query in ["  STUDIO   visual  ", "microsoft", "/applications", "vscode", "ma"] {
      XCTAssertEqual(LauncherSearch.apps([code], query: query), [code])
    }
    XCTAssertTrue(LauncherSearch.apps([code], query: "/applicatons").isEmpty)
    let ranked = [app("Safari Technology Preview"), app("Safira"), app("Safari"), app("My Safari")]
    let usage = Dictionary(
      uniqueKeysWithValues: ranked.enumerated().map {
        ($0.element.id, LauncherUsage(count: 100 - $0.offset, lastLaunchedAt: Double($0.offset)))
      })
    XCTAssertEqual(
      LauncherSearch.apps(ranked, query: "safari", usage: usage).map(\.name),
      ["Safari", "Safari Technology Preview", "My Safari", "Safira"])
    let used = [app("Visual Studio Code"), app("Visual Studio"), app("Visual Notes")]
    let stats = [
      used[0].id: LauncherUsage(count: 2, lastLaunchedAt: 50),
      used[1].id: LauncherUsage(count: 2, lastLaunchedAt: 100),
      used[2].id: LauncherUsage(count: 1, lastLaunchedAt: 200),
    ]
    XCTAssertEqual(
      LauncherSearch.apps(used, query: "visual", usage: stats).map(\.name),
      ["Visual Studio", "Visual Studio Code", "Visual Notes"])
    XCTAssertEqual(
      LauncherSearch.apps(Array(used.reversed()), query: "visual", usage: stats),
      LauncherSearch.apps(used, query: "visual", usage: stats))
    XCTAssertEqual(
      LauncherSearch.apps(used + LauncherSearch.builtinApps.reversed(), query: "", usage: stats)
        .map(\.id),
      [
        "builtin:clipboard", "builtin:emoji", "builtin:files", "builtin:quick-links",
        "builtin:screenshots", "builtin:snippets", "builtin:system-status", used[1].id, used[0].id,
        used[2].id,
      ])
  }
  func testBoundedSearchLargeCatalog() {
    let apps =
      (0..<3000).map { app("Application \($0) Editor", aliases: ["com.vendor.product\($0)"]) } + [
        app("Safari"), app("Visual Studio Code"),
      ]
    let start = Date()
    for query in ["sa", "saf", "safri", "ыфафкш", "vsc", String(repeating: "z", count: 10000)] {
      _ = LauncherSearch.apps(apps, query: query)
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 10)
  }

  func testRecentLaunchesRankDirectMatchesAndExpire() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let safari = app("Safari")
    let preview = app("Safari Technology Preview")
    let typo = app("Safira")
    let apps = [typo, preview, safari]
    let day: TimeInterval = 24 * 60 * 60
    var previewUsage = LauncherUsage()
    previewUsage.recordLaunch(at: now.addingTimeInterval(-2 * day))
    previewUsage.recordLaunch(at: now.addingTimeInterval(-day))
    var safariUsage = LauncherUsage()
    safariUsage.recordLaunch(at: now)
    let usage = [
      preview.id: previewUsage, safari.id: safariUsage,
      typo.id: LauncherUsage(count: 100, lastLaunchedAt: now.timeIntervalSince1970 * 1000),
    ]
    let persisted = try JSONEncoder().encode(usage)
    let restored = try JSONDecoder().decode([String: LauncherUsage].self, from: persisted)
    XCTAssertEqual(restored, usage)
    XCTAssertEqual(LauncherSearch.apps(apps, query: "safari", now: now), [safari, preview, typo])
    XCTAssertEqual(
      LauncherSearch.apps(apps, query: "safari", usage: restored, now: now),
      [preview, safari, typo])
    XCTAssertEqual(
      LauncherSearch.apps(
        apps, query: "safari", usage: restored, now: now.addingTimeInterval(7 * day + 1)),
      [safari, preview, typo])
  }

  func testLaunchFrequencySurvivesClockRollbackAndCountsEveryInWindowLaunch() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let keynote = app("Keynote")
    let beta = app("Keynote Beta")
    var keynoteUsage = LauncherUsage()
    var betaUsage = LauncherUsage()
    keynoteUsage.recordLaunch(at: now.addingTimeInterval(-1))
    for _ in 0..<500 {
      keynoteUsage.recordLaunch(at: now.addingTimeInterval(-2))
      betaUsage.recordLaunch(at: now)
    }
    XCTAssertEqual(keynoteUsage.lastLaunchedAt, 1_799_999_999_000)
    XCTAssertEqual(
      LauncherSearch.apps(
        [beta, keynote], query: "keynote", usage: [keynote.id: keynoteUsage, beta.id: betaUsage],
        now: now), [keynote, beta])
  }

  func testTypedNameMatchesRankAboveBundleIdentifiersAndLayoutCorrection() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let appleTV = app("Apple TV")
    let mail = NativeLauncherApp(id: "mac:Mail", name: "Mail", bundleIdentifier: "com.apple.mail")
    let terminal = app("Terminal")
    let notes = app("Заметки")
    let safari = app("Safari")
    let preview = app("Safari Technology Preview")
    let literalCyrillic = app("Ыфафкш Tools")
    var recent = LauncherUsage()
    recent.recordLaunch(at: now)
    let usage = [mail.id: recent, notes.id: recent, preview.id: recent]
    XCTAssertEqual(
      LauncherSearch.apps([mail, appleTV], query: "apple", usage: usage, now: now), [appleTV, mail])
    XCTAssertEqual(LauncherSearch.apps([appleTV, mail], query: "com.apple.mail"), [mail])
    XCTAssertEqual(
      LauncherSearch.apps([notes, terminal], query: "t", usage: usage, now: now), [terminal, notes])
    XCTAssertEqual(
      LauncherSearch.apps([safari, literalCyrillic], query: "ЫФАФКШ", now: now),
      [literalCyrillic, safari])
    XCTAssertEqual(
      LauncherSearch.apps([safari, preview], query: "ыфафкш", usage: usage, now: now),
      [preview, safari])
  }

  func testLegacyUsageRetainsItsLastKnownLaunch() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let preview = app("Safari Technology Preview")
    let safari = app("Safari")
    let legacy = try JSONDecoder().decode(
      LauncherUsage.self, from: Data(#"{"count":100,"lastLaunchedAt":1799999999000}"#.utf8))
    var updated = legacy
    updated.recordLaunch(at: now.addingTimeInterval(-0.5))
    var safariUsage = LauncherUsage()
    safariUsage.recordLaunch(at: now)
    let apps = [safari, preview]
    XCTAssertEqual(
      LauncherSearch.apps(apps, query: "safari", usage: [preview.id: legacy], now: now).first,
      preview)
    XCTAssertEqual(
      LauncherSearch.apps(
        apps, query: "safari", usage: [preview.id: updated, safari.id: safariUsage], now: now
      ).first, preview, "A known legacy launch still counts after the first new launch")
  }

  func testScatteredNameMatchesStayBelowDirectMatches() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let safari = app("Safari")
    let direct = app("SFR Viewer")
    let password = app("1Password")
    let metadataOnly = app("Notes", aliases: ["org.safari"])
    let apps = [safari, direct, password, metadataOnly]
    let usage = [
      safari.id: LauncherUsage(count: 100, lastLaunchedAt: now.timeIntervalSince1970 * 1000)
    ]
    XCTAssertEqual(
      LauncherSearch.apps(apps, query: "sfr", usage: usage, now: now), [direct, safari])
    XCTAssertEqual(LauncherSearch.apps(apps, query: "1pwd"), [password])
    XCTAssertEqual(LauncherSearch.apps([safari], query: "sfi"), [safari])
    XCTAssertTrue(LauncherSearch.apps([safari], query: "sf").isEmpty)
  }
}
