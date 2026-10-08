import AppKit
import Darwin
import Foundation
import PolkaCore
import XCTest

@testable import PolkaApp

final class ClipboardCaptureTests: XCTestCase {
  var roots: [URL] = []
  override func tearDown() {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
  }
  func history() throws -> ClipboardHistory {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PolkaCaptureTests-\(UUID().uuidString)")
    roots.append(root)
    let history = ClipboardHistory(
      path: root.appendingPathComponent("history.enc"),
      codec: SyntheticEncryptionCodec(key: Data(repeating: 31, count: 32)))
    try history.initialize()
    return history
  }
  func image(_ format: NSBitmapImageRep.FileType = .png) throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 500, height: 400, bitsPerComponent: 8, bytesPerRow: 2000,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 500, height: 400))
    return try XCTUnwrap(
      NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(
        using: format, properties: [:]))
  }
  @MainActor func testPrivatePasteboardImageOnlyAndNativeImagePriority() throws {
    let board = NSPasteboard(name: NSPasteboard.Name("PolkaCaptureTests-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let history = try history()
    let capture = NativeClipboardCapture(history: history, fixture: true)
    let jpeg = try image(.jpeg)
    let item = NSPasteboardItem()
    XCTAssertTrue(item.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg")))
    XCTAssertTrue(board.writeObjects([item]))
    let snapshot = try XCTUnwrap(NativeClipboardCapture.snapshot(from: board))
    XCTAssertNil(snapshot.items.first?.text)
    XCTAssertEqual(snapshot.items.first?.images["public.jpeg"], jpeg)
    try capture.capture(snapshot: snapshot)
    XCTAssertEqual(history.snapshot().clips.first?.kind, .image)
    XCTAssertTrue(
      try XCTUnwrap(Data(base64Encoded: XCTUnwrap(history.snapshot().clips.first?.content)))
        .starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))

    board.clearContents()
    let both = NSPasteboardItem()
    let png = try image()
    XCTAssertTrue(both.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg")))
    XCTAssertTrue(both.setData(png, forType: .png))
    XCTAssertTrue(both.setString("Image alternative", forType: .string))
    XCTAssertTrue(board.writeObjects([both]))
    let preferred = try XCTUnwrap(NativeClipboardCapture.snapshot(from: board))
    XCTAssertEqual(preferred.items.first?.images, ["public.png": png])
    try capture.capture(snapshot: preferred)
    XCTAssertNotNil(history.find(clipId(.image, png.base64EncodedString())))
    XCTAssertNil(history.find(clipId(.text, "Image alternative")))
  }
  @MainActor func testPrivatePasteboardValidTextRepresentationsAndUTF8Priority() throws {
    let board = NSPasteboard(name: NSPasteboard.Name("PolkaCaptureTests-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let history = try history()
    let capture = NativeClipboardCapture(history: history, fixture: true)
    let utf16 = NSPasteboard.PasteboardType("public.utf16-plain-text")
    for (type, text) in [
      (NSPasteboard.PasteboardType.string, "UTF8 Русский 🐈"),
      (utf16, "UTF16 日本語 🐈"),
      (NSPasteboard.PasteboardType("public.utf16-external-plain-text"), "External UTF16 🐈"),
      (NSPasteboard.PasteboardType("public.plain-text"), "Plain text"),
    ] {
      board.clearContents()
      let item = NSPasteboardItem()
      if type == utf16 || type.rawValue == "public.utf16-external-plain-text" {
        XCTAssertTrue(item.setData(try XCTUnwrap(text.data(using: .utf16)), forType: type))
      } else {
        XCTAssertTrue(item.setString(text, forType: type))
      }
      XCTAssertTrue(board.writeObjects([item]))
      let snapshot = try XCTUnwrap(NativeClipboardCapture.snapshot(from: board))
      XCTAssertEqual(snapshot.items.first?.text, text)
      XCTAssertEqual(snapshot.items.first?.images, [:])
      try capture.capture(snapshot: snapshot)
      XCTAssertNotNil(history.find(clipId(.text, text)))
    }
    board.clearContents()
    let item = NSPasteboardItem()
    XCTAssertTrue(item.setString("Preferred UTF8", forType: .string))
    XCTAssertTrue(
      item.setData(try XCTUnwrap("UTF16 fallback".data(using: .utf16)), forType: utf16))
    XCTAssertTrue(board.writeObjects([item]))
    XCTAssertEqual(
      NativeClipboardCapture.snapshot(from: board)?.items.first?.text, "Preferred UTF8")
  }
  @MainActor func testPrivatePasteboardSensitiveItemExcludesEveryRepresentation() throws {
    let board = NSPasteboard(name: NSPasteboard.Name("PolkaCaptureTests-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let history = try history()
    let capture = NativeClipboardCapture(history: history, fixture: true)
    let publicItem = NSPasteboardItem()
    XCTAssertTrue(publicItem.setString("Must remain private", forType: .string))
    XCTAssertTrue(publicItem.setData(try image(), forType: .png))
    let concealed = NSPasteboardItem()
    XCTAssertTrue(
      concealed.setData(
        Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
    XCTAssertTrue(board.writeObjects([publicItem, concealed]))
    let snapshot = try XCTUnwrap(NativeClipboardCapture.snapshot(from: board))
    XCTAssertTrue(snapshot.items.allSatisfy { $0.text == nil && $0.images.isEmpty })
    try capture.capture(snapshot: snapshot)
    XCTAssertTrue(history.snapshot().clips.isEmpty)
  }
  @MainActor func testSyntheticInitialCaptureSensitiveSnapshotFileOnlyAndUTF8Limit() throws {
    let history = try history()
    let capture = NativeClipboardCapture(history: history, fixture: true)
    let text = NativeClipboardItem(
      types: ["public.utf8-plain-text"], text: "Synthetic initial text")
    try capture.capture(snapshot: NativeClipboardSnapshot(changeCount: 0, items: [text]))
    XCTAssertEqual(history.snapshot().clips.count, 1)
    try capture.capture(snapshot: NativeClipboardSnapshot(changeCount: 0, items: [text]))
    XCTAssertEqual(history.snapshot().clips.count, 1)
    try capture.capture(
      snapshot: NativeClipboardSnapshot(
        changeCount: 1,
        items: [
          NativeClipboardItem(types: ["text/plain"], text: "must not capture"),
          NativeClipboardItem(types: ["org.nspasteboard.ConcealedType"]),
        ]))
    XCTAssertNil(history.find(clipId(.text, "must not capture")))
    try capture.capture(
      snapshot: NativeClipboardSnapshot(
        changeCount: 2,
        items: [
          NativeClipboardItem(types: ["public.file-url", "text/plain"], text: "file://synthetic")
        ]))
    XCTAssertEqual(history.snapshot().clips.count, 1)
    XCTAssertThrowsError(
      try capture.capture(
        snapshot: NativeClipboardSnapshot(
          changeCount: 3,
          items: [
            NativeClipboardItem(types: ["text/plain"], text: String(repeating: "я", count: 600_000))
          ])))
    XCTAssertTrue(history.storage.ready)
    capture.stop()
  }
  @MainActor func testGeneratedWritesMarkSensitiveWithoutSystemClipboard() throws {
    let capture = NativeClipboardCapture(history: try history(), fixture: true)
    capture.write(text: "Synthetic calculation")
    XCTAssertEqual(capture.syntheticText, "Synthetic calculation")
    XCTAssertTrue(excludedClipboardType(capture.syntheticTypes))
    XCTAssertTrue(capture.syntheticTypes.contains("org.nspasteboard.AutoGeneratedType"))
    capture.write(text: "Synthetic pairing code", concealed: true)
    XCTAssertTrue(capture.syntheticTypes.contains("org.nspasteboard.ConcealedType"))
    capture.write(image: try image())
    XCTAssertTrue(capture.syntheticTypes.contains("public.png"))
    XCTAssertTrue(capture.syntheticTypes.contains("org.nspasteboard.AutoGeneratedType"))
  }
  @MainActor func testPNGIdentityImagePriorityAndThumbnailAspectAndJPEGConversion() throws {
    let history = try history()
    let capture = NativeClipboardCapture(history: history, fixture: true)
    let png = try image()
    try capture.capture(
      snapshot: NativeClipboardSnapshot(
        changeCount: 0,
        items: [
          NativeClipboardItem(
            types: ["public.file-url", "public.png", "text/plain"], text: "fallback",
            images: ["public.png": png])
        ]))
    let clip = try XCTUnwrap(history.snapshot().clips.first)
    XCTAssertEqual(clip.kind, .image)
    XCTAssertEqual(clip.content, png.base64EncodedString())
    let thumbnail = try XCTUnwrap(
      NSBitmapImageRep(
        data: XCTUnwrap(
          Data(
            base64Encoded: clip.preview.replacingOccurrences(of: "data:image/png;base64,", with: "")
          ))))
    XCTAssertEqual(thumbnail.pixelsWide, 125)
    XCTAssertEqual(thumbnail.pixelsHigh, 100)
    let jpeg = try image(.jpeg)
    try capture.capture(
      snapshot: NativeClipboardSnapshot(
        changeCount: 1,
        items: [NativeClipboardItem(types: ["public.jpeg"], images: ["public.jpeg": jpeg])]))
    XCTAssertEqual(history.snapshot().clips.count, 2)
    XCTAssertTrue(
      history.snapshot().clips.allSatisfy {
        Data(base64Encoded: $0.content)?.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10])
      })
    capture.stop()
  }
  @MainActor func testOCRCancellationDoesNotCacheFailureOrOverlapWorkers() async throws {
    let history = try history()
    var calls = 0
    var active = 0
    var maximum = 0
    let capture = NativeClipboardCapture(
      history: history, fixture: true,
      recognize: { _ in
        calls += 1
        active += 1
        maximum = max(maximum, active)
        defer { active -= 1 }
        if calls == 1 { try await Task.sleep(nanoseconds: 5_000_000_000) }
        return Data("{\"text\":\" Recognized synthetic text \",\"languages\":[\"en-US\"]}".utf8)
      })
    let png = try image()
    try history.add(
      .image, content: png.base64EncodedString(),
      preview: "data:image/png;base64," + png.base64EncodedString())
    let id = try XCTUnwrap(history.snapshot().clips.first?.id)
    capture.indexImages()
    await Task.yield()
    XCTAssertEqual(active, 1)
    try history.remove(id)
    capture.indexImages()
    try history.add(
      .image, content: png.base64EncodedString(),
      preview: "data:image/png;base64," + png.base64EncodedString())
    capture.indexImages()
    for _ in 0..<100 {
      if history.find(id)?.ocr != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(history.find(id)?.ocr?.status, .ready)
    XCTAssertEqual(history.find(id)?.ocr?.text, "Recognized synthetic text")
    XCTAssertEqual(maximum, 1)
    XCTAssertEqual(active, 0)
    capture.stop()
    await capture.waitForStop()
  }
  @MainActor func testOCRShutdownReapsActualNativeCommandBeforeReturning() async throws {
    let history = try history()
    let pidPath = try XCTUnwrap(roots.last).appendingPathComponent("ocr-pid")
    let script =
      "import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(60)"
    let capture = NativeClipboardCapture(
      history: history, fixture: true,
      recognize: { data in
        try await NativeCommand.run(
          URL(fileURLWithPath: "/usr/bin/env"),
          arguments: ["python3", "-u", "-c", script, pidPath.path], stdin: data, timeout: 30)
      })
    let png = try image()
    try history.add(
      .image, content: png.base64EncodedString(),
      preview: "data:image/png;base64," + png.base64EncodedString())
    capture.indexImages()
    var pid: Int32?
    for _ in 0..<100 {
      pid = (try? String(contentsOf: pidPath, encoding: .utf8)).flatMap(Int32.init)
      if pid != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let child = try XCTUnwrap(pid)
    capture.stop()
    await capture.waitForStop()
    XCTAssertEqual(kill(child, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    XCTAssertNil(history.snapshot().clips.first?.ocr)
  }
  @MainActor func testStoppedCapturePreservesHistoryAndIgnoresFutureSnapshots() async throws {
    let history = try history()
    let capture = NativeClipboardCapture(history: history, fixture: true)
    capture.stop()
    await capture.waitForStop()
    try capture.capture(
      snapshot: NativeClipboardSnapshot(
        changeCount: 1, items: [NativeClipboardItem(types: ["text/plain"], text: "Stopped")]))
    XCTAssertTrue(history.snapshot().clips.isEmpty)
  }
}
