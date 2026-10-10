import XCTest

@testable import PolkaCore

final class EmojiTests: XCTestCase {
  func testPackagedCatalogResolvesBothSwiftPMResourceLayoutsWithoutBuildDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertNil(EmojiCatalog.packagedResourceURL(in: nil))
    XCTAssertNil(EmojiCatalog.packagedResourceURL(in: root))
    for layout in ["", "Contents/Resources"] {
      let directory = root.appendingPathComponent(layout.isEmpty ? "flat" : "structured")
      let bundle = directory.appendingPathComponent("PolkaNative_PolkaCore.bundle")
      let resources = layout.isEmpty ? bundle : bundle.appendingPathComponent(layout)
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      if !layout.isEmpty {
        let plist = try PropertyListSerialization.data(
          fromPropertyList: [
            "CFBundleIdentifier": "app.polka.fixture", "CFBundlePackageType": "BNDL",
          ],
          format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
      }
      let file = resources.appendingPathComponent("emoji-data.json")
      try Data("bundled catalog".utf8).write(to: file)
      let resolved = try XCTUnwrap(EmojiCatalog.packagedResourceURL(in: directory))
      XCTAssertEqual(try Data(contentsOf: resolved), Data("bundled catalog".utf8))
    }
  }
  func testCompleteLocalizedCatalogAndSequences() {
    let catalog = EmojiCatalog.shared
    XCTAssertEqual(catalog.emojis.count, 3781)
    XCTAssertEqual(Set(catalog.emojis.map(\.id)).count, 3781)
    for emoji in catalog.emojis {
      XCTAssertFalse(emoji.name.isEmpty)
      XCTAssertFalse(emoji.englishName.isEmpty)
      XCTAssertTrue(EmojiCatalog.categories.contains { $0.id == emoji.category })
      XCTAssertEqual(emoji.value.count, 1, emoji.value)
      XCTAssertEqual(catalog.byID(emoji.id), emoji)
    }
    for value in ["❤️", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇷🇺", "1️⃣", "🏳️‍🌈"] {
      XCTAssertEqual(catalog.results(query: value).first?.value, value)
    }
    XCTAssertNil(catalog.byID("made-up-id"))
  }
  func testKeywordsCategoriesAndSkinTones() {
    let catalog = EmojiCatalog.shared
    for (query, value) in [
      ("улыбка", "😀"), ("HEART", "❤️"), ("ЛАЙК", "👍"), ("спасибо", "🙏"), ("lol", "😂"),
      ("красное сердце", "❤️"),
    ] { XCTAssertTrue(catalog.results(query: query).contains { $0.value == value }, query) }
    XCTAssertEqual(catalog.results(query: "ёлка"), catalog.results(query: "елка"))
    XCTAssertTrue(catalog.results(query: "zz-no-emoji-zz").isEmpty)
    XCTAssertEqual(catalog.results(query: "красное сердце").first?.value, "❤️")
    let people = catalog.results(query: "", category: "People & Body")
    XCTAssertFalse(people.isEmpty)
    XCTAssertTrue(people.allSatisfy { $0.category == "People & Body" && $0.tones.isEmpty })
    let toned = catalog.results(query: "лайк", tone: "🏽")
    XCTAssertTrue(toned.contains { $0.value == "👍🏽" })
    XCTAssertFalse(toned.contains { $0.value == "👍🏻" })
    XCTAssertTrue(catalog.results(query: "", tone: "all").contains { Set($0.tones).count > 1 })
    XCTAssertTrue(catalog.results(query: "❤️", tone: "🏽").contains { $0.value == "❤️" })
  }
  func testGridKeyboardClamping() {
    for (index, key, expected) in [
      (0, "ArrowRight", 1), (1, "ArrowDown", 11), (18, "ArrowDown", 22), (22, "ArrowUp", 12),
      (0, "ArrowLeft", 0), (15, "Home", 0), (2, "End", 22),
    ] {
      XCTAssertEqual(
        EmojiCatalog.gridIndex(index: index, key: key, count: 23, columns: 10), expected)
    }
    XCTAssertEqual(EmojiCatalog.gridIndex(index: 0, key: "ArrowDown", count: 0, columns: 10), 0)
  }
}
