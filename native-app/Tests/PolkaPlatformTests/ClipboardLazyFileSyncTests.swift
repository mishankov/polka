import Foundation
import PolkaCore
import XCTest

@testable import PolkaApp

final class ClipboardLazyFileSyncTests: XCTestCase {
  let codec = SyntheticEncryptionCodec(key: Data(repeating: 97, count: 32))
  func testMetadataFirstDownloadGroupOfflineRestartAndChangedOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func make(_ name: String) throws -> (ClipboardHistory, NativeClipboardSync) {
      let folder = root.appendingPathComponent(name)
      let history = ClipboardHistory(
        path: folder.appendingPathComponent("history.enc"), codec: codec)
      try history.initialize()
      return (
        history,
        NativeClipboardSync(
          path: folder.appendingPathComponent("sync.enc"), codec: codec,
          history: history, name: name, discovery: false)
      )
    }
    let (a, sa) = try make("A")
    let (b, sb) = try make("B")
    try await sa.initialize()
    try await sb.initialize()
    try await sa.setEnabled(true)
    try await sb.setEnabled(true)
    sa.discover(id: b.deviceId, name: "B", host: "127.0.0.1", port: sb.port)
    sb.discover(id: a.deviceId, name: "A", host: "127.0.0.1", port: sa.port)
    let sourceFolder = root.appendingPathComponent("Private source folder")
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    let pdf = sourceFolder.appendingPathComponent("Отчёт 3 MB.pdf")
    let second = sourceFolder.appendingPathComponent("Second.txt")
    let bytes = Data(repeating: 65, count: 3 * 1024 * 1024)
    try bytes.write(to: pdf)
    try Data("second".utf8).write(to: second)
    let files = try ClipboardFiles(urls: [pdf, second])
    try a.add(.files, content: files.content, preview: files.preview)
    let original = try XCTUnwrap(a.snapshot().clips.first)
    let source = try XCTUnwrap(original.fileSource)
    XCTAssertFalse(
      try a.manifest().available.contains(original.id), "Old peers must not see file records")
    XCTAssertTrue(try a.manifest(files: true).available.contains(original.id))
    try sa.invite()
    try await sb.pair(XCTUnwrap(sa.state().invitation?.code))
    for _ in 0..<3 {
      await sa.syncNow()
      await sb.syncNow()
    }
    let remote = try XCTUnwrap(b.find(original.id))
    XCTAssertEqual(remote.content, "")
    XCTAssertEqual(remote.fileSource, source)
    XCTAssertFalse(sb.fileCache.contains(source), "Metadata exchange must not download bytes")
    XCTAssertFalse(FileManager.default.fileExists(atPath: sb.fileCache.exports.path))
    let wire = try JSONEncoder().encode(XCTUnwrap(a.transfer(original.id, files: true)))
    XCTAssertLessThan(wire.count, 4096)
    XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("Private source folder"))

    let pasted = try await sb.filesForPaste(remote.id) { _ in }
    XCTAssertEqual(
      pasted.urls.map(\.lastPathComponent), [pdf.lastPathComponent, second.lastPathComponent])
    XCTAssertEqual(try Data(contentsOf: pasted.urls[0]), bytes)
    XCTAssertEqual(try Data(contentsOf: pasted.urls[1]), Data("second".utf8))
    XCTAssertTrue(sb.fileCache.contains(source))
    let encrypted = try Data(
      contentsOf: sb.fileCache.root.appendingPathComponent(source.key + ".enc"))
    XCTAssertNil(String(data: encrypted, encoding: .utf8))
    await sa.stop()
    let offline = try await sb.filesForPaste(remote.id) { _ in }
    XCTAssertEqual(try Data(contentsOf: offline.urls[0]), bytes)
    sb.fileCache.pruneExports(protecting: pasted.urls + offline.urls)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: pasted.urls[0].path),
      "Keep the current clipboard's files")
    await sb.stop()
    let (_, restarted) = try make("B")
    try await restarted.initialize()
    let afterRestart = try await restarted.filesForPaste(remote.id) { _ in }
    XCTAssertEqual(try Data(contentsOf: afterRestart.urls[0]), bytes)
    restarted.fileCache.discard(source)
    do {
      _ = try await restarted.filesForPaste(remote.id) { _ in }
      XCTFail("An uncached file must need the source Mac")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains(
          localized("The source Mac is unavailable. Connect it to the local network and try again.")
        ))
    }
    await restarted.stop()

    // Reopen both peers, then change the original after metadata was copied.
    var sourceSync = NativeClipboardSync(
      path: root.appendingPathComponent("A/sync.enc"), codec: codec, history: a, name: "A",
      discovery: false)
    let receiverSync = NativeClipboardSync(
      path: root.appendingPathComponent("B/sync.enc"), codec: codec, history: b, name: "B",
      discovery: false)
    try await sourceSync.initialize()
    try await receiverSync.initialize()
    receiverSync.discover(id: a.deviceId, name: "A", host: "127.0.0.1", port: sourceSync.port)
    sourceSync.discover(id: b.deviceId, name: "B", host: "127.0.0.1", port: receiverSync.port)
    try Data("changed".utf8).write(to: pdf)
    do {
      _ = try await receiverSync.filesForPaste(remote.id) { _ in }
      XCTFail("Changed bytes must never be silently substituted")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains(
          localized("The original file is unavailable or changed. Copy it again on the source Mac.")
        ))
    }
    XCTAssertFalse(receiverSync.fileCache.contains(source))
    // A stale discovered endpoint must produce an actionable download error.
    await sourceSync.stop()
    do {
      _ = try await receiverSync.filesForPaste(remote.id) { _ in }
      XCTFail("Offline source unexpectedly transferred bytes")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains(
          localized(
            "Could not download files from {0}. Check that it is online and sync is enabled.", "A"))
      )
    }
    sourceSync = NativeClipboardSync(
      path: root.appendingPathComponent("A/sync.enc"), codec: codec,
      history: a, name: "A", discovery: false)
    try await sourceSync.initialize()
    receiverSync.discover(id: a.deviceId, name: "A", host: "127.0.0.1", port: sourceSync.port)
    sourceSync.discover(id: b.deviceId, name: "B", host: "127.0.0.1", port: receiverSync.port)
    // A deleted source record can precede its tombstone arriving at the receiver.
    try a.remove(original.id)
    do {
      _ = try await receiverSync.filesForPaste(remote.id) { _ in }
      XCTFail("Deleted source record unexpectedly transferred bytes")
    } catch {
      // The tombstone may arrive before this user request starts.
      XCTAssertTrue(
        error is CancellationError
          || [
            localized("The original file is unavailable"),
            localized(
              "The original file is unavailable or changed. Copy it again on the source Mac."),
          ].contains(error.localizedDescription))
    }
    for _ in 0..<3 {
      await sourceSync.syncNow()
      await receiverSync.syncNow()
    }
    XCTAssertNil(b.find(original.id))
    await sourceSync.stop()
    await receiverSync.stop()
    try? FileManager.default.removeItem(at: sb.fileCache.exports)
  }

  func testMetadataRejectsUnsafeNamesAndPayloadSizes() throws {
    let device = UUID().uuidString.lowercased()
    for name in ["../escape", "/tmp/escape", "..", ".", "", "a\0b"] {
      XCTAssertThrowsError(
        try ClipboardFileSource(
          device: device,
          items: [.init(name: name, size: 1, version: String(repeating: "a", count: 64))]))
    }
    XCTAssertThrowsError(
      try ClipboardFileSource(
        device: device,
        items: [
          .init(name: "a.pdf", size: 17 * 1024 * 1024, version: String(repeating: "a", count: 64)),
          .init(name: "b.pdf", size: 17 * 1024 * 1024, version: String(repeating: "b", count: 64)),
        ]))
    let source = try ClipboardFileSource(
      device: device,
      items: [.init(name: "safe.pdf", size: 3, version: String(repeating: "a", count: 64))])
    XCTAssertThrowsError(try ClipboardFileBundle(source: source, contents: [Data([1])]))
    XCTAssertThrowsError(try ClipboardFileBundle(source: source, contents: []))
  }
}
