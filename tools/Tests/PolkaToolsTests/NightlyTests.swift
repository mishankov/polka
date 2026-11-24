import CryptoKit
import Foundation
import XCTest

@testable import PolkaTools

final class NightlyTests: XCTestCase {
  func testUniqueVersionsTargetNextStablePatch() throws {
    let date = Date(timeIntervalSince1970: 1_791_589_020)
    let version = try NightlyPreparation.version(
      base: "0.1.15", date: date, runID: "123", attempt: "1")
    XCTAssertTrue(version.hasPrefix("0.1.16-nightly."))
    XCTAssertTrue(version.hasSuffix(".123.1"))
    XCTAssertEqual(try ReleaseVersion.parse("v" + version), version)
    XCTAssertNotEqual(
      version,
      try NightlyPreparation.version(base: "0.1.15", date: date, runID: "123", attempt: "2"))
    for base in ["0.1.15-beta.1", "0.1.15+meta", "0.1", "0.1.9223372036854775807"] {
      XCTAssertThrowsError(
        try NightlyPreparation.version(base: base, date: date, runID: "123", attempt: "1"))
    }
    for value in ["0", "-1", "1\n", "", "1/2"] {
      XCTAssertThrowsError(
        try NightlyPreparation.version(base: "0.1.15", date: date, runID: value, attempt: "1"))
      XCTAssertThrowsError(
        try NightlyPreparation.version(base: "0.1.15", date: date, runID: "123", attempt: value))
    }
  }
  func testNightlySourceAndNotesArePinnedAndStableTagsCannotCrossChannels() throws {
    let root = try Files.temporary("polka-nightly-tests")
    defer { try? FileManager.default.removeItem(at: root) }
    try Command.run("git", ["init", "--quiet", root.path])
    try Command.run(
      "git",
      [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit",
        "--allow-empty", "--quiet", "-m", "fixture",
      ], directory: root)
    try JSONEncoder().encode(PolkaMetadata(version: "0.1.15")).write(
      to: root.appendingPathComponent("polka.json"))
    let output = root.appendingPathComponent("output")
    try Data("existing=value\n".utf8).write(to: output)
    let env = [
      "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": output.path,
      "NIGHTLY_BASE_VERSION": "v0.9.0",
    ]
    try NightlyPreparation.run(context: ToolContext(root: root, environment: env))
    let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines[0], "existing=value")
    let tag = String(lines[1].dropFirst(4))
    // Published releases can be ahead of the development version in polka.json.
    // The nightly must remain between that stable release and its next patch.
    XCTAssertTrue(tag.hasPrefix("v0.9.1-nightly."))
    XCTAssertTrue(try ReleaseVersion.buildVersion(tag).hasPrefix("0.9.0."))
    let commit = String(lines[2].dropFirst(7))
    var nightly = ["RELEASE_CHANNEL": "nightly", "RELEASE_TAG": tag, "RELEASE_COMMIT": commit]
    let metadata = try ReleaseTool.resolved(PolkaMetadata(version: "0.1.15"), environment: nightly)
      .metadata
    let notes = try ReleaseTool.notes(
      metadata: metadata, context: ToolContext(root: root, environment: nightly))
    XCTAssertTrue(notes.en.contains(commit))
    XCTAssertTrue(notes.ru.contains(commit))
    XCTAssertThrowsError(try ReleaseTool.resolved(metadata, environment: ["RELEASE_TAG": tag]))
    XCTAssertThrowsError(
      try ReleaseTool.resolved(
        metadata, environment: ["RELEASE_CHANNEL": "nightly", "RELEASE_TAG": "v0.1.16"]))
    nightly["RELEASE_COMMIT"] = String(repeating: "a", count: 40)
    XCTAssertThrowsError(
      try ReleaseTool.notes(
        metadata: metadata, context: ToolContext(root: root, environment: nightly)))
    nightly["RELEASE_COMMIT"] = "invalid"
    XCTAssertThrowsError(
      try ReleaseTool.notes(
        metadata: metadata, context: ToolContext(root: root, environment: nightly)))
    XCTAssertThrowsError(
      try NightlyPreparation.run(
        context: ToolContext(
          root: root, environment: ["GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"])))
    var invalidBase = env
    invalidBase["NIGHTLY_BASE_VERSION"] = ""
    XCTAssertThrowsError(
      try NightlyPreparation.run(context: ToolContext(root: root, environment: invalidBase)))
  }
  func testSignedNightlyFeedReferencesImmutableVersionedArchive() throws {
    let metadata = PolkaMetadata(version: "0.1.16-nightly.20261010021700.123.1")
    let key = Curve25519.Signing.PrivateKey()
    let bytes = Data("nightly archive".utf8)
    let root = try Files.temporary("polka-nightly-appcast")
    defer { try? FileManager.default.removeItem(at: root) }
    let names = try ReleaseMetadata.artifactNames(metadata: metadata)
    for name in names { try bytes.write(to: root.appendingPathComponent(name)) }
    let xml = try ReleaseMetadata.appcast(
      metadata: metadata, repository: "owner/app",
      signature: key.signature(for: bytes).base64EncodedString(), size: bytes.count)
    try Data(xml.utf8).write(to: root.appendingPathComponent("appcast.xml"))
    XCTAssertTrue(xml.contains("<sparkle:version>0.1.15.20261010021700.123.1</sparkle:version>"))
    XCTAssertTrue(
      xml.contains("<sparkle:shortVersionString>\(metadata.version)</sparkle:shortVersionString>"))
    XCTAssertTrue(xml.contains("/releases/download/v\(metadata.version)/"))
    XCTAssertFalse(xml.contains("/download/nightly/"))
    XCTAssertEqual(
      try ReleaseMetadata.verify(
        metadata: metadata, directory: root, repository: "owner/app",
        publicKey: key.publicKey.rawRepresentation.base64EncodedString()), names)
  }

  private func runNightlyPrepareScript(
    repo: URL, environment: [String: String]
  ) throws -> Command.Result {
    try Command.execute(
      "/bin/bash",
      [TestSupport.root.appendingPathComponent("scripts/nightly-prepare.sh").path],
      environment: environment, directory: repo)
  }

  private func parseOutputs(_ file: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
    }
    return result
  }

  func testNightlyPrepareScriptMatchesSwiftValidationAndDetectsVerifiedCI() throws {
    let root = try Files.temporary("polka-nightly-prepare-script")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    let bin = root.appendingPathComponent("bin")
    try Files.mkdir(repo)
    try Files.mkdir(bin)
    try Command.run("git", ["init", "--quiet"], directory: repo)
    try Command.run(
      "git",
      [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit",
        "--allow-empty", "--quiet", "-m", "fixture",
      ], directory: repo)
    let commit = try Command.capture("git", ["rev-parse", "HEAD"], directory: repo)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let tree = try Command.capture("git", ["rev-parse", "HEAD^{tree}"], directory: repo)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let prHead = String(repeating: "b", count: 40)

    let fakeGH = bin.appendingPathComponent("gh")
    let ghScript = """
      #!/bin/bash
      set -euo pipefail
      mode="${FAKE_GH_MODE:-none}"
      if [[ "$1" != "api" ]]; then exit 1; fi
      shift
      while [[ "${1:-}" == --* ]]; do
        if [[ "$1" == "--jq" ]]; then shift 2; else shift; fi
      done
      endpoint="$1"
      case "$mode:$endpoint" in
        direct:repos/owner/polka/actions/workflows/build.yml/runs?head_sha=\(commit)*)
          echo '{"workflow_runs":[{"id":101,"conclusion":"success","event":"push"}]}' ;;
        direct_pr_event:repos/owner/polka/actions/workflows/build.yml/runs?head_sha=\(commit)*)
          echo '{"workflow_runs":[{"id":101,"conclusion":"success","event":"pull_request"}]}' ;;
        pr_match:repos/owner/polka/actions/workflows/build.yml/runs?head_sha=\(commit)*)
          echo '{"workflow_runs":[]}' ;;
        pr_match:repos/owner/polka/commits/\(commit)/pulls*)
          echo '[{"merged_at":"2026-11-24T14:17:42Z","merge_commit_sha":"\(commit)","base":{"repo":{"full_name":"owner/polka"}},"head":{"sha":"\(prHead)"}}]' ;;
        pr_match:repos/owner/polka/actions/workflows/build.yml/runs?head_sha=\(prHead)*)
          echo '{"workflow_runs":[{"id":101,"conclusion":"success","event":"pull_request"}]}' ;;
        pr_match:repos/owner/polka/check-runs/5001/annotations)
          echo '[[{"title":"verified-source-tree","message":"\(tree)"}]]' ;;
        pr_tree_mismatch:repos/owner/polka/actions/workflows/build.yml/runs?head_sha=\(commit)*)
          echo '{"workflow_runs":[]}' ;;
        pr_tree_mismatch:repos/owner/polka/commits/\(commit)/pulls*)
          echo '[{"merged_at":"2026-11-24T14:17:42Z","merge_commit_sha":"\(commit)","base":{"repo":{"full_name":"owner/polka"}},"head":{"sha":"\(prHead)"}}]' ;;
        pr_tree_mismatch:repos/owner/polka/actions/workflows/build.yml/runs?head_sha=\(prHead)*)
          echo '{"workflow_runs":[{"id":101,"conclusion":"success","event":"pull_request"}]}' ;;
        pr_tree_mismatch:repos/owner/polka/check-runs/5001/annotations)
          echo '[[{"title":"verified-source-tree","message":"\(String(repeating: "c", count: 40))"}]]' ;;
        pr_no_annotation:repos/owner/polka/actions/workflows/build.yml/runs?head_sha=\(commit)*)
          echo '{"workflow_runs":[]}' ;;
        pr_no_annotation:repos/owner/polka/commits/\(commit)/pulls*)
          echo '[{"merged_at":"2026-11-24T14:17:42Z","merge_commit_sha":"\(commit)","base":{"repo":{"full_name":"owner/polka"}},"head":{"sha":"\(prHead)"}}]' ;;
        pr_no_annotation:repos/owner/polka/actions/workflows/build.yml/runs?head_sha=\(prHead)*)
          echo '{"workflow_runs":[{"id":101,"conclusion":"success","event":"pull_request"}]}' ;;
        pr_no_annotation:repos/owner/polka/check-runs/5001/annotations)
          echo '[[]]' ;;
        incomplete:repos/owner/polka/actions/workflows/build.yml/runs?head_sha=\(commit)*)
          echo '{"workflow_runs":[{"id":102,"conclusion":"success","event":"push"}]}' ;;
        *:repos/owner/polka/actions/runs/101/jobs)
          echo '[{"jobs":[{"id":4001,"name":"Verify native macOS source","status":"completed","conclusion":"success"},{"id":4002,"name":"Verify Swift tooling","status":"completed","conclusion":"success"},{"id":4003,"name":"Package and test native macOS arm64","status":"completed","conclusion":"success"},{"id":5001,"name":"Verify and package macOS arm64","status":"completed","conclusion":"success"}]}]' ;;
        *:repos/owner/polka/actions/runs/102/jobs)
          echo '[{"jobs":[{"id":4001,"name":"Verify native macOS source","status":"completed","conclusion":"success"},{"id":4002,"name":"Verify Swift tooling","status":"completed","conclusion":"success"},{"id":4003,"name":"Package and test native macOS arm64","status":"completed","conclusion":"failure"}]}]' ;;
        direct:repos/owner/polka/check-runs/5001/annotations)
          echo '[[{"title":"verified-source-tree","message":"\(tree)"}]]' ;;
        error:*)
          exit 1 ;;
        *)
          echo '{}' ;;
      esac
      """
    try TestSupport.write(ghScript, to: fakeGH, executable: true)

    func baseEnv(_ output: URL, mode: String) -> [String: String] {
      var env = ProcessInfo.processInfo.environment
      env["PATH"] = bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
      env["NIGHTLY_BASE_VERSION"] = "v0.12.1"
      env["NIGHTLY_TIMESTAMP"] = "20261124143524"
      env["GITHUB_RUN_ID"] = "45412541492"
      env["GITHUB_RUN_ATTEMPT"] = "2"
      env["GITHUB_REPOSITORY"] = "owner/polka"
      env["GITHUB_OUTPUT"] = output.path
      env["FAKE_GH_MODE"] = mode
      return env
    }

    for (mode, expectedVerified) in [
      ("direct", "true"),
      ("direct_pr_event", "false"),
      ("pr_match", "true"),
      ("pr_tree_mismatch", "false"),
      ("pr_no_annotation", "false"),
      ("incomplete", "false"),
      ("error", "false"),
    ] {
      let output = root.appendingPathComponent("out-\(mode)")
      try Data().write(to: output)
      let result = try runNightlyPrepareScript(repo: repo, environment: baseEnv(output, mode: mode))
      XCTAssertEqual(result.status, 0, "\(mode): \(result.error)")
      let values = try parseOutputs(output)
      XCTAssertEqual(values["tag"], "v0.12.2-nightly.20261124143524.45412541492.2")
      XCTAssertEqual(values["commit"], commit)
      XCTAssertEqual(values["verified_by_ci"], expectedVerified, mode)
    }

    let forcedOutput = root.appendingPathComponent("out-forced")
    try Data().write(to: forcedOutput)
    var forcedEnv = baseEnv(forcedOutput, mode: "direct")
    forcedEnv["FORCE_FULL_VERIFICATION"] = "true"
    XCTAssertEqual(try runNightlyPrepareScript(repo: repo, environment: forcedEnv).status, 0)
    XCTAssertEqual(try parseOutputs(forcedOutput)["verified_by_ci"], "false")

    for invalidBase in [
      "", "0.1.15-beta.1", "0.1.15+meta", "0.1", "0.1.9223372036854775807", "0.1.01",
    ] {
      let output = root.appendingPathComponent("out-invalid")
      try Data().write(to: output)
      var env = baseEnv(output, mode: "none")
      env["NIGHTLY_BASE_VERSION"] = invalidBase
      XCTAssertNotEqual(
        try runNightlyPrepareScript(repo: repo, environment: env).status, 0, invalidBase)
    }
    for invalidID in ["", "0", "-1", "1/2"] {
      let output = root.appendingPathComponent("out-invalid-id")
      try Data().write(to: output)
      var env = baseEnv(output, mode: "none")
      env["GITHUB_RUN_ID"] = invalidID
      XCTAssertNotEqual(
        try runNightlyPrepareScript(repo: repo, environment: env).status, 0, invalidID)
    }
  }

  func testNightlyWorkflowUsesLinuxPrepareSharedCachesAndFailClosedPublishGate() throws {
    let nightly = try String(
      contentsOf: TestSupport.root.appendingPathComponent(".github/workflows/nightly.yml"),
      encoding: .utf8)
    func job(_ name: String) throws -> String {
      let marker = "\n  \(name):\n"
      let start = try XCTUnwrap(nightly.range(of: marker)).upperBound
      let tail = nightly[start...]
      let end =
        tail.range(of: #"\n  [A-Za-z][A-Za-z0-9_-]*:\n"#, options: .regularExpression)?.lowerBound
        ?? nightly.endIndex
      return String(nightly[start..<end])
    }
    let prepare = try job("prepare")
    XCTAssertTrue(prepare.contains("runs-on: ubuntu-latest"))
    XCTAssertTrue(prepare.contains("bash scripts/nightly-prepare.sh"))
    XCTAssertTrue(prepare.contains("verified_by_ci:"))
    for name in ["verify", "tooling", "updates"] {
      let section = try job(name)
      XCTAssertTrue(section.contains("if: needs.prepare.outputs.verified_by_ci != 'true'"), name)
      XCTAssertTrue(section.contains("tools-configuration: debug"), name)
      XCTAssertTrue(section.contains("save-tools-cache: 'false'"), name)
    }
    XCTAssertTrue(try job("verify").contains("save-native-cache: 'false'"))
    let updates = try job("updates")
    XCTAssertTrue(updates.contains("build-cache: optimized-native"))
    XCTAssertTrue(updates.contains("save-native-cache: 'false'"))
    let build = try job("build")
    XCTAssertTrue(build.contains("build-cache: optimized-native"))
    XCTAssertTrue(build.contains("tools-configuration: debug"))
    XCTAssertTrue(build.contains("save-tools-cache: 'false'"))
    XCTAssertTrue(build.contains("save-native-cache: 'false'"))
    XCTAssertFalse(build.contains("if: needs.prepare.outputs.verified_by_ci"))
    XCTAssertTrue(build.contains("./polka release --desktop"))
    let publish = try job("publish")
    XCTAssertTrue(publish.contains("save-tools-cache: 'false'"))
    XCTAssertTrue(publish.contains("needs: [prepare, verify, tooling, updates, build]"))
    XCTAssertTrue(publish.contains("!failure() && !cancelled()"))
    XCTAssertTrue(publish.contains("needs.build.result == 'success'"))
    XCTAssertTrue(publish.contains("needs.prepare.outputs.verified_by_ci == 'true'"))
  }
}
