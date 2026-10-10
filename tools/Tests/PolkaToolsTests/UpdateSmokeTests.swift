import Foundation
import XCTest

@testable import PolkaTools

final class UpdateSmokeTests: XCTestCase {
  func testSyntheticHistoryEnvelopeMatchesExistingCrossImplementationVector() throws {
    let bytes = try UpdateSmoke.envelope(
      Data("{\"synthetic\":true}".utf8), password: Data("synthetic password".utf8))
    XCTAssertEqual(bytes.base64EncodedString(), "djEwJaPd3yw8w3RDXqGvgnlyb+hxG346d2cU1NsQutlCzws=")
    XCTAssertNotEqual(
      try UpdateSmoke.envelope(
        Data("{\"synthetic\":true}".utf8), password: Data("different password".utf8)), bytes)
  }
  func testReceiptValidationRejectsChangedContentAndWrongCollection() {
    let receipt: [String: Any] = [
      "clips": [["id": "one", "content": "synthetic"]],
      "snippets": [["id": "two", "content": "reply"]],
    ]
    XCTAssertTrue(
      UpdateSmoke.preserves(receipt, collection: "clips", id: "one", content: "synthetic"))
    XCTAssertFalse(
      UpdateSmoke.preserves(receipt, collection: "clips", id: "one", content: "changed"))
    XCTAssertFalse(
      UpdateSmoke.preserves(receipt, collection: "snippets", id: "one", content: "synthetic"))
    XCTAssertEqual(try UpdateSmoke.nextVersion("0.1.15"), "0.1.16")
    XCTAssertThrowsError(try UpdateSmoke.nextVersion("0.1"))
    XCTAssertThrowsError(try UpdateSmoke.nextVersion("0.1.15-beta"))
  }
  func testLocalFeedServerServesChangedFeedAndBinaryArchiveAndRecordsRequests() async throws {
    let server = try UpdateHTTPServer()
    defer { server.stop() }
    let bytes = Data([0, 128, 255, 10])
    server.set(feed: "first feed", archive: bytes)
    let (first, response) = try await URLSession.shared.data(
      from: URL(string: server.origin + "/appcast.xml")!)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(first, Data("first feed".utf8))
    server.set(feed: "authenticated feed", archive: bytes)
    let (second, _) = try await URLSession.shared.data(
      from: URL(string: server.origin + "/appcast.xml?no-cache")!)
    // The server implements the same exact routes as the prior localhost fixture.
    XCTAssertEqual(second, Data())
    let (feed, _) = try await URLSession.shared.data(
      from: URL(string: server.origin + "/appcast.xml")!)
    XCTAssertEqual(feed, Data("authenticated feed".utf8))
    let (archive, _) = try await URLSession.shared.data(
      from: URL(string: server.origin + "/fixture.zip")!)
    XCTAssertEqual(archive, bytes)
    XCTAssertEqual(
      server.requestLog.compactMap { $0["url"] as? String },
      ["/appcast.xml", "/appcast.xml?no-cache", "/appcast.xml", "/fixture.zip"])
  }
}
