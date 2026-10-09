import Foundation

public enum Coverage {
  public static let thresholds = ["business": 76.0, "overall": 43.0]
  public static let targets = ["PolkaCoreTests", "PolkaPlatformTests", "PolkaUITests"]
  public struct Group: Codable, Equatable {
    public var covered = 0
    public var total = 0
    public var files = 0
    public var percent: Double { total > 0 ? Double(covered) * 100 / Double(total) : 0 }
    enum CodingKeys: String, CodingKey { case covered, total, files, percent }
    public init(covered: Int = 0, total: Int = 0, files: Int = 0) {
      self.covered = covered
      self.total = total
      self.files = files
    }
    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      covered = try container.decode(Int.self, forKey: .covered)
      total = try container.decode(Int.self, forKey: .total)
      files = try container.decode(Int.self, forKey: .files)
    }
    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(covered, forKey: .covered)
      try container.encode(total, forKey: .total)
      try container.encode(files, forKey: .files)
      try container.encode(percent, forKey: .percent)
    }
  }
  public struct Source: Codable {
    public let path: String
    public let group: String
    public let covered: Int
    public let total: Int
    public let percent: Double
  }
  public struct Gate: Codable {
    public let passed: Bool
    public let thresholds: [String: Double]
    public let failures: [String]
  }
  public struct Report: Codable {
    public var metric = "LLVM executable source lines (unit/service/UI unit tests)"
    public let scope: [String: String]
    public var groups: [String: Group]
    public let files: [Source]
    public var gate: Gate?
  }
  public static func exportArguments(codecov: URL, nativeEngine: Bool = false) -> [String] {
    let directory = codecov.deletingLastPathComponent()
    let products = directory.deletingLastPathComponent()
    // Native SwiftPM links all test targets into one package XCTest bundle;
    // Swift Build emits a separate bundle for each target.
    let testBundles = nativeEngine ? ["PolkaNativePackageTests"] : targets
    let binaries = testBundles.map {
      products.appendingPathComponent("\($0).xctest/Contents/MacOS/\($0)").path
    }
    return [
      "llvm-cov", "export", "-summary-only", "-instr-profile",
      directory.appendingPathComponent("default.profdata").path, binaries[0],
    ] + binaries.dropFirst().flatMap { ["-object", $0] }
  }
  static func group(_ path: String) -> String? {
    guard path.hasSuffix(".swift") else { return nil }
    if path.hasPrefix("native-app/Sources/PolkaCore/") { return "core" }
    guard path.hasPrefix("native-app/Sources/PolkaApp/") else { return nil }
    let name = URL(fileURLWithPath: path).lastPathComponent
    if name.hasPrefix("Native") && name.contains("Smoke") { return nil }
    return path.hasPrefix("native-app/Sources/PolkaApp/Platform/") ? "platform" : "app"
  }
  public static func summary(_ data: Data, root: URL, sourceFiles: [URL]? = nil) throws -> Report {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = json["data"] as? [[String: Any]], !entries.isEmpty
    else { throw ToolError("Missing LLVM coverage data.") }
    var groups = Dictionary(
      uniqueKeysWithValues: ["core", "platform", "business", "overall"].map { ($0, Group()) })
    var sources: [Source] = []
    var seen = Set<String>()
    for entry in entries {
      guard let files = entry["files"] as? [[String: Any]] else {
        throw ToolError("Missing LLVM file coverage.")
      }
      for file in files {
        guard let filename = file["filename"] as? String, filename.hasPrefix("/") else { continue }
        let path = Files.relative(URL(fileURLWithPath: filename), to: root)
        guard let scope = group(path) else { continue }
        guard seen.insert(path).inserted else {
          throw ToolError("Duplicate source coverage: \(path). Export all test binaries together.")
        }
        guard let summary = file["summary"] as? [String: Any],
          let lines = summary["lines"] as? [String: Any],
          let covered = lines["covered"] as? Int, let total = lines["count"] as? Int, covered >= 0,
          total >= covered
        else { throw ToolError("Invalid line coverage: \(path).") }
        for key in scope == "app" ? ["overall"] : [scope, "business", "overall"] {
          groups[key]!.covered += covered
          groups[key]!.total += total
          groups[key]!.files += 1
        }
        sources.append(
          Source(
            path: path, group: scope, covered: covered, total: total,
            percent: total == 0 ? 100 : Double(covered) * 100 / Double(total)))
      }
    }
    for file in sourceFiles ?? [] {
      let path = Files.relative(file, to: root)
      if group(path) != nil && !seen.contains(path) {
        throw ToolError("Source omitted from coverage: \(path).")
      }
    }
    return Report(
      scope: [
        "business": "PolkaCore + PolkaApp/Platform",
        "overall":
          "All PolkaCore + PolkaApp Swift product sources, including UI and NativeApplication",
        "excluded":
          "Generated/dependency/test/probe sources and Native*Smoke*.swift desktop drivers; no GUI coverage is merged",
      ], groups: groups, files: sources.sorted { $0.path < $1.path })
  }
  public static func gate(_ report: Report, thresholds: [String: Double] = thresholds) throws
    -> Gate
  {
    var failures: [String] = []
    for (key, floor) in thresholds.sorted(by: { $0.key < $1.key }) {
      guard floor.isFinite, (0...100).contains(floor) else {
        throw ToolError("Invalid \(key) coverage threshold.")
      }
      guard let group = report.groups[key], group.total > 0 else {
        failures.append("\(key): no source coverage")
        continue
      }
      if group.percent < floor {
        failures.append(String(format: "%@: %.2f%% < %.2f%%", key, group.percent, floor))
      }
    }
    return Gate(passed: failures.isEmpty, thresholds: thresholds, failures: failures)
  }
  public static func run(context: ToolContext) throws {
    try Command.run(
      "swift",
      ["test"] + context.swiftBuildArguments
        + ["--package-path", "native-app", "--enable-code-coverage"],
      environment: context.environment, directory: context.root)
    let path = try Command.capture(
      "swift",
      ["test"] + context.swiftBuildArguments
        + ["--package-path", "native-app", "--show-codecov-path"],
      environment: context.environment, directory: context.root
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = try Command.execute(
      "xcrun",
      exportArguments(
        codecov: URL(fileURLWithPath: path),
        nativeEngine: context.environment["POLKA_SWIFT_BUILD_SYSTEM"] == "native"),
      environment: context.environment, directory: context.root)
    guard raw.status == 0 else { throw ToolError("LLVM coverage export failed.") }
    let files = ["PolkaCore", "PolkaApp"].flatMap {
      sourceFiles(context.root.appendingPathComponent("native-app/Sources/\($0)"))
    }
    var report = try summary(raw.stdout, root: context.root, sourceFiles: files)
    report.gate = try gate(report)
    let directory = context.root.appendingPathComponent("artifacts/coverage")
    try Files.mkdir(directory)
    try raw.stdout.write(to: directory.appendingPathComponent("native-llvm.json"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: directory.appendingPathComponent("native-summary.json"))
    for key in ["core", "platform", "business", "overall"] {
      let value = report.groups[key]!
      print(
        String(
          format: "%@: %.2f%% (%d/%d lines, %d files)", key, value.percent, value.covered,
          value.total, value.files))
    }
    guard report.gate!.passed else {
      throw ToolError("Coverage gate failed: \(report.gate!.failures.joined(separator: "; "))")
    }
  }
  static func sourceFiles(_ directory: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
  }
}
