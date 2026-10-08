import Sparkle
import XCTest

@testable import PolkaApp

@MainActor final class UpdateTests: XCTestCase {
  private func ready(
    _ service: NativeUpdates, version: String = "0.2.0",
    reply: @escaping (SPUUserUpdateChoice) -> Void = { _ in }
  ) {
    service.receiveAvailable(version: version)
    service.receiveReady(version: version, reply: reply)
  }
  private func rejects(
    _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await body()
      XCTFail("Expected operation rejection", file: file, line: line)
    } catch {}
  }
  func testDownloadProgressAndExplicitInstallFlush() async throws {
    let service = NativeUpdates(enabled: true, checkAction: {})
    var states: [String] = []
    var replies: [SPUUserUpdateChoice] = []
    var saved = false
    service.changed = { states.append(service.status + ":" + String(Int(service.progress))) }
    service.beforeInstall = { saved = true }
    await rejects { try await service.install() }
    try service.check()
    XCTAssertEqual(service.status, "checking")
    service.receiveAvailable(
      version: "0.2.0", releaseNotes: ["ru": "Новая полка", "en": "A new shelf"])
    service.showDownloadInitiated(cancellation: {})
    service.showDownloadDidReceiveExpectedContentLength(100)
    service.showDownloadDidReceiveData(ofLength: 42)
    XCTAssertEqual(service.progress, 42)
    XCTAssertThrowsError(try service.check())
    service.showDownloadDidStartExtractingUpdate()
    service.showExtractionReceivedProgress(0.1)
    XCTAssertEqual(service.progress, 100, "Extraction never moves the download progress backwards")
    service.receiveReady(version: "0.2.0") { choice in
      XCTAssertTrue(saved)
      replies.append(choice)
    }
    XCTAssertEqual(service.status, "ready")
    XCTAssertTrue(replies.isEmpty)
    XCTAssertTrue(service.notes.contains("Новая полка"))
    XCTAssertTrue(states.contains("downloading:42"))
    try await service.install()
    XCTAssertEqual(replies, [.install])
    XCTAssertEqual(service.status, "installing")
    service.cancelForQuit(explicitUpdate: true)
    XCTAssertEqual(service.status, "installing")
  }
  func testLocalBuildNeverChecksOrInstalls() async {
    var checked = false
    let service = NativeUpdates(checkAction: { checked = true })
    XCTAssertEqual(service.status, "unavailable")
    XCTAssertThrowsError(try service.check())
    await rejects { try await service.install() }
    await rejects { try await service.skip() }
    XCTAssertFalse(checked)
    service.receiveAvailable(version: "0.2.0")
    XCTAssertTrue(service.version.isEmpty)
  }
  func testFailedFlushRestoresInteractionAndRetainsReadyReply() async throws {
    let service = NativeUpdates(enabled: true)
    var disabled = false
    var replies: [SPUUserUpdateChoice] = []
    ready(service) { replies.append($0) }
    service.beforeInstall = {
      disabled = true
      throw CocoaError(.fileWriteOutOfSpace)
    }
    service.restoreAfterInstallFailure = { disabled = false }
    try await service.install()
    XCTAssertFalse(disabled)
    XCTAssertTrue(replies.isEmpty)
    XCTAssertEqual(service.status, "ready")
    XCTAssertTrue(service.message.contains("сохранить историю"))
    service.beforeInstall = {}
    try await service.install()
    XCTAssertEqual(replies, [.install])
  }
  func testNativeStagingFailureRestoresAppAndHidesCredentials() async throws {
    var disabled = false
    let service = NativeUpdates(
      enabled: true,
      checkAction: { throw NSError(domain: "https://secret:token@example.com", code: 1) })
    try service.check()
    XCTAssertEqual(service.status, "error")
    XCTAssertFalse(service.message.contains("token"))
    ready(service)
    service.beforeInstall = { disabled = true }
    service.restoreAfterInstallFailure = { disabled = false }
    try await service.install()
    XCTAssertTrue(disabled)
    service.showUpdaterError(NSError(domain: "signed url secret", code: 1), acknowledgement: {})
    XCTAssertFalse(disabled)
    XCTAssertEqual(service.status, "error")
    XCTAssertFalse(service.message.contains("secret"))
    try service.check()
    service.receiveCurrent()
    XCTAssertEqual(service.status, "current")
    XCTAssertTrue(service.version.isEmpty)
  }
  func testOrdinaryQuitCancelsStagingAndLateFlushCannotInstall() async throws {
    let service = NativeUpdates(enabled: true)
    var replies: [SPUUserUpdateChoice] = []
    ready(service) { replies.append($0) }
    service.beforeInstall = { service.cancelForQuit() }
    try await service.install()
    XCTAssertEqual(replies, [.skip])
    XCTAssertEqual(service.status, "idle")
    var cancelled = false
    service.receiveAvailable(version: "0.3.0")
    service.showDownloadInitiated(cancellation: { cancelled = true })
    service.cancelForQuit()
    XCTAssertTrue(cancelled)
    XCTAssertTrue(service.version.isEmpty)
  }
  func testSkipAndReminderPersistAndReplaceEachOther() async throws {
    var now = 1000.0
    var saved: [String: Any] = [:]
    let service = NativeUpdates(enabled: true, now: { now }, savePreferences: { saved = $0 })
    ready(service)
    try await service.skip()
    XCTAssertEqual(service.notification, "skipped")
    let restarted = NativeUpdates(enabled: true, preferences: saved, now: { now })
    ready(restarted)
    XCTAssertEqual(restarted.notification, "skipped")
    try await service.remind()
    XCTAssertEqual(service.notification, "deferred")
    XCTAssertEqual(service.remindAfter, now + NativeUpdates.reminderDelay)
    XCTAssertNil(saved["skippedVersion"])
    let reminded = NativeUpdates(enabled: true, preferences: saved, now: { now })
    ready(reminded)
    XCTAssertEqual(reminded.notification, "deferred")
    now += NativeUpdates.reminderDelay - 1
    XCTAssertEqual(reminded.notification, "deferred")
    now += 1
    reminded.reminderExpired()
    XCTAssertEqual(reminded.notification, "visible")
    XCTAssertEqual(reminded.remindAfter, 0)
    try await service.skip()
    XCTAssertNil(saved["reminder"])
    service.receiveError()
    service.receiveAvailable(version: "0.3.0")
    XCTAssertEqual(service.notification, "visible")
    service.cancelForQuit()
    reminded.cancelForQuit()
    restarted.cancelForQuit()
  }
  func testStaleChoiceAndFailedPersistenceLeaveNotificationVisible() async throws {
    var fail = true
    let service = NativeUpdates(
      enabled: true, savePreferences: { _ in if fail { throw CocoaError(.fileWriteOutOfSpace) } })
    ready(service)
    await rejects { try await service.skip(version: "0.1.9") }
    await rejects { try await service.remind() }
    XCTAssertEqual(service.notification, "visible")
    XCTAssertEqual(service.status, "ready")
    fail = false
    try await service.skip()
    fail = true
    await rejects { try await service.remind() }
    XCTAssertEqual(service.notification, "skipped", "Failed saves preserve previous choice")
    try await service.install()
    await rejects { try await service.skip() }
  }
  func testAsyncPreferenceSaveBlocksOtherOperations() async throws {
    var finish: CheckedContinuation<Void, Never>?
    let service = NativeUpdates(
      enabled: true, savePreferences: { _ in await withCheckedContinuation { finish = $0 } })
    ready(service)
    let saving = Task { try await service.remind() }
    while finish == nil { await Task.yield() }
    XCTAssertEqual(
      service.notification, "visible", "Pending choice remains visible until persistence succeeds")
    await rejects { try await service.skip() }
    await rejects { try await service.install() }
    XCTAssertThrowsError(try service.check())
    finish?.resume()
    try await saving.value
    XCTAssertEqual(service.notification, "deferred")
    service.cancelForQuit()
  }
  func testPlainBilingualReleaseNotesValidation() {
    let ru = "• Обновление <script>alert(1)</script>"
    let en = "• Update & fixes"
    XCTAssertEqual(NativeUpdates.releaseNotes(["ru": ru, "en": en]), ru + "\n\nEnglish\n\n" + en)
    XCTAssertEqual(
      NativeUpdates.releaseNotes("{\"ru\":\" Полка \",\"en\":\" Shelf \"}"),
      "Полка\n\nEnglish\n\nShelf")
    for invalid: Any in [
      "<p>Legacy release</p>", "{invalid", [String: String](), ["ru": "Без перевода"],
      ["ru": " ", "en": "English"], ["ru": String(repeating: "x", count: 20_001), "en": "English"],
      ["ru": String(repeating: "😀", count: 10_001), "en": "English"],
    ] { XCTAssertNil(NativeUpdates.releaseNotes(invalid)) }
    let service = NativeUpdates(enabled: true)
    service.receiveAvailable(version: "0.2.0", releaseNotes: ["ru": ru, "en": en])
    service.receiveReady(version: "0.2.0", reply: { _ in })
    XCTAssertTrue(service.notes.contains(ru), "Downloaded event retains same-version notes")
    XCTAssertEqual(service.notesRussian, ru)
    XCTAssertEqual(service.notesEnglish, en)
    service.receiveReady(version: "0.3.0", reply: { _ in })
    XCTAssertTrue(service.notes.isEmpty, "Different versions never inherit stale notes")
    XCTAssertTrue(service.notesRussian.isEmpty)
    XCTAssertTrue(service.notesEnglish.isEmpty)
  }
}
