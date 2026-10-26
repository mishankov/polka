import Foundation
import XCTest

@testable import PolkaTools

final class NightlyFeedTests: XCTestCase {
  private static func appcast(_ version: String) -> Data {
    Data(
      """
      <?xml version="1.0" encoding="utf-8"?>
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><item><sparkle:version>\(version)</sparkle:version>
      <description>{"ru":"Изменения &amp; исправления", "en":"Changes &amp; fixes"}</description>
      <enclosure url="https://github.com/owner/polka/releases/download/v\(version)/polka.zip"
      sparkle:edSignature="unchanged-signature" length="123" /></item></channel></rss>
      """.utf8)
  }

  private final class GitHub {
    var candidate = "v0.8.0"
    var feeds = ["v0.8.0": appcast("0.8.0")]
    var currentExists: Bool
    var currentHasAsset = true
    var draftTag: String?
    var failedEndpoint: String?
    var failDownloads = false
    var mutations: [[String]] = []
    var uploaded: Data?

    init(current: String? = "0.7.0.20261010021700.123.1") {
      currentExists = current != nil
      if let current { feeds["nightly"] = appcast(current) }
    }

    func execute(_ arguments: [String]) throws -> Command.Result {
      func result(_ data: Data = Data(), status: Int32 = 0, error: String = "") -> Command.Result {
        Command.Result(status: status, stdout: data, stderr: Data(error.utf8))
      }
      if arguments[0] == "api" {
        let endpoint = arguments[1].components(separatedBy: "/releases/").last!
        if endpoint == failedEndpoint {
          return result(status: 1, error: "HTTP 403 / network error")
        }
        let tag = endpoint == "latest" ? "v0.8.0" : String(endpoint.dropFirst(5))
        if tag == "nightly" && !currentExists {
          return result(status: 1, error: "gh: Not Found (HTTP 404)")
        }
        let metadata: [String: Any] = [
          "tag_name": tag, "draft": tag == draftTag,
          "prerelease": tag == "nightly" || tag.contains("-"),
          "target_commitish": String(repeating: "a", count: 40),
          "assets": tag == "nightly" && !currentHasAsset ? [] : [["name": "appcast.xml"]],
        ]
        return result(try JSONSerialization.data(withJSONObject: metadata))
      }
      if arguments.starts(with: ["release", "download"]) {
        guard !failDownloads, let feed = feeds[arguments[2]] else {
          return result(status: 1, error: "Asset download failed")
        }
        return result(feed)
      }
      mutations.append(arguments)
      if arguments.starts(with: ["release", "upload"]) {
        uploaded = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
      }
      return result()
    }

    @discardableResult func publish() throws -> [UInt64]? {
      try NightlyFeedPublisher(execute: execute).publish(repository: "owner/polka", tag: candidate)
    }
  }

  func testStableReleaseReachesExistingNightlyClientsWithExactSignedFeed() throws {
    let github = GitHub()
    try github.publish()
    XCTAssertEqual(github.uploaded, github.feeds["v0.8.0"])
    XCTAssertEqual(github.mutations.last?[2], "nightly")
  }

  func testNewerNightlySurvivesStablePublicationOrRetry() throws {
    let github = GitHub(current: "0.8.0.20261026010101.999.2")
    try github.publish()
    XCTAssertEqual(github.uploaded, github.feeds["nightly"])
  }

  func testNightlyBuiltBeforeStablePublicationUsesLatestStable() throws {
    let github = GitHub()
    github.candidate = "v0.8.0-nightly.20261010021700.123.1"
    github.feeds[github.candidate] = Self.appcast("0.7.0.20261010021700.123.1")
    try github.publish()
    XCTAssertEqual(github.uploaded, github.feeds["v0.8.0"])
  }

  func testNewNightlyAdvancesStablePointer() throws {
    let github = GitHub(current: "0.8.0")
    github.candidate = "v0.8.1-nightly.20261026010101.1000.1"
    github.feeds[github.candidate] = Self.appcast("0.8.0.20261026010101.1000.1")
    try github.publish()
    XCTAssertEqual(github.uploaded, github.feeds[github.candidate])
  }

  func testOldWorkflowRetryCannotDowngradeCurrentPointer() throws {
    let github = GitHub(current: "0.8.0.20261026010101.1000.2")
    github.candidate = "v0.8.1-nightly.20261026010101.1000.1"
    github.feeds[github.candidate] = Self.appcast("0.8.0.20261026010101.1000.1")
    try github.publish()
    XCTAssertEqual(github.uploaded, github.feeds["nightly"])
  }

  func testFirstPublicationCreatesPointerWithoutChangingLatestStable() throws {
    let github = GitHub(current: nil)
    try github.publish()
    XCTAssertEqual(github.uploaded, github.feeds["v0.8.0"])
    XCTAssertTrue(try XCTUnwrap(github.mutations.first).contains("--latest=false"))
  }

  func testUnrelatedPrereleaseDoesNotEnterNightlyChannel() throws {
    let github = GitHub()
    github.candidate = "v0.9.0-beta.1"
    XCTAssertNil(try github.publish())
    XCTAssertTrue(github.mutations.isEmpty)
  }

  func testRetryRecoversPointerCreatedBeforeFailedFirstUpload() throws {
    let github = GitHub()
    github.currentHasAsset = false
    github.feeds["nightly"] = nil
    try github.publish()
    XCTAssertEqual(github.uploaded, github.feeds["v0.8.0"])
    XCTAssertFalse(github.mutations.contains { $0.starts(with: ["release", "create"]) })
  }

  func testInvalidRemoteFeedKeepsPreviousPointer() throws {
    for invalid in [
      Data("not xml".utf8), Self.appcast("0.8.0-beta"), Data("<!DOCTYPE rss><rss/>".utf8),
      Data(
        String(decoding: Self.appcast("0.8.0"), as: UTF8.self)
          .replacingOccurrences(of: "<item>", with: "<item/><item>").utf8),
    ] {
      let github = GitHub()
      github.feeds["v0.8.0"] = invalid
      XCTAssertThrowsError(try github.publish())
      XCTAssertTrue(github.mutations.isEmpty)
    }
  }

  func testDownloadAndAPIFailuresDoNotOverwritePreviousFeed() throws {
    for download in [false, true] {
      let github = GitHub()
      github.failDownloads = download
      github.failedEndpoint = download ? nil : "tags/nightly"
      XCTAssertThrowsError(try github.publish())
      XCTAssertTrue(github.mutations.isEmpty)
    }
  }

  func testDraftCannotBecomeAnUpdate() throws {
    for tag in ["v0.8.0", "nightly"] {
      let github = GitHub()
      github.draftTag = tag
      XCTAssertThrowsError(try github.publish())
      XCTAssertTrue(github.mutations.isEmpty)
    }
  }

  func testNumericOrderingUsesSparkleBuildVersion() throws {
    let versions = [
      "0.9.0", "0.9.0.20261026123456.99.1", "0.10.0", "0.10.0.20261026123456.100.1",
    ]
    let numeric = try versions.map { try ReleaseMetadata.appcastVersion(Self.appcast($0)) }
    for index in 1..<numeric.count {
      XCTAssertTrue(numeric[index - 1].lexicographicallyPrecedes(numeric[index]))
    }
    XCTAssertEqual(
      try ReleaseMetadata.appcastVersion(Self.appcast("1.0.0")),
      try ReleaseMetadata.appcastVersion(Self.appcast("1")))
    XCTAssertThrowsError(
      try ReleaseMetadata.appcastVersion(Self.appcast("1.18446744073709551616")))
  }

  func testWorkflowsSerializeSwiftFeedPublicationAfterArchivesAreUploaded() throws {
    for name in ["release", "nightly"] {
      let source = try String(
        contentsOf: TestSupport.root.appendingPathComponent(".github/workflows/\(name).yml"),
        encoding: .utf8)
      let publish = try XCTUnwrap(source.components(separatedBy: "\n  publish:\n").last)
      XCTAssertTrue(publish.contains("group: polka-update-feed"))
      XCTAssertTrue(publish.contains("runs-on: xcode-27"))
      XCTAssertTrue(publish.contains("tools-only: 'true'"))
      let upload = try XCTUnwrap(publish.range(of: "gh release upload"))
      let advance = try XCTUnwrap(publish.range(of: "./polka nightly-feed"))
      XCTAssertLessThan(upload.lowerBound, advance.lowerBound)
    }
    XCTAssertEqual(try ToolRequest(["nightly-feed"]).command, "nightly-feed")
  }
}
