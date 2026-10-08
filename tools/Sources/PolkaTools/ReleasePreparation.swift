import Foundation

public enum ReleasePreparation {
  public struct Prepared {
    public let tag: String
    public let commit: String
    public let safeTag: String
    public let publishAfterUpload: Bool
  }
  // Workflow selection, notes preflight and tag pinning all use one immutable
  // commit. This operation is only invoked by an explicitly requested release.
  public static func run(context: ToolContext) throws -> Prepared {
    let env = context.environment
    let published = env["EVENT_NAME"] == "release"
    let tag = env[published ? "RELEASE_TAG" : "REQUESTED_TAG"] ?? ""
    let version = try ReleaseVersion.parse(tag)
    // A valid semantic version may still be unsuitable for release filenames.
    // Reject it before creating a GitHub draft or its immutable Git tag.
    _ = try ReleaseMetadata.artifactNames(metadata: PolkaMetadata(version: version))
    let repository = env["GITHUB_REPOSITORY"] ?? ""
    _ = try ReleaseVersion.repository(repository)
    func capture(_ tool: String, _ args: [String]) throws -> String {
      try Command.capture(tool, args, environment: env, directory: context.root).trimmingCharacters(
        in: .whitespacesAndNewlines)
    }
    func run(_ tool: String, _ args: [String]) throws {
      try Command.run(tool, args, environment: env, directory: context.root)
    }
    try run("git", ["check-ref-format", "refs/tags/\(tag)"])
    let viewed = try Command.execute(
      "gh", ["release", "view", tag, "--json", "isDraft,targetCommitish", "--repo", repository],
      environment: env, directory: context.root)
    let exists = viewed.status == 0
    var draft = false
    var target = env["DEFAULT_BRANCH"] ?? "master"
    if exists {
      guard let metadata = try JSONSerialization.jsonObject(with: viewed.stdout) as? [String: Any],
        let isDraft = metadata["isDraft"] as? Bool,
        let ref = metadata["targetCommitish"] as? String, !ref.isEmpty
      else { throw ToolError("Invalid GitHub release metadata.") }
      draft = isDraft
      target = ref
    } else if published {
      throw ToolError("Published release \(tag) could not be read.")
    }
    let remote = try capture("git", ["ls-remote", "--refs", "origin", "refs/tags/\(tag)"])
    if !remote.isEmpty {
      try run("git", ["fetch", "--depth=1", "origin", "refs/tags/\(tag)"])
    } else {
      guard !exists || draft else {
        throw ToolError("Published release \(tag) is missing its Git tag. Refusing to recreate it.")
      }
      let sha = try capture("gh", ["api", "repos/\(repository)/commits/\(target)", "--jq", ".sha"])
      guard sha.range(of: "^[A-Fa-f0-9]{40}$", options: .regularExpression) != nil else {
        throw ToolError("Invalid release source commit.")
      }
      try run("git", ["fetch", "--depth=1", "origin", sha])
    }
    let commit = try capture("git", ["rev-parse", "FETCH_HEAD^{commit}"])
    let temporary = URL(
      fileURLWithPath: env["RUNNER_TEMP"] ?? FileManager.default.temporaryDirectory.path)
    let notesFile = temporary.appendingPathComponent("release-notes.json")
    let description = temporary.appendingPathComponent("release-notes.md")
    let text = try capture("git", ["show", "\(commit):release-notes/\(version).json"])
    try Data(text.utf8).write(to: notesFile)
    let notes = try ReleaseNotes.read(version: version, root: context.root, source: notesFile)
    try Data(try notes.markdown(tag: tag, repository: repository).utf8).write(to: description)
    if !exists {
      var arguments = [
        "release", "create", tag, "--target", commit, "--draft", "--repo", repository,
        "--notes-file", description.path,
      ]
      if env["PRERELEASE"] == "true" { arguments.append("--prerelease") }
      try run("gh", arguments)
      draft = true
    }
    let current = try capture("git", ["ls-remote", "--refs", "origin", "refs/tags/\(tag)"])
    if current.isEmpty {
      try run(
        "gh",
        [
          "api", "--method", "POST", "repos/\(repository)/git/refs", "-f", "ref=refs/tags/\(tag)",
          "-f", "sha=\(commit)",
        ])
    }
    try run("git", ["fetch", "--depth=1", "origin", "refs/tags/\(tag)"])
    guard try capture("git", ["rev-parse", "FETCH_HEAD^{commit}"]) == commit else {
      throw ToolError(
        "Release tag changed during preparation. Refusing to build a different source.")
    }
    let safeTag = tag.replacingOccurrences(
      of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    let result = Prepared(
      tag: tag, commit: commit, safeTag: safeTag, publishAfterUpload: !published && draft)
    if let path = env["GITHUB_OUTPUT"] {
      let output =
        "tag=\(tag)\ncommit=\(commit)\nsafe_tag=\(safeTag)\npublish_after_upload=\(result.publishAfterUpload)\nhas_notes=true\n"
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(output.utf8))
    }
    return result
  }
}
