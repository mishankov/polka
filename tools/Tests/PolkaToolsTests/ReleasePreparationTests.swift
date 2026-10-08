import Foundation
import XCTest

@testable import PolkaTools

final class ReleasePreparationTests: XCTestCase {
  private let tag = "v0.2.0"
  private struct Fixture {
    let root: URL, source: URL, remote: URL, log: URL, output: URL, commit: String
    var environment: [String: String]
    var context: ToolContext { ToolContext(root: source, environment: environment) }
    func git(_ arguments: [String]) throws -> String {
      try Command.capture("git", arguments, environment: environment, directory: source)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func calls() throws -> [[String]] {
      try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode([String].self, from: Data($0.utf8))
      }
    }
    func outputs() throws -> [String: String] {
      var values: [String: String] = [:]
      for line in try String(contentsOf: output, encoding: .utf8).split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
      }
      return values
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }
  private func fixture(
    notes: Any? = nil, missing: Bool = false, tagged: Bool = false,
    existing: String? = nil, race: Bool = false
  ) throws -> Fixture {
    let root = try Files.temporary("polka-release-preparation")
    let source = root.appendingPathComponent("source")
    let remote = root.appendingPathComponent("origin.git")
    let bin = root.appendingPathComponent("bin")
    let log = root.appendingPathComponent("calls.jsonl")
    let output = root.appendingPathComponent("outputs")
    do {
      try Files.mkdir(source)
      try Files.mkdir(bin)
      try Data().write(to: log)
      try Data().write(to: output)
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
      environment["GH_TOKEN"] = "synthetic-release-test-token"
      environment["EVENT_NAME"] = "workflow_dispatch"
      environment["REQUESTED_TAG"] = tag
      environment["RELEASE_TAG"] = ""
      environment["PRERELEASE"] = "false"
      environment["DEFAULT_BRANCH"] = "master"
      environment["GITHUB_REPOSITORY"] = "fixture/polka"
      environment["RUNNER_TEMP"] = root.path
      environment["GITHUB_OUTPUT"] = output.path
      environment["RELEASE_TEST_LOG"] = log.path
      environment["RELEASE_TEST_REMOTE"] = remote.path
      environment["RELEASE_TEST_EXISTING"] = existing ?? ""
      environment["RELEASE_TEST_DESCRIPTION"] =
        root.appendingPathComponent("github-description.md").path
      let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      #if DEBUG
        let configuration = "debug"
      #else
        let configuration = "release"
      #endif
      let executable = tools.appendingPathComponent(".build/\(configuration)/polka-tool-fixture")
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw ToolError("Build the disposable tooling fixture")
      }
      try FileManager.default.createSymbolicLink(
        at: bin.appendingPathComponent("gh"), withDestinationURL: executable)
      func git(_ args: [String]) throws -> String {
        try Command.capture("git", args, environment: environment, directory: source)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      _ = try git(["init", "--bare", remote.path])
      _ = try git(["init", "-b", "master"])
      _ = try git(["remote", "add", "origin", remote.path])
      try Data("Synthetic immutable release source".utf8).write(
        to: source.appendingPathComponent("README.md"))
      try Files.mkdir(source.appendingPathComponent("release-notes"))
      if !missing {
        try Files.writeJSON(
          notes ?? ["ru": "• Из проверенного коммита.", "en": "• From the verified commit."],
          to: source.appendingPathComponent("release-notes/0.2.0.json"))
      }
      _ = try git(["add", "."])
      let commitArguments = [
        "-c", "user.name=Release test", "-c", "user.email=release@example.invalid", "commit", "-m",
      ]
      _ = try git(commitArguments + ["Release source"])
      let commit = try git(["rev-parse", "HEAD"])
      _ = try git(["push", "origin", "master"])
      if tagged {
        _ = try git(["tag", tag])
        _ = try git(["push", "origin", tag])
      }
      if race {
        try Data("A different source".utf8).write(
          to: source.appendingPathComponent("branch-movement.txt"))
        _ = try git(["add", "branch-movement.txt"])
        _ = try git(commitArguments + ["Branch moved"])
        environment["RELEASE_TEST_RACE"] = try git(["rev-parse", "HEAD"])
        _ = try git(["push", "origin", "master"])
      }
      environment["RELEASE_TEST_COMMIT"] = commit
      try Files.writeJSON(
        ["ru": "Неверный checkout", "en": "Wrong checkout notes"],
        to: source.appendingPathComponent("release-notes/0.2.0.json"))
      return Fixture(
        root: root, source: source, remote: remote, log: log, output: output, commit: commit,
        environment: environment)
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }
  private func mutates(_ calls: [[String]]) -> Bool {
    calls.contains { $0.starts(with: ["release", "create"]) || $0.contains("POST") }
  }
  func testNewReleasePreflightsImmutableNotesAndPinsDraftAndTag() throws {
    let f = try fixture()
    defer { f.cleanup() }
    let prepared = try ReleasePreparation.run(context: f.context)
    XCTAssertEqual(prepared.commit, f.commit)
    XCTAssertTrue(prepared.publishAfterUpload)
    let outputs = try f.outputs()
    XCTAssertEqual(outputs["commit"], f.commit)
    XCTAssertEqual(outputs["has_notes"], "true")
    XCTAssertEqual(outputs["publish_after_upload"], "true")
    let create = try XCTUnwrap(f.calls().first { $0.starts(with: ["release", "create"]) })
    XCTAssertEqual(create[try XCTUnwrap(create.firstIndex(of: "--target")) + 1], f.commit)
    XCTAssertFalse(create.contains("--generate-notes"))
    let description = try String(
      contentsOf: f.root.appendingPathComponent("github-description.md"), encoding: .utf8)
    XCTAssertTrue(description.hasPrefix("# Polka 0.2.0\n"))
    XCTAssertTrue(description.contains("- Из проверенного коммита."))
    XCTAssertTrue(description.contains("- From the verified commit."))
    XCTAssertFalse(description.contains("Wrong checkout notes"))
    XCTAssertTrue(description.contains("### Установка"))
    XCTAssertTrue(description.contains("### Installation"))
    XCTAssertTrue(
      description.contains(
        "https://github.com/fixture/polka/releases/download/v0.2.0/polka-0.2.0-arm64.dmg"))
    XCTAssertEqual(
      try f.git(["--git-dir", f.remote.path, "rev-parse", "refs/tags/\(tag)"]), f.commit)
  }
  func testMissingOrInvalidTranslationsStopBeforeDraftOrTag() throws {
    for invalid in [nil, ["ru": "Нет английского"], ["ru": " ", "en": "English"]]
      as [[String: String]?]
    {
      let f = try fixture(notes: invalid, missing: invalid == nil)
      defer { f.cleanup() }
      XCTAssertThrowsError(try ReleasePreparation.run(context: f.context))
      XCTAssertFalse(try mutates(f.calls()))
      XCTAssertEqual(try f.outputs(), [:])
      XCTAssertEqual(try f.git(["ls-remote", "--refs", "origin", "refs/tags/\(tag)"]), "")
    }
  }
  func testUnsupportedArtifactVersionStopsBeforeGitHubMutation() throws {
    var f = try fixture()
    defer { f.cleanup() }
    f.environment["REQUESTED_TAG"] = "v0.2.0+build"
    XCTAssertEqual(try ReleaseVersion.parse("v0.2.0+build"), "0.2.0+build")
    XCTAssertThrowsError(try ReleasePreparation.run(context: f.context)) { error in
      XCTAssertTrue(String(describing: error).contains("artifact name"))
    }
    XCTAssertEqual(try f.calls(), [])
    XCTAssertEqual(try f.outputs(), [:])
    XCTAssertEqual(try f.git(["ls-remote", "--refs", "origin", "refs/tags/v0.2.0+build"]), "")
  }
  func testPublishedTaggedReleaseIsReusedWithoutChangingSource() throws {
    let f = try fixture(tagged: true, existing: "published")
    defer { f.cleanup() }
    let result = try ReleasePreparation.run(context: f.context)
    XCTAssertEqual(result.commit, f.commit)
    XCTAssertFalse(result.publishAfterUpload)
    XCTAssertEqual(try f.outputs()["has_notes"], "true")
    XCTAssertFalse(try f.calls().contains { $0.first == "api" || $0.contains("create") })
  }
  func testPublishedRetryStillRequiresNotesFromPinnedCommit() throws {
    let f = try fixture(missing: true, tagged: true, existing: "published")
    defer { f.cleanup() }
    XCTAssertThrowsError(try ReleasePreparation.run(context: f.context))
    XCTAssertEqual(try f.outputs(), [:])
    XCTAssertFalse(try mutates(f.calls()))
    XCTAssertEqual(
      try f.git(["--git-dir", f.remote.path, "rev-parse", "refs/tags/\(tag)"]), f.commit)
  }
  func testDraftWithoutTagResumesSameSourceWithoutDuplicateRelease() throws {
    let f = try fixture(existing: "draft")
    defer { f.cleanup() }
    let result = try ReleasePreparation.run(context: f.context)
    XCTAssertTrue(result.publishAfterUpload)
    XCTAssertFalse(try f.calls().contains { $0.contains("create") })
    XCTAssertEqual(try f.calls().filter { $0.contains("POST") }.count, 1)
    XCTAssertEqual(
      try f.git(["--git-dir", f.remote.path, "rev-parse", "refs/tags/\(tag)"]), f.commit)
  }
  func testTagRaceAbortsInsteadOfBuildingUnverifiedSource() throws {
    let f = try fixture(race: true)
    defer { f.cleanup() }
    XCTAssertThrowsError(try ReleasePreparation.run(context: f.context)) { error in
      XCTAssertTrue(String(describing: error).contains("Release tag changed"))
    }
    XCTAssertEqual(try f.outputs(), [:])
    let create = try XCTUnwrap(f.calls().first { $0.contains("create") })
    XCTAssertEqual(create[try XCTUnwrap(create.firstIndex(of: "--target")) + 1], f.commit)
  }
  private var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }
  private func source(_ path: String) throws -> String {
    try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
  }
  private func job(_ name: String, in document: String) throws -> String {
    let marker = "\n  \(name):\n"
    let start = try XCTUnwrap(document.range(of: marker)).upperBound
    let tail = document[start...]
    let end =
      tail.range(of: #"\n  [A-Za-z][A-Za-z0-9_-]*:\n"#, options: .regularExpression)?.lowerBound
      ?? document.endIndex
    return String(document[start..<end])
  }
  func testAggregateBranchProtectionRequiresAllNativeJobs() throws {
    let build = try source(".github/workflows/build.yml")
    let aggregate = try job("macos-arm64", in: build)
    XCTAssertTrue(aggregate.contains("name: Verify and package macOS arm64"))
    XCTAssertTrue(aggregate.contains("needs: [verify, package, updates]"))
    XCTAssertTrue(aggregate.contains("if: always()"))
    XCTAssertTrue(aggregate.contains("all(.[]; .result == \"success\")"))
    for name in ["verify", "package", "updates"] {
      XCTAssertTrue(try job(name, in: build).contains("runs-on: xcode-27"))
    }
    XCTAssertTrue(try job("verify", in: build).contains("./polka verify --no-desktop"))
  }
  func testPackageAndUpdateChecksUseOptimizedSwiftProducts() throws {
    let build = try source(".github/workflows/build.yml")
    let package = try job("package", in: build)
    let updates = try job("updates", in: build)
    for section in [package, updates] { XCTAssertTrue(section.contains("./polka build")) }
    XCTAssertTrue(package.contains("./polka package --prebuilt --desktop"))
    XCTAssertTrue(updates.contains("./polka desktop updates --prebuilt --release"))
    XCTAssertTrue(package.contains("release/native-dev/*.zip"))
    XCTAssertTrue(package.contains("release/native-dev/*.dmg"))
    XCTAssertTrue(package.contains("if-no-files-found: error"))
    XCTAssertTrue(package.contains("Accessibility"))
  }
  func testPreparationSeparatesCachesAndKeepsReleaseSigningFresh() throws {
    let action = try source(".github/actions/prepare-macos/action.yml")
    let build = try source(".github/workflows/build.yml")
    let release = try source(".github/workflows/release.yml")
    XCTAssertTrue(action.contains("swift package --package-path native-app resolve"))
    for path in [
      "native-app/.build/checkouts", "native-app/.build/repositories",
      "native-app/.build/artifacts",
    ] { XCTAssertTrue(action.contains(path)) }
    XCTAssertTrue(action.contains("Package.resolved"))
    XCTAssertTrue(action.contains("toolchain.outputs.key"))
    XCTAssertTrue(action.contains("toolchain.outputs.build_key"))
    XCTAssertTrue(action.contains("default: ''"))
    XCTAssertTrue(action.contains("if: inputs.build-cache != ''"))
    XCTAssertTrue(action.contains("if: inputs.build-cache == ''"))
    XCTAssertTrue(action.contains("native-app/.build\n"))
    XCTAssertTrue(action.contains("path: tools/.build"))
    XCTAssertTrue(action.contains("swift-tools-v1-"))
    XCTAssertTrue(action.contains("swift-native-v1-"))
    XCTAssertTrue(action.contains("inputs.build-cache"))
    XCTAssertTrue(action.contains("xcrun --show-sdk-path; pwd -P"))
    XCTAssertTrue(try job("verify", in: build).contains("build-cache: source"))
    for name in ["package", "updates"] {
      XCTAssertTrue(try job(name, in: build).contains("build-cache: optimized"))
    }
    XCTAssertTrue(try job("verify", in: release).contains("build-cache: source"))
    for name in ["prepare", "updates", "build"] {
      XCTAssertTrue(try job(name, in: release).contains("build-cache: optimized"))
    }
    XCTAssertTrue(try job("prepare", in: release).contains("tools-only: 'true'"))
    XCTAssertTrue(action.contains("if: inputs.tools-only != 'true'"))
    XCTAssertTrue(action.contains("inputs.build-cache != '' && inputs.tools-only != 'true'"))
    XCTAssertTrue(action.contains("inputs.build-cache == '' && inputs.tools-only != 'true'"))
    XCTAssertFalse(action.contains("release/native"))
    XCTAssertTrue(action.contains("uname -m"))
    XCTAssertTrue(action.contains("-ge 27"))
  }
  func testReleaseJobsUseOneImmutableSourceAndProtectedSigning() throws {
    let release = try source(".github/workflows/release.yml")
    for name in ["verify", "updates", "build"] {
      let section = try job(name, in: release)
      XCTAssertTrue(section.contains("ref: ${{ needs.prepare.outputs.commit }}"))
      XCTAssertTrue(section.contains("uses: ./.github/actions/prepare-macos"))
      XCTAssertTrue(section.contains("needs: prepare"))
      XCTAssertFalse(section.contains("needs: verify"))
    }
    let build = try job("build", in: release)
    XCTAssertTrue(build.contains("./polka release --desktop"))
    XCTAssertFalse(build.contains("./polka release --prebuilt"))
    XCTAssertTrue(build.contains("environment: release"))
    XCTAssertTrue(build.contains("${{ secrets.POLKA_SIGNING_P12 }}"))
    XCTAssertTrue(build.contains("${{ secrets.SPARKLE_PRIVATE_KEY }}"))
    let publish = try job("publish", in: release)
    XCTAssertTrue(publish.contains("needs: [prepare, verify, updates, build]"))
    XCTAssertFalse(publish.contains("if: always()"))
    XCTAssertTrue(publish.contains("COMMIT: ${{ needs.prepare.outputs.commit }}"))
    let currentTag = try XCTUnwrap(
      publish.range(of: #"gh api "repos/$GITHUB_REPOSITORY/commits/$TAG" --jq '.sha'"#))
    let rejectChangedTag = try XCTUnwrap(
      publish.range(of: #"if [[ "$current_commit" != "$COMMIT" ]]; then"#))
    let firstUpload = try XCTUnwrap(publish.range(of: "gh release upload"))
    XCTAssertLessThan(currentTag.lowerBound, rejectChangedTag.lowerBound)
    XCTAssertLessThan(rejectChangedTag.lowerBound, firstUpload.lowerBound)
    XCTAssertTrue(publish[rejectChangedTag.upperBound..<firstUpload.lowerBound].contains("exit 1"))
  }
  func testReleaseUpdaterRunsSeparatelyFromSourceVerification() throws {
    let release = try source(".github/workflows/release.yml")
    let verify = try job("verify", in: release)
    XCTAssertTrue(verify.contains("./polka verify --no-desktop"))
    XCTAssertFalse(verify.contains("./polka build"))
    XCTAssertFalse(verify.contains("./polka desktop updates"))
    let updates = try job("updates", in: release)
    XCTAssertTrue(updates.contains("./polka build"))
    XCTAssertTrue(updates.contains("./polka desktop updates --prebuilt --release"))
    XCTAssertTrue(updates.contains("release-macos-arm64-update-diagnostics"))
    XCTAssertFalse(updates.contains("environment: release"))
    XCTAssertFalse(updates.contains("secrets."))
  }
  func testWorkflowsHaveNoNonSwiftApplicationOrToolchainFallbacks() throws {
    for path in [
      ".github/workflows/build.yml", ".github/workflows/release.yml",
      ".github/actions/prepare-macos/action.yml",
    ] {
      let contents = try source(path)
      XCTAssertNil(
        contents.range(
          of:
            #"(?i)electron|npm|node-version|setup-node|playwright|python|--javascript|migrate-self-signed|CSC_FOR_PULL_REQUEST|legacy release"#,
          options: .regularExpression), path)
    }
    XCTAssertTrue(
      try job("prepare", in: source(".github/workflows/release.yml")).contains(
        "./polka release-prepare"))
  }
}
