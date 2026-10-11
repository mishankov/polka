import Foundation

public enum NightlyPreparation {
  public static func version(base: String, date: Date, runID: String, attempt: String) throws
    -> String
  {
    let stable = try ReleaseVersion.parse(base)
    let parts = stable.split(separator: ".")
    guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }),
      let patch = Int(parts[2]), patch < Int.max,
      [runID, attempt].allSatisfy({
        $0.range(of: #"^[1-9][0-9]*\z"#, options: .regularExpression) != nil
      })
    else {
      throw ReleaseError.invalid(
        "Nightlies require a stable base version and positive run ID/attempt.")
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss"
    return
      "\(parts[0]).\(parts[1]).\(patch + 1)-nightly.\(formatter.string(from: date)).\(runID).\(attempt)"
  }
  public static func run(context: ToolContext = ToolContext()) throws {
    let metadata = try PolkaMetadata.load(root: context.root)
    let version = try version(
      base: context.environment["NIGHTLY_BASE_VERSION"] ?? metadata.version,
      date: Date(), runID: context.environment["GITHUB_RUN_ID"] ?? "",
      attempt: context.environment["GITHUB_RUN_ATTEMPT"] ?? "")
    let commit = try Command.capture("git", ["rev-parse", "HEAD"], directory: context.root)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard commit.range(of: #"^[0-9a-f]{40}\z"#, options: .regularExpression) != nil,
      let output = context.environment["GITHUB_OUTPUT"]
    else {
      throw ReleaseError.invalid("Nightly preparation requires a source commit and GITHUB_OUTPUT.")
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("tag=v\(version)\ncommit=\(commit)\n".utf8))
  }
}

extension ReleaseTool {
  public static func notes(metadata: PolkaMetadata, context: ToolContext) throws -> ReleaseNotes {
    guard context.environment["RELEASE_CHANNEL"] == "nightly" else {
      return try ReleaseNotes.read(version: metadata.version, root: context.root)
    }
    let commit = context.environment["RELEASE_COMMIT"] ?? ""
    guard metadata.version.contains("-nightly."),
      commit.range(of: #"^[0-9a-f]{40}\z"#, options: .regularExpression) != nil
    else {
      throw ReleaseError.invalid("Nightly notes require the pinned master commit.")
    }
    let actual = try Command.capture("git", ["rev-parse", "HEAD"], directory: context.root)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard actual == commit else {
      throw ReleaseError.invalid("Nightly source no longer matches the pinned commit.")
    }
    return try ReleaseNotes(
      ru:
        "Ночная сборка из master: \(commit). Может содержать ошибки. В настройках «О приложении → Обновления» выберите ночной или стабильный канал. Возврат на стабильный канал дождётся более новой стабильной версии без понижения версии.",
      en:
        "Nightly build from master: \(commit). May contain bugs. Choose Nightly or Stable in Settings → About → Updates. Switching back to Stable waits for a newer stable version without downgrading."
    )
  }
}
