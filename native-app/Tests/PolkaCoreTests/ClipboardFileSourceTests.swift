import Foundation
import XCTest

@testable import PolkaCore

final class ClipboardFileSourceTests: XCTestCase {
  func testRegularFilesShareMetadataWhileFoldersSymlinksAndOversizedGroupsStayLocal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let codec = SyntheticEncryptionCodec(key: Data(repeating: 1, count: 32))
    let a = ClipboardHistory(path: root.appendingPathComponent("a.enc"), codec: codec)
    let b = ClipboardHistory(path: root.appendingPathComponent("b.enc"), codec: codec)
    try a.initialize()
    try b.initialize()
    let file = root.appendingPathComponent("Empty.txt")
    try Data().write(to: file)
    let refs = try ClipboardFiles(urls: [file])
    try a.add(.files, content: refs.content, preview: refs.preview)
    try b.add(.files, content: refs.content, preview: refs.preview)
    let local = try XCTUnwrap(a.snapshot().clips.first)
    XCTAssertNotEqual(
      local.id, b.snapshot().clips.first?.id,
      "The same path on different Macs identifies different files")
    let source = try XCTUnwrap(local.fileSource)
    XCTAssertEqual(source.byteCount, 0)
    XCTAssertEqual(try source.read(refs), [Data()])
    XCTAssertFalse(try a.manifest().entries.keys.contains(local.id))
    XCTAssertTrue(try a.manifest(files: true).entries.keys.contains(local.id))
    XCTAssertNil(a.transfer(local.id))
    let transfer = try XCTUnwrap(a.transfer(local.id, files: true))
    XCTAssertEqual(transfer.clip.content, "")
    _ = try b.mergeManifest(a.manifest(files: true))
    try b.receive(transfer, sourceDevice: "A")
    XCTAssertEqual(b.find(local.id)?.content, "")
    XCTAssertEqual(
      clipboardResults(b.snapshot().clips, query: "empty.txt", filter: .files).count, 2)
    // A round trip of portable metadata must retain A's own local references.
    try b.pin(local.id, pinned: true)
    _ = try a.mergeManifest(b.manifest(files: true))
    XCTAssertEqual(a.find(local.id)?.content, refs.content)
    XCTAssertTrue(try XCTUnwrap(a.find(local.id)).pinned)

    let folder = root.appendingPathComponent("Folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let large = root.appendingPathComponent("Large.dat")
    try Data().write(to: large)
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(ClipboardFileSource.maximumBytes + 1))
    try handle.close()
    for url in [folder, link, large] {
      let refs = try ClipboardFiles(urls: [url])
      XCTAssertThrowsError(try ClipboardFileSource.inspect(refs, device: a.deviceId))
      try a.add(.files, content: refs.content, preview: refs.preview)
      XCTAssertNil(a.find(clipId(.files, a.deviceId + "\0" + refs.content))?.fileSource)
    }
  }

  func testVersionChecksAndBundleIntegrityRejectReplacementsAndCorruptBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Report.pdf")
    try Data([1, 2, 3]).write(to: file)
    let refs = try ClipboardFiles(urls: [file])
    let source = try ClipboardFileSource.inspect(refs, device: UUID().uuidString.lowercased())
    var bundle = try ClipboardFileBundle(source: source, contents: [Data([1, 2, 3])])
    bundle.contents[0] = Data([4, 5, 6])
    XCTAssertThrowsError(try bundle.validate())
    try Data([7, 8, 9]).write(to: file)
    XCTAssertThrowsError(try source.read(refs), "Same-size replacements must be detected")
    try FileManager.default.removeItem(at: file)
    XCTAssertThrowsError(try source.read(refs))
  }
}
