import Foundation
import XCTest

@testable import PolkaCore

final class ClipboardFilesTests: XCTestCase {
  func testUnicodePathsRoundTripAndInvalidReferencesAreRejected() throws {
    let urls = [URL(fileURLWithPath: "/tmp/Отчёт 👩🏽‍💻 #1.pdf"), URL(fileURLWithPath: "/tmp/a\nb")]
    let files = try ClipboardFiles(urls: urls)
    XCTAssertEqual(try ClipboardFiles(content: files.content).urls, urls)
    XCTAssertTrue(files.preview.contains(urls[0].lastPathComponent))
    for content in [
      "[]", "{}", "null", "[\"https://example.com/file.pdf\"]", "[\"relative.pdf\"]",
      "[\"file://remote.example/tmp/a\"]", "[\"file:///tmp/a?query=1\"]",
      "[\"file:///tmp/a%00b\"]", String(repeating: "x", count: 1024 * 1024 + 1),
    ] { XCTAssertThrowsError(try ClipboardFiles(content: content), content.prefix(80).description) }
    XCTAssertThrowsError(try ClipboardFiles(urls: Array(repeating: urls[0], count: 1001)))
  }

  func testReferencesPersistDeduplicateExpireAndStayOutOfSync() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codec = SyntheticEncryptionCodec(key: Data(repeating: 31, count: 32))
    var now = 1_800_000_000_000.0
    let path = root.appendingPathComponent("history.enc")
    let history = ClipboardHistory(path: path, codec: codec, now: { now })
    try history.initialize()
    let files = try ClipboardFiles(urls: [URL(fileURLWithPath: "/tmp/Отчёт 3 MB.pdf")])
    let id = clipId(.files, history.deviceId + "\0" + files.content)
    let manifest = try history.manifest()
    try history.add(.files, content: files.content, preview: files.preview)
    try history.pin(id, pinned: true)
    now += 1
    try history.add(.files, content: files.content, preview: files.preview)
    XCTAssertEqual(history.snapshot().clips.count, 1)
    XCTAssertTrue(try XCTUnwrap(history.find(id)).pinned)
    XCTAssertEqual(try history.manifest(), manifest)
    XCTAssertNil(history.transfer(id))
    XCTAssertEqual(
      clipboardResults(history.snapshot().clips, query: "отчёт pdf", filter: .files).map(\.id), [id]
    )
    XCTAssertTrue(clipboardResults(history.snapshot().clips, query: "", filter: .text).isEmpty)
    XCTAssertThrowsError(try history.edit(id, content: "snippet"))
    XCTAssertThrowsError(try history.add(.files, content: "[]", preview: "Invalid"))
    let reopened = ClipboardHistory(path: path, codec: codec, now: { now })
    try reopened.initialize()
    XCTAssertEqual(reopened.snapshot(), history.snapshot())
    XCTAssertLessThan(try Data(contentsOf: path).count, 4096)

    let peer = ClipboardHistory(
      path: root.appendingPathComponent("peer.enc"), codec: codec, now: { now })
    try peer.initialize()
    try peer.add(.text, content: "Remote text", preview: "Remote text")
    for needed in try reopened.mergeManifest(peer.manifest()) {
      try reopened.receive(try XCTUnwrap(peer.transfer(needed)), sourceDevice: "Peer")
    }
    XCTAssertEqual(reopened.find(id)?.pinned, true)
    try peer.clear()
    _ = try reopened.mergeManifest(peer.manifest())
    XCTAssertNotNil(reopened.find(id), "A remote clear must not remove local references")
    XCTAssertThrowsError(
      try peer.receive(
        ClipTransfer(
          clip: XCTUnwrap(history.find(id)), stamp: Stamp(counter: 1, device: history.deviceId)),
        sourceDevice: "Other"))
    now += 8 * 86_400_000
    try reopened.prune()
    XCTAssertNotNil(reopened.find(id))
    try reopened.pin(id, pinned: false)
    XCTAssertNil(reopened.find(id))
    try reopened.add(.files, content: files.content, preview: files.preview)
    try reopened.remove(id)
    XCTAssertNil(reopened.find(id))
    XCTAssertFalse(try reopened.manifest().entries.keys.contains(id))
    try reopened.add(.files, content: files.content, preview: files.preview)
    try reopened.clear()
    XCTAssertTrue(reopened.snapshot().clips.isEmpty)
  }
}
