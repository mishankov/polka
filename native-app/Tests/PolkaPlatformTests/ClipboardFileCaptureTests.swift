import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

final class ClipboardFileCaptureTests: XCTestCase {
  @MainActor func testFinderGroupCapturesAndReplaysNativeFileURLsWithoutReadingContents() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("Отчёт 3 MB.pdf")
    try Data(repeating: 32, count: 3 * 1024 * 1024).write(to: pdf)
    let folder = root.appendingPathComponent("Папка 👩🏽‍💻", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    defer { board.releaseGlobally() }
    XCTAssertTrue(board.writeObjects([pdf as NSURL, folder as NSURL]))
    let history = ClipboardHistory(
      path: root.appendingPathComponent("history.enc"),
      codec: SyntheticEncryptionCodec(key: Data(repeating: 1, count: 32)))
    try history.initialize()
    let capture = NativeClipboardCapture(history: history, fixture: true)
    defer { capture.stop() }
    let snapshot = try XCTUnwrap(NativeClipboardCapture.snapshot(from: board))
    XCTAssertEqual(snapshot.items.flatMap(\.fileURLs), [pdf, folder])
    try capture.capture(snapshot: snapshot)
    let clip = try XCTUnwrap(history.snapshot().clips.first)
    XCTAssertEqual(clip.kind, .files)
    let files = try ClipboardFiles(content: clip.content)
    XCTAssertEqual(files.urls, [pdf, folder])
    XCTAssertLessThan(clip.content.utf8.count, 2048)
    XCTAssertTrue(clip.preview.contains(pdf.lastPathComponent))
    try NativeClipboardCapture.write(files: files, to: board)
    XCTAssertEqual(board.readObjects(forClasses: [NSURL.self]) as? [URL], [pdf, folder])
    try capture.capture(snapshot: XCTUnwrap(NativeClipboardCapture.snapshot(from: board)))
    XCTAssertEqual(history.snapshot().clips.count, 1, "Replaying a group must not recapture it")

    board.clearContents()
    board.setString("Preserved clipboard", forType: .string)
    let count = board.changeCount
    try FileManager.default.removeItem(at: pdf)
    XCTAssertThrowsError(try NativeClipboardCapture.write(files: files, to: board))
    XCTAssertEqual(board.changeCount, count)
    XCTAssertEqual(board.string(forType: .string), "Preserved clipboard")
    XCTAssertEqual(history.find(clip.id), clip)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
  }

  @MainActor func testLegacyFileListSensitiveGroupPauseAndFileImagePriority() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = ClipboardHistory(
      path: root.appendingPathComponent("history.enc"),
      codec: SyntheticEncryptionCodec(key: Data(repeating: 1, count: 32)))
    try history.initialize()
    let capture = NativeClipboardCapture(history: history, fixture: true)
    defer { capture.stop() }
    let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    defer { board.releaseGlobally() }
    let urls = [URL(fileURLWithPath: "/tmp/one.pdf"), URL(fileURLWithPath: "/tmp/two.pdf")]
    board.setPropertyList(
      urls.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    let legacy = try XCTUnwrap(NativeClipboardCapture.snapshot(from: board))
    XCTAssertEqual(legacy.items.flatMap(\.fileURLs), urls)
    try capture.capture(snapshot: legacy)
    XCTAssertEqual(history.snapshot().clips.first?.kind, .files)
    try history.clear()
    var preferences = history.getPreferences()
    preferences.paused = true
    try history.setPreferences(preferences)
    try capture.capture(
      snapshot: NativeClipboardSnapshot(
        changeCount: 100, items: [NativeClipboardItem(types: ["public.file-url"], fileURLs: urls)]))
    XCTAssertTrue(history.snapshot().clips.isEmpty)
    preferences.paused = false
    try history.setPreferences(preferences)
    try capture.capture(
      snapshot: NativeClipboardSnapshot(
        changeCount: 101,
        items: [
          NativeClipboardItem(types: ["public.file-url"], fileURLs: urls),
          NativeClipboardItem(types: ["org.nspasteboard.ConcealedType"]),
        ]))
    XCTAssertTrue(history.snapshot().clips.isEmpty)
    try capture.capture(
      snapshot: NativeClipboardSnapshot(
        changeCount: 102,
        items: [
          NativeClipboardItem(
            types: ["public.file-url", "public.png", "text/plain"], text: "file path",
            images: ["public.png": Data()], fileURLs: urls)
        ]))
    XCTAssertEqual(history.snapshot().clips.count, 1)
    XCTAssertEqual(history.snapshot().clips.first?.kind, .files)
    XCTAssertThrowsError(
      try capture.capture(
        snapshot: NativeClipboardSnapshot(
          changeCount: 103,
          items: [
            NativeClipboardItem(
              types: ["public.file-url"], fileURLs: [URL(string: "https://example.com")!])
          ])))
  }
}
