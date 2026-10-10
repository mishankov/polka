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
      LauncherSearch.apps(used + LauncherSearch.builtinApps, query: "", usage: stats).prefix(4).map(
        \.id),
      AppLocalization.language == .russian
        ? ["builtin:clipboard", "builtin:snippets", "builtin:files", "builtin:emoji"]
        : ["builtin:clipboard", "builtin:emoji", "builtin:files", "builtin:snippets"])
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
}
