import Foundation
import PolkaCore

let encoder = JSONEncoder()
while let line = readLine() {
  do {
    guard let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    else { throw CocoaError(.coderReadCorrupt) }
    let query = input["query"] as? String ?? ""
    AppLocalization.configure(
      AppLanguagePreference(rawValue: input["language"] as? String ?? "system") ?? .system)
    let output: Data
    switch input["action"] as? String {
    case "calculate":
      let context = input["context"] as? [String: Any] ?? [:]
      let now: Date
      if let timestamp = context["now"] as? Double {
        now = Date(timeIntervalSince1970: timestamp / 1000)
      } else if let value = context["now"] as? String {
        now = ISO8601DateFormatter().date(from: value) ?? Date()
      } else {
        now = Date()
      }
      output = try encoder.encode(
        Calculator.calculate(
          query, context: CalculationContext(now: now, sourceDate: context["sourceDate"] as? String)
        ))
    case "search":
      let apps = try JSONDecoder().decode(
        [NativeLauncherApp].self, from: JSONSerialization.data(withJSONObject: input["apps"] ?? []))
      let usage = try JSONDecoder().decode(
        [String: LauncherUsage].self,
        from: JSONSerialization.data(withJSONObject: input["usage"] ?? [:]))
      output = try encoder.encode(LauncherSearch.apps(apps, query: query, usage: usage).map(\.id))
    case "emoji":
      output = try encoder.encode(
        EmojiCatalog.shared.results(
          query: query, category: input["category"] as? String ?? "all",
          tone: input["tone"] as? String ?? "default"
        ).map(\.id))
    default: throw CocoaError(.featureUnsupported)
    }
    print(String(decoding: output, as: UTF8.self))
    fflush(stdout)
  } catch { print("{\"error\":\"invalid probe input\"}") }
}
