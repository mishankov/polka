import Foundation
import XCTest

@testable import PolkaTools

final class EmojiGeneratorTests: XCTestCase {
  private func files() -> [String: String] {
    [
      "emoji": """
      # group: Smileys & Emotion
      1F600 ; fully-qualified # 😀 E1.0 grinning face
      2764 FE0F ; fully-qualified # ❤️ E0.6 red heart
      2764 ; unqualified # ❤ E0.6 red heart
      # group: People & Body
      1F44D 1F3FD ; fully-qualified # 👍🏽 E1.0 thumbs up: medium skin tone
      """,
      "en/annotations": """
      <ldml><annotations>
        <annotation cp="😀" type="tts">grinning face</annotation>
        <annotation cp="😀">face | grin | happy</annotation>
        <annotation cp="❤" type="tts">red heart</annotation>
        <annotation cp="❤">heart | love &amp; affection</annotation>
      </annotations></ldml>
      """,
      "ru/annotations": """
      <ldml><annotations>
        <annotation cp="😀" type="tts">улыбающееся лицо</annotation>
        <annotation cp="😀">лицо | улыбка</annotation>
        <annotation cp="❤️" type="tts">красное сердце</annotation>
        <annotation cp="❤">любовь | сердце</annotation>
      </annotations></ldml>
      """,
      "en/annotationsDerived": """
      <ldml><annotations>
        <annotation cp="👍🏽" type="tts">thumbs up: medium skin tone</annotation>
        <annotation cp="👍🏽">medium skin tone | thumbs up</annotation>
        <annotation cp="😀">smile | happy</annotation>
      </annotations></ldml>
      """,
      "ru/annotationsDerived": """
      <ldml><annotations>
        <annotation cp="👍🏽" type="tts">большой палец вверх: средний тон кожи</annotation>
        <annotation cp="👍🏽">палец | средний тон кожи</annotation>
      </annotations></ldml>
      """,
    ]
  }
  func testUnicodeSequencesCategoriesAndBothCLDRLocalesArePreserved() throws {
    let catalog = try EmojiGenerator.catalog(files: files())
    XCTAssertEqual(catalog["unicodeVersion"] as? String, "16.0")
    XCTAssertEqual(catalog["cldrVersion"] as? String, "release-48")
    XCTAssertEqual(catalog["groups"] as? [String], ["Smileys & Emotion", "People & Body"])
    let entries = try XCTUnwrap(catalog["entries"] as? [[Any]])
    XCTAssertEqual(
      entries.count, 3, "Unqualified entries must not become copyable catalog sequences")
    XCTAssertEqual(entries.map { $0[0] as! String }, ["😀", "❤️", "👍🏽"])
    XCTAssertEqual(entries.map { $0[1] as! Int }, [0, 0, 1])
    XCTAssertEqual(
      entries[0][5] as? String, "smile | happy", "Derived CLDR keywords take precedence")
    XCTAssertEqual(entries[1][2] as? String, "красное сердце")
    XCTAssertEqual(entries[1][5] as? String, "heart | love & affection")
    XCTAssertEqual(entries[2][2] as? String, "большой палец вверх: средний тон кожи")
    XCTAssertEqual(entries[2][3] as? String, "thumbs up: medium skin tone")
  }
  func testSelectorNormalizationOnlyAffectsAnnotationLookup() throws {
    let result = try EmojiGenerator.annotations(
      "<ldml><annotation cp=\"❤️\" type=\"tts\">  red heart  </annotation></ldml>")
    XCTAssertEqual(result["❤"]?["name"], "red heart")
    XCTAssertNil(result["❤️"])
    let entries = try XCTUnwrap(EmojiGenerator.catalog(files: files())["entries"] as? [[Any]])
    XCTAssertEqual(entries[1][0] as? String, "❤️", "Qualified copy sequence retains FE0F")
  }
  func testMissingSourcesNamesAndMalformedXMLStopGeneration() throws {
    for key in ["emoji", "ru/annotations", "en/annotationsDerived"] {
      var invalid = files()
      invalid.removeValue(forKey: key)
      XCTAssertThrowsError(try EmojiGenerator.catalog(files: invalid))
    }
    var missingTranslation = files()
    missingTranslation["ru/annotations"] = "<ldml/>"
    XCTAssertThrowsError(try EmojiGenerator.catalog(files: missingTranslation))
    XCTAssertThrowsError(try EmojiGenerator.annotations("<ldml><annotation cp=\"😀\">broken"))
    var invalidScalar = files()
    invalidScalar["emoji"] = "# group: Invalid\n110000 ; fully-qualified # ? E1.0 invalid scalar"
    XCTAssertThrowsError(try EmojiGenerator.catalog(files: invalidScalar))
  }
}
