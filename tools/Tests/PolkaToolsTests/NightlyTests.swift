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
    let env = ["GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": output.path]
    try NightlyPreparation.run(context: ToolContext(root: root, environment: env))
    let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines[0], "existing=value")
    let tag = String(lines[1].dropFirst(4))
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
}
