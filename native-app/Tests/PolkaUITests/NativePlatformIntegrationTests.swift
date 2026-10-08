import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativePlatformIntegrationTests: XCTestCase {
  @MainActor func testPendingEncryptionDoesNotBlockEscapeOrQuitAndCannotWriteAfterShutdown()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-native-pending-encryption-\(UUID().uuidString)")
    let codec = GatedSyntheticEncryptionCodec()
    defer {
      codec.release()
      try? FileManager.default.removeItem(at: root)
    }
    let platform = try NativePlatform(
      model: NativeUIModel(), root: root, fixture: true, encryption: codec)
    await platform.initialize()
    await fulfillment(of: [codec.entered], timeout: 1)
    XCTAssertTrue(
      codec.waiting, "The synthetic encryption operation must still be pending while UI work runs")

    let closed = XCTestExpectation(
      description: "Escape command runs on the main actor while encryption waits")
    platform.hide = { [weak platform] _ in
      platform?.model.conceal()
      closed.fulfill()
    }
    platform.model.present(destination: "apps")
    XCTAssertTrue(
      platform.model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [])))
    await fulfillment(of: [closed], timeout: 1)
    XCTAssertFalse(platform.model.visible)
    XCTAssertTrue(codec.waiting)
    XCTAssertEqual(platform.history.storage.state().status, .starting)
    XCTAssertTrue(platform.history.snapshot().clips.isEmpty)
    XCTAssertTrue(codec.waiting, "Reading history must not wait on the background encryption gate")
    let stores = ["clipboard-history/history.enc", "clipboard-history/sync.enc"].map {
      root.appendingPathComponent($0)
    }
    for file in stores { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }

    await platform.shutdown()
    XCTAssertTrue(
      codec.waiting, "Shutdown must finish without waiting for a Keychain-like operation")
    codec.release()
    await platform.waitForInitialization()
    XCTAssertFalse(codec.waiting)
    XCTAssertFalse(codec.timedOut)
    XCTAssertEqual(platform.history.storage.state().status, .starting)
    XCTAssertTrue(platform.history.snapshot().clips.isEmpty)
    for file in stores {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: file.path),
        "Canceled initialization must not create encrypted stores after quit")
    }
  }
  func testImageSaveFailuresExplainRecoveryWithoutFilesystemSideEffects() {
    XCTAssertTrue(
      nativeImageSaveError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))).contains(
        "Папка больше не существует"))
    XCTAssertTrue(
      nativeImageSaveError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        .contains("Нет доступа к файлу"))
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    XCTAssertTrue(
      nativeImageSaveError(
        NSError(
          domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
          userInfo: [NSUnderlyingErrorKey: underlying])
      ).contains("нет свободного места"))
    XCTAssertTrue(
      nativeImageSaveError(NSError(domain: "other", code: 123)).contains(
        "Выберите другую папку и попробуйте ещё раз"))
  }
  @MainActor private func withPlatform(_ body: (NativePlatform) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-native-ui-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    try platform.history.initialize()
    platform.capture.stop()
    platform.show = { [weak platform] destination, query in
      platform?.model.present(destination: destination ?? "apps", searchQuery: query)
    }
    platform.hide = { [weak platform] _ in platform?.model.conceal() }
    platform.refresh()
    do {
      try await body(platform)
      await platform.shutdown()
    } catch {
      await platform.shutdown()
      throw error
    }
  }
  @MainActor func testCreateFromHistoryNavigatesToSnippetEditorEvenDuringBusyCommand() async throws
  {
    try await withPlatform { platform in
      try platform.history.add(.text, content: "Исходная запись", preview: "Исходная запись")
      platform.refresh()
      platform.model.present(destination: "clipboard")
      let clip = try XCTUnwrap(platform.model.clips.first)
      platform.model.edit(clip)
      XCTAssertTrue(platform.model.busy)
      for _ in 0..<20 where platform.model.busy { await Task.yield() }
      XCTAssertEqual(platform.model.destination, "snippets")
      XCTAssertEqual(platform.model.draft?.content, clip.content)
      XCTAssertEqual(platform.model.draft?.id, "")
      platform.model.saveSnippet()
      for _ in 0..<20 where platform.model.busy { await Task.yield() }
      XCTAssertNil(platform.model.draft)
      XCTAssertEqual(platform.history.snapshot().snippets.first?.content, clip.content)
      XCTAssertEqual(platform.history.find(clip.id)?.content, clip.content)
    }
  }
  @MainActor func testUnnamedSnippetCanBeEditedAndConcurrentChangesPreserveDraft() async throws {
    try await withPlatform { platform in
      let id = try platform.history.createSnippet(content: "first")
      platform.refresh()
      platform.model.present(destination: "snippets")
      platform.model.edit(try XCTUnwrap(platform.model.snippets.first))
      platform.model.draft?.content = "edited"
      platform.model.saveSnippet()
      for _ in 0..<20 where platform.model.busy { await Task.yield() }
      XCTAssertEqual(platform.history.find(id)?.content, "edited")
      XCTAssertNil(platform.model.draft)
      platform.model.edit(try XCTUnwrap(platform.model.snippets.first))
      platform.model.draft?.content = "local unsaved"
      _ = try platform.history.edit(
        id, content: "remote edit", expected: SnippetExpected(content: "edited"))
      platform.model.saveSnippet()
      for _ in 0..<20 where platform.model.busy { await Task.yield() }
      XCTAssertEqual(platform.history.find(id)?.content, "remote edit")
      XCTAssertEqual(platform.model.draft?.content, "local unsaved")
      XCTAssertFalse(platform.model.error.isEmpty)
    }
  }
  @MainActor func testStaleOCRIsRedactedFromBothProjectionAndLauncherSearch() async throws {
    try await withPlatform { platform in
      let content = Data("synthetic image".utf8).base64EncodedString()
      try platform.history.add(
        .image, content: content, preview: "data:image/png;base64," + content)
      let image = try XCTUnwrap(platform.history.imageTextImages().first)
      try platform.history.saveImageText(
        image.id, incarnation: image.incarnation,
        result: ImageText(
          version: "old-system", status: .ready, text: "staleocrneedle", languages: ["ru-RU"]))
      platform.refresh()
      XCTAssertEqual(platform.model.clips.first?.ocrText, "")
      XCTAssertFalse(
        platform.model.searchProvider?("staleocrneedle").contains(where: { $0.kind == "clip" })
          ?? true)
      do {
        try await platform.handle(
          NativeUICommand("clipboardHistory.copyImageText", strings: ["id": image.id]))
        XCTFail("Stale OCR must not be copied")
      } catch {}
      XCTAssertEqual(platform.capture.syntheticText, "")
      try platform.history.saveImageText(
        image.id, incarnation: image.incarnation,
        result: ImageText(
          version: platform.capture.ocrVersion, status: .ready, text: "currentocrneedle",
          languages: ["ru-RU"]))
      platform.refresh()
      XCTAssertTrue(
        platform.model.searchProvider?("currentocrneedle").contains(where: { $0.kind == "clip" })
          ?? false)
      try await platform.handle(
        NativeUICommand("clipboardHistory.copyImageText", strings: ["id": image.id]))
      XCTAssertEqual(platform.capture.syntheticText, "currentocrneedle")
    }
  }
  @MainActor func testResumedImagePreviewReloadUsesDiscoverableKeyboardAction() async throws {
    try await withPlatform { platform in
      let bitmap = try XCTUnwrap(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4,
          bitsPerPixel: 32))
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try platform.history.add(
        .image, content: data.base64EncodedString(),
        preview: "data:image/png;base64," + data.base64EncodedString())
      platform.refresh()
      platform.model.present(destination: "clipboard")
      platform.model.openPreview(try XCTUnwrap(platform.model.clips.first))
      for _ in 0..<20 where platform.model.busy { await Task.yield() }
      XCTAssertNotNil(platform.model.previewImage)
      platform.model.conceal()
      platform.model.present(destination: "clipboard", resume: true)
      XCTAssertNotNil(platform.model.previewID)
      XCTAssertNil(platform.model.previewImage)
      XCTAssertTrue(
        platform.model.handleKeyboard(
          NativeKeyInput(code: 15, characters: "к", modifiers: .command)))
      for _ in 0..<20 where platform.model.busy { await Task.yield() }
      XCTAssertNotNil(platform.model.previewImage)
      XCTAssertTrue(platform.model.error.isEmpty)
    }
  }
  @MainActor func testCopyTransformationAndNamedSearchContextKeepSource() async throws {
    try await withPlatform { platform in
      let text =
        String(repeating: "before ", count: 40) + "needle context "
        + String(repeating: "after ", count: 20)
      let id = try platform.history.createSnippet(content: text, name: "Template")
      platform.refresh()
      let result = try XCTUnwrap(
        platform.model.searchProvider?("needle").first(where: { $0.clipID == id }))
      XCTAssertEqual(result.title, "Template")
      XCTAssertTrue(result.detail.contains("needle"))
      XCTAssertTrue(result.detail.hasPrefix("…"))
      XCTAssertEqual(result.icon, "")
      try await platform.handle(
        NativeUICommand(
          "clipboardHistory.copy", strings: ["id": id, "transformation": "upperCase"]))
      XCTAssertEqual(platform.capture.syntheticText, text.uppercased())
      XCTAssertEqual(platform.history.find(id)?.content, text)
    }
  }
  @MainActor func testClipboardCopyClosesButCalculatorCopyKeepsShelfOpen() async throws {
    try await withPlatform { platform in
      try platform.history.add(.text, content: "Copy this", preview: "Copy this")
      platform.refresh()
      platform.model.present(destination: "clipboard")
      let clip = try XCTUnwrap(platform.model.clips.first)
      try await platform.handle(NativeUICommand("clipboardHistory.copy", strings: ["id": clip.id]))
      XCTAssertFalse(platform.model.visible)
      XCTAssertEqual(platform.capture.syntheticText, clip.content)
      XCTAssertTrue(platform.capture.syntheticTypes.contains("org.nspasteboard.AutoGeneratedType"))
      platform.model.present(destination: "apps")
      try await platform.handle(
        NativeUICommand("shelf.copyCalculation", strings: ["expression": "2 + 3"]))
      XCTAssertTrue(platform.model.visible)
      XCTAssertEqual(platform.capture.syntheticText, "5")
      do {
        try await platform.handle(
          NativeUICommand(
            "clipboardHistory.select", strings: ["id": clip.id, "transformation": "invalid"]))
        XCTFail("Unknown text transformation must fail")
      } catch {}
      XCTAssertEqual(platform.capture.syntheticText, "5")
    }
  }
  @MainActor func testFixtureShortcutChangesPersistWithoutRegisteringSystemBindings() async throws {
    try await withPlatform { platform in
      try await platform.handle(
        NativeUICommand("launcher.setShortcut", strings: ["accelerator": "CommandOrControl+Alt+P"]))
      XCTAssertEqual(
        try platform.settings.get(key: "launcherShortcut") as? String, "CommandOrControl+Alt+P")
      try await platform.handle(
        NativeUICommand(
          "clipboardHistory.shortcut", strings: ["accelerator": "CommandOrControl+Alt+V"]))
      XCTAssertEqual(platform.history.getPreferences().accelerator, "CommandOrControl+Alt+V")
      do {
        try await platform.handle(
          NativeUICommand(
            "clipboardHistory.shortcut", strings: ["accelerator": "CommandOrControl+Alt+P"]))
        XCTFail("Conflicting shortcut should fail")
      } catch {}
      XCTAssertEqual(platform.history.getPreferences().accelerator, "CommandOrControl+Alt+V")
      try await platform.handle(
        NativeUICommand("launcher.setShortcut", strings: ["accelerator": "CommandOrControl+Alt+P"]))
    }
  }
  @MainActor func testCopiedTimeConversionUsesDateShownBeforeClockAnchorChanges() async throws {
    try await withPlatform { platform in
      let formatter = ISO8601DateFormatter()
      platform.anchorCalculationDate(try XCTUnwrap(formatter.date(from: "2026-07-15T12:00:00Z")))
      let row = try XCTUnwrap(
        platform.model.searchProvider?("18:00 Moscow in London").first(where: {
          $0.kind == "calculation"
        }))
      XCTAssertEqual(row.sourceDate, "2026-07-15")
      platform.anchorCalculationDate(try XCTUnwrap(formatter.date(from: "2026-07-16T12:00:00Z")))
      try await platform.handle(
        NativeUICommand(
          "shelf.copyCalculation",
          strings: ["expression": row.expression, "sourceDate": row.sourceDate]))
      XCTAssertTrue(platform.capture.syntheticText.contains("2026-07-15"))
      XCTAssertFalse(platform.capture.syntheticText.contains("2026-07-16"))
    }
  }
}

/// Blocks only the synthetic codec worker, with a deadline so a regression fails
/// instead of hanging the suite. No Keychain, system clipboard, or native app is used.
private final class GatedSyntheticEncryptionCodec: EncryptionCodec, @unchecked Sendable {
  let entered = XCTestExpectation(description: "Background encryption preflight entered")
  private let codec = SyntheticEncryptionCodec(key: Data(repeating: 0x45, count: 32))
  private let condition = NSCondition()
  private var started = false
  private var released = false
  private var exited = false
  private var timeout = false
  var waiting: Bool {
    condition.lock()
    defer { condition.unlock() }
    return started && !released && !exited
  }
  var timedOut: Bool {
    condition.lock()
    defer { condition.unlock() }
    return timeout
  }
  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
  func encode(_ plaintext: Data) throws -> Data {
    condition.lock()
    if !started {
      started = true
      entered.fulfill()
    }
    let deadline = Date().addingTimeInterval(10)
    while !released {
      if !condition.wait(until: deadline) {
        timeout = true
        break
      }
    }
    exited = true
    let failed = timeout
    condition.unlock()
    if failed { throw NSError(domain: "PolkaSyntheticEncryptionGate", code: 1) }
    return try codec.encode(plaintext)
  }
  func decode(_ ciphertext: Data) throws -> Data { try codec.decode(ciphertext) }
}
