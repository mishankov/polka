import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

private final class ClipboardFileDecodeGate: EncryptionCodec {
  let entered = XCTestExpectation(description: "File cache decoding started")
  private let codec = SyntheticEncryptionCodec(key: Data(repeating: 13, count: 32))
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var enabled = false
  func enable() {
    lock.lock()
    enabled = true
    lock.unlock()
  }
  func release() { semaphore.signal() }
  func encode(_ plaintext: Data) throws -> Data { try codec.encode(plaintext) }
  func decode(_ ciphertext: Data) throws -> Data {
    let data = try codec.decode(ciphertext)
    lock.lock()
    let block = enabled
    enabled = false
    lock.unlock()
    if block {
      entered.fulfill()
      guard semaphore.wait(timeout: .now() + 5) == .success else {
        throw CocoaError(.fileReadUnknown)
      }
    }
    return data
  }
}

final class NativePlatformIntegrationTests: XCTestCase {
  @MainActor func testLateFileDownloadCannotOverwriteClipboardAfterCancelCloseOrDeletion()
    async throws
  {
    for scenario in ["clipboard", "cancel", "close", "delete"] {
      let gate = ClipboardFileDecodeGate()
      defer { gate.release() }
      try await withPlatform(encryption: gate) { platform in
        let source = try ClipboardFileSource(
          device: UUID().uuidString.lowercased(),
          items: [
            .init(name: "Remote.pdf", size: 3, version: String(repeating: "a", count: 64))
          ])
        let id = clipId(.files, scenario)
        let stamp = Stamp(counter: 1, device: source.device)
        _ = try platform.history.mergeManifest(
          SyncManifest(
            files: true,
            entries: [
              id: SyncEntry(files: true, added: stamp)
            ], available: [id]))
        try platform.history.receive(
          ClipTransfer(
            clip: ClipboardClip(
              id: id, kind: .files, content: "", preview: "Remote.pdf",
              createdAt: Date().timeIntervalSince1970 * 1000, fileSource: source), stamp: stamp),
          sourceDevice: "Remote Mac")
        try platform.sync.fileCache.save(
          ClipboardFileBundle(source: source, contents: [Data([1, 2, 3])]))
        defer { try? FileManager.default.removeItem(at: platform.sync.fileCache.exports) }
        platform.refresh()
        platform.model.present(destination: "clipboard")
        platform.model.query = "remote"
        platform.capture.write(text: "Original clipboard")
        gate.enable()
        platform.model.chooseClip(try XCTUnwrap(platform.model.selectedClip), copyOnly: true)
        await fulfillment(of: [gate.entered], timeout: 2)
        switch scenario {
        case "clipboard": platform.capture.write(text: "New clipboard")
        case "cancel":
          XCTAssertTrue(
            platform.model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [])))
        case "close": platform.model.conceal()
        default: try platform.history.remove(id)
        }
        gate.release()
        for _ in 0..<500 where platform.model.commandPending {
          try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(platform.model.commandPending, scenario)
        XCTAssertEqual(
          platform.capture.syntheticText,
          scenario == "clipboard" ? "New clipboard" : "Original clipboard", scenario)
        XCTAssertTrue(platform.capture.syntheticFileURLs.isEmpty, scenario)
        if scenario == "clipboard" {
          XCTAssertTrue(
            platform.model.error.contains(
              localized("The clipboard changed during download. Select the file again to copy it."))
          )
        } else {
          XCTAssertTrue(platform.model.error.isEmpty, scenario)
        }
      }
    }
  }

  @MainActor func testCachedRemoteFilesUseTheSameKeyboardCopyAndPasteFlow() async throws {
    try await withPlatform { platform in
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: platform.sync.fileCache.exports)
      }
      let codec = SyntheticEncryptionCodec(key: Data(repeating: 7, count: 32))
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let sourceHistory = ClipboardHistory(
        path: root.appendingPathComponent("source.enc"), codec: codec)
      try sourceHistory.initialize()
      let pdf = root.appendingPathComponent("Remote Отчёт.pdf")
      let data = Data("%PDF synthetic remote data".utf8)
      try data.write(to: pdf)
      let refs = try ClipboardFiles(urls: [pdf])
      try sourceHistory.add(.files, content: refs.content, preview: refs.preview)
      let sourceClip = try XCTUnwrap(sourceHistory.snapshot().clips.first)
      let source = try XCTUnwrap(sourceClip.fileSource)
      _ = try platform.history.mergeManifest(sourceHistory.manifest(files: true))
      try platform.history.receive(
        XCTUnwrap(sourceHistory.transfer(sourceClip.id, files: true)), sourceDevice: "Source Mac")
      try platform.sync.fileCache.save(ClipboardFileBundle(source: source, contents: [data]))
      platform.refresh()
      let model = platform.model
      model.present(destination: "clipboard")
      model.query = "remote отчёт"
      let clip = try XCTUnwrap(model.selectedClip)
      XCTAssertTrue(clip.filesDownloaded)
      XCTAssertEqual(clip.content, "")
      XCTAssertTrue(
        model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: .shift)))
      for _ in 0..<200 where model.commandPending { try await Task.sleep(nanoseconds: 1_000_000) }
      XCTAssertFalse(model.commandPending)
      XCTAssertTrue(model.error.isEmpty)
      let urls = platform.capture.syntheticFileURLs
      XCTAssertEqual(urls.count, 1)
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), data)
      XCTAssertNil(model.fileDownloadProgress)
      model.present(destination: "clipboard")
      model.query = "remote отчёт"
      XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: [])))
      for _ in 0..<200 where model.commandPending { try await Task.sleep(nanoseconds: 1_000_000) }
      XCTAssertFalse(model.visible)
      XCTAssertEqual(
        try Data(contentsOf: XCTUnwrap(platform.capture.syntheticFileURLs.first)), data)
    }
  }

  @MainActor func testFileHistoryKeyboardPreviewCopySelectAndUnavailableOriginal() async throws {
    try await withPlatform { platform in
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("Отчёт.pdf")
      try Data("%PDF synthetic".utf8).write(to: url)
      let files = try ClipboardFiles(urls: [url])
      try platform.history.add(.files, content: files.content, preview: files.preview)
      platform.refresh()
      let model = platform.model
      model.present(destination: "clipboard")
      model.query = "отчёт"
      let filter = NativeKeyInput(
        code: 22, characters: "^", modifiers: [.command, .control], editing: true,
        searchEditing: true)
      var composing = filter
      composing.composing = true
      XCTAssertFalse(model.handleKeyboard(composing))
      XCTAssertEqual(model.clipboardFilter, .all)
      var repeated = filter
      repeated.repeatKey = true
      XCTAssertTrue(model.handleKeyboard(repeated))
      XCTAssertEqual(model.clipboardFilter, .all)
      XCTAssertTrue(model.handleKeyboard(filter))
      XCTAssertEqual(model.clipboardFilter, .files)
      let clip = try XCTUnwrap(model.selectedClip)
      XCTAssertEqual(clip.kind, "files")
      XCTAssertTrue(model.previewActions(for: clip).isEmpty)
      XCTAssertEqual(nativeClipboardSnippet(clip, query: "отчёт"), "Отчёт.pdf")
      XCTAssertTrue(
        model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: .command)))
      XCTAssertEqual(model.previewID, clip.id)
      XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [])))
      XCTAssertNil(model.previewID)
      let original = platform.history.snapshot()
      model.busy = true
      XCTAssertTrue(
        model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: .shift)))
      XCTAssertTrue(platform.capture.syntheticFileURLs.isEmpty)
      model.busy = false
      XCTAssertTrue(
        model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: .shift)))
      for _ in 0..<30 where model.commandPending { await Task.yield() }
      XCTAssertEqual(platform.capture.syntheticFileURLs, [url])
      XCTAssertTrue(excludedClipboardType(platform.capture.syntheticTypes))
      XCTAssertEqual(platform.history.snapshot(), original)
      model.present(destination: "clipboard")
      model.query = "отчёт"
      XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: [])))
      for _ in 0..<30 where model.commandPending { await Task.yield() }
      XCTAssertEqual(platform.capture.syntheticFileURLs, [url])
      XCTAssertFalse(model.visible)
      platform.capture.write(text: "Clipboard sentinel")
      try FileManager.default.removeItem(at: url)
      model.present(destination: "clipboard")
      model.query = "отчёт"
      model.chooseClip(clip, copyOnly: true)
      for _ in 0..<30 where model.commandPending { await Task.yield() }
      XCTAssertTrue(model.visible)
      XCTAssertTrue(model.error.contains(url.lastPathComponent))
      XCTAssertEqual(platform.capture.syntheticText, "Clipboard sentinel")
      XCTAssertEqual(platform.history.snapshot(), original)
    }
  }

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
        localized("The folder no longer exists. Choose another folder.")))
    XCTAssertTrue(
      nativeImageSaveError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        .contains(localized("No access to the file. Choose another folder or name.")))
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    XCTAssertTrue(
      nativeImageSaveError(
        NSError(
          domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
          userInfo: [NSUnderlyingErrorKey: underlying])
      ).contains(localized("There is no free disk space.")))
    XCTAssertTrue(
      nativeImageSaveError(NSError(domain: "other", code: 123)).contains(
        localized("Choose another folder and try again.")))
  }
  @MainActor private func withPlatform(
    encryption: EncryptionCodec? = nil, _ body: (NativePlatform) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-native-ui-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try NativePlatform(
      model: NativeUIModel(), root: root, fixture: true, encryption: encryption)
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
      platform.model.query = "64^8"
      XCTAssertEqual(platform.model.searchResults.first?.title, "281 474 976 710 656")
      for key in [
        NativeKeyInput(code: 18, characters: "1", modifiers: .command),
        NativeKeyInput(code: 36, characters: "\r", modifiers: []),
      ] {
        platform.capture.write(text: "Before calculation")
        XCTAssertTrue(platform.model.handleKeyboard(key))
        for _ in 0..<500 where platform.model.commandPending {
          try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(platform.model.commandPending)
        XCTAssertTrue(platform.model.visible)
        XCTAssertEqual(platform.model.query, "64^8")
        XCTAssertEqual(platform.capture.syntheticText, "281474976710656")
      }
      do {
        try await platform.handle(
          NativeUICommand(
            "clipboardHistory.select", strings: ["id": clip.id, "transformation": "invalid"]))
        XCTFail("Unknown text transformation must fail")
      } catch {}
      XCTAssertEqual(platform.capture.syntheticText, "281474976710656")
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
