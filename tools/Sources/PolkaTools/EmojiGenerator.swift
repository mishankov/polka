import Foundation

public enum EmojiGenerator {
  public static let unicodeVersion = "16.0"
  public static let cldrVersion = "release-48"
  public static var sources: [String: String] {
    var sources = ["emoji": "https://www.unicode.org/Public/emoji/\(unicodeVersion)/emoji-test.txt"]
    for locale in ["ru", "en"] {
      for directory in ["annotations", "annotationsDerived"] {
        sources["\(locale)/\(directory)"] =
          "https://raw.githubusercontent.com/unicode-org/cldr/\(cldrVersion)/common/\(directory)/\(locale).xml"
      }
    }
    return sources
  }
  public static func annotations(_ source: String) throws -> [String: [String: String]] {
    let document = try XMLDocument(xmlString: source, options: .nodeLoadExternalEntitiesNever)
    var result: [String: [String: String]] = [:]
    for node in try document.nodes(forXPath: "//annotation") {
      guard let element = node as? XMLElement,
        let cp = element.attribute(forName: "cp")?.stringValue
      else { continue }
      let key = cp.replacingOccurrences(of: "\u{FE0F}", with: "")
      let type = element.attribute(forName: "type")?.stringValue == "tts" ? "name" : "keywords"
      result[key, default: [:]][type] =
        element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return result
  }
  public static func catalog(files: [String: String]) throws -> [String: Any] {
    func localized(_ locale: String) throws -> [String: [String: String]] {
      var result: [String: [String: String]] = [:]
      for directory in ["annotations", "annotationsDerived"] {
        guard let source = files["\(locale)/\(directory)"] else {
          throw ToolError("Missing \(locale)/\(directory) annotations.")
        }
        for (key, item) in try annotations(source) {
          result[key, default: [:]].merge(item) { _, new in new }
        }
      }
      return result
    }
    let russian = try localized("ru")
    let english = try localized("en")
    guard let source = files["emoji"] else { throw ToolError("Missing Unicode emoji source.") }
    let regex = try NSRegularExpression(
      pattern: #"^([\dA-F ]+)\s*; fully-qualified\s*# \S+ E[\d.]+ (.+)$"#)
    var groups: [String] = []
    var entries: [[Any]] = []
    for line in source.components(separatedBy: .newlines) {
      if line.hasPrefix("# group: ") { groups.append(String(line.dropFirst(9))) }
      let range = NSRange(line.startIndex..., in: line)
      guard let match = regex.firstMatch(in: line, range: range),
        let codesRange = Range(match.range(at: 1), in: line)
      else { continue }
      let points = try line[codesRange].split(whereSeparator: \.isWhitespace).map {
        code -> Unicode.Scalar in
        guard let value = UInt32(code, radix: 16), let scalar = Unicode.Scalar(value) else {
          throw ToolError("Invalid emoji code point.")
        }
        return scalar
      }
      let emoji = String(String.UnicodeScalarView(points))
      let key = emoji.replacingOccurrences(of: "\u{FE0F}", with: "")
      guard let ru = russian[key]?["name"], !ru.isEmpty, let en = english[key]?["name"],
        !en.isEmpty, !groups.isEmpty
      else { throw ToolError("Missing localized name: \(emoji)") }
      entries.append([
        emoji, groups.count - 1, ru, en, russian[key]?["keywords"] ?? "",
        english[key]?["keywords"] ?? "",
      ])
    }
    return [
      "unicodeVersion": unicodeVersion, "cldrVersion": cldrVersion, "sources": sources,
      "groups": groups, "entries": entries,
    ]
  }
  public static func run(context: ToolContext) async throws {
    var files: [String: String] = [:]
    for (key, path) in sources.sorted(by: { $0.key < $1.key }) {
      let (data, response) = try await URLSession.shared.data(from: URL(string: path)!)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let text = String(data: data, encoding: .utf8)
      else { throw ToolError("Unicode source download failed: \(path)") }
      files[key] = text
    }
    let catalog = try catalog(files: files)
    try Files.writeJSON(
      catalog,
      to: context.root.appendingPathComponent(
        "native-app/Sources/PolkaCore/Resources/emoji-data.json"))
    print(
      "Bundled \((catalog["entries"] as? [[Any]])?.count ?? 0) emoji (\(unicodeVersion), \(cldrVersion))."
    )
  }
}
