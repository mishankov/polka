import Foundation

/// Both publishing workflows hold the shared polka-update-feed concurrency group.
/// Copy verified feed bytes without rewriting signatures or immutable archive URLs.
struct NightlyFeedPublisher {
  struct Release: Decodable {
    struct Asset: Decodable { let name: String }
    let tag: String
    let draft: Bool
    let prerelease: Bool
    let target: String
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
      case tag = "tag_name"
      case target = "target_commitish"
      case draft, prerelease, assets
    }
  }

  let execute: ([String]) throws -> Command.Result

  private func gh(_ arguments: [String]) throws -> Data {
    let result = try execute(arguments)
    guard result.status == 0 else { throw ToolError("GitHub command failed: \(result.error)") }
    return result.stdout
  }

  private func release(_ repository: String, _ endpoint: String, optional: Bool = false) throws
    -> Release?
  {
    let result = try execute(["api", "repos/\(repository)/releases/\(endpoint)"])
    if optional && result.status != 0 && result.error.contains("(HTTP 404)") { return nil }
    guard result.status == 0 else { throw ToolError("Could not read release: \(result.error)") }
    return try JSONDecoder().decode(Release.self, from: result.stdout)
  }

  private func feed(_ repository: String, _ release: Release) throws -> Data {
    guard !release.draft else { throw ToolError("Cannot publish a feed from a draft release.") }
    return try gh([
      "release", "download", release.tag, "--repo", repository,
      "--pattern", "appcast.xml", "--output", "-",
    ])
  }

  @discardableResult func publish(repository: String, tag: String) throws -> [UInt64]? {
    _ = try ReleaseVersion.repository(repository)
    _ = try ReleaseVersion.parse(tag)
    guard let candidate = try release(repository, "tags/" + ReleaseVersion.encodedTag(tag)) else {
      throw ToolError("Release is missing.")
    }
    guard !candidate.draft else {
      throw ToolError("Release must be published before advancing the feed.")
    }
    if candidate.prerelease && !candidate.tag.contains("-nightly.") { return nil }
    guard let stable = try release(repository, "latest"), !stable.prerelease else {
      throw ToolError("Latest stable release is missing or a prerelease.")
    }
    let current = try release(repository, "tags/nightly", optional: true)
    guard current?.draft != true else { throw ToolError("Nightly pointer is still a draft.") }
    var feeds = try [feed(repository, stable), feed(repository, candidate)]
    // A failed first upload can leave a new pointer with no assets. Existing
    // feeds must download and parse successfully before any replacement.
    if let current, !current.assets.isEmpty { feeds.append(try feed(repository, current)) }
    let versions = try feeds.map { try ReleaseMetadata.appcastVersion($0) }
    var newest = 0
    for index in versions.indices where versions[newest].lexicographicallyPrecedes(versions[index])
    {
      newest = index
    }
    let directory = try Files.temporary("polka-update-feed")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("appcast.xml")
    try feeds[newest].write(to: path)
    if current == nil {
      _ = try gh([
        "release", "create", "nightly", "--repo", repository,
        "--target", candidate.target, "--prerelease", "--latest=false",
        "--title", "Polka nightly channel",
        "--notes",
        "Newest signed stable or nightly build. Select Nightly in Settings → About → Updates.",
      ])
    }
    _ = try gh([
      "release", "edit", "nightly", "--prerelease", "--latest=false", "--repo", repository,
    ])
    _ = try gh(["release", "upload", "nightly", path.path, "--clobber", "--repo", repository])
    return versions[newest]
  }

  static func run(context: ToolContext) throws {
    let publisher = Self { arguments in
      try Command.execute(
        "gh", arguments, environment: context.environment, directory: context.root)
    }
    if let version = try publisher.publish(
      repository: context.environment["GITHUB_REPOSITORY"] ?? "",
      tag: context.environment["TAG"] ?? "")
    {
      print("Nightly feed build: " + version.map(String.init).joined(separator: "."))
    } else {
      print("Skipping a prerelease outside the nightly channel.")
    }
  }
}
