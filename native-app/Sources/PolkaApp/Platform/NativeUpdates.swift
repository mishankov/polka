import AppKit
import PolkaCore
import Sparkle

/// Sparkle downloads and verifies updates; the shelf grants the final installation reply.
/// Events and preference persistence are injectable so no update feed or installer is
/// touched by the state-machine tests.
@MainActor final class NativeUpdates: NSObject, SPUUserDriver {
  private var updater: SPUUpdater?
  private var readyReply: ((SPUUserUpdateChoice) -> Void)?
  private var cancellation: (() -> Void)?
  private let settings: SettingsStore?
  private var enabled: Bool
  private var skippedVersion: String?
  private var reminder: (version: String, after: Double)?
  private var reminderTimer: Timer?
  private var preferenceSaving = false
  private var busy = false
  private var generation = 0
  private var expected: UInt64 = 0
  private var received: UInt64 = 0
  private let now: () -> Double
  private let savePreferences: (([String: Any]) async throws -> Void)?
  private let checkAction: (() throws -> Void)?
  private(set) var status: String
  private(set) var version = ""
  private(set) var notes = ""
  private(set) var notesRussian = ""
  private(set) var notesEnglish = ""
  private(set) var progress = 0.0
  private(set) var message: String
  private(set) var installationAuthorized = false
  let currentVersion: String
  var changed: (() -> Void)?
  var beforeInstall: (() async throws -> Void)?
  var restoreAfterInstallFailure: (() -> Void)?
  private static let unavailable =
    "Эта сборка не подключена к каналу обновлений. Установите выпуск с GitHub, чтобы получать обновления."
  private static let updateError =
    "Не удалось обновить приложение. Проверьте подключение и повторите проверку."
  static let reminderDelay = 86_400_000.0

  init(
    settings: SettingsStore? = nil, currentVersion: String? = nil, enabled: Bool = false,
    preferences: Any? = nil,
    now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
    savePreferences: (([String: Any]) async throws -> Void)? = nil,
    checkAction: (() throws -> Void)? = nil
  ) {
    self.settings = settings
    self.enabled = enabled
    self.now = now
    self.savePreferences = savePreferences
    self.checkAction = checkAction
    self.currentVersion =
      currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String ?? "0.1.15"
    status = enabled ? "idle" : "unavailable"
    message = enabled ? "" : Self.unavailable
    super.init()
    let saved = (preferences ?? (try? settings?.get(key: "updatePreferences"))) as? [String: Any]
    skippedVersion = saved?["skippedVersion"] as? String
    if let value = saved?["reminder"] as? [String: Any], let version = value["version"] as? String,
      let after = value["after"] as? Double, after.isFinite
    {
      reminder = (version, after)
    }
    scheduleReminder()
  }
  var notification: String {
    if !version.isEmpty && version == skippedVersion { return "skipped" }
    if let reminder, reminder.version == version, reminder.after > now() { return "deferred" }
    return "visible"
  }
  var remindAfter: Double { notification == "deferred" ? reminder?.after ?? 0 : 0 }
  func start() {
    guard updater == nil,
      let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let url = URL(string: feed), ["https", "http"].contains(url.scheme),
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      Data(base64Encoded: key)?.count == 32
    else { return }
    let updater = SPUUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
    self.updater = updater
    do {
      try updater.start()
      updater.automaticallyChecksForUpdates = true
      updater.sendsSystemProfile = false
      enabled = true
      status = "idle"
      message = ""
      changed?()
      updater.checkForUpdatesInBackground()
    } catch {
      enabled = true
      status = "error"
      message = "Не удалось начать проверку обновлений."
      changed?()
    }
  }
  private func requireEnabled() throws {
    guard enabled else {
      throw PolkaCoreError.invalid(message.isEmpty ? Self.unavailable : message)
    }
  }
  private func requireIdleOperation() throws {
    try requireEnabled()
    guard !busy && !preferenceSaving else {
      throw PolkaCoreError.invalid("Дождитесь завершения текущей операции обновления")
    }
  }
  func check() throws {
    try requireIdleOperation()
    guard !["checking", "downloading", "ready", "installing"].contains(status) else {
      throw PolkaCoreError.invalid("Сначала завершите текущее обновление")
    }
    if checkAction == nil {
      guard let updater, updater.canCheckForUpdates else {
        throw PolkaCoreError.invalid("Проверка обновлений уже выполняется")
      }
    }
    status = "checking"
    message = ""
    progress = 0
    changed?()
    do { if let checkAction { try checkAction() } else { updater?.checkForUpdates() } } catch {
      status = "error"
      message = "Не удалось проверить обновления. Повторите попытку позже."
      changed?()
    }
  }
  func install() async throws {
    try requireIdleOperation()
    guard status == "ready", let reply = readyReply else {
      throw PolkaCoreError.invalid("Обновление ещё не загружено")
    }
    busy = true
    status = "installing"
    message = ""
    changed?()
    let operationGeneration = generation
    defer { busy = false }
    do {
      try await beforeInstall?()
      // An ordinary quit or error while saving must never authorize a late restart.
      guard status == "installing", generation == operationGeneration else { return }
      readyReply = nil
      cancellation = nil
      installationAuthorized = true
      reply(.install)
    } catch {
      guard generation == operationGeneration else { return }
      restoreAfterInstallFailure?()
      status = "ready"
      message = "Не удалось сохранить историю буфера или начать установку. Повторите попытку."
      changed?()
    }
  }
  func skip(version requestedVersion: String? = nil) async throws {
    try await saveChoice(version: requestedVersion ?? version, skip: true)
  }
  func remind(version requestedVersion: String? = nil) async throws {
    try await saveChoice(version: requestedVersion ?? version, skip: false)
  }
  private func saveChoice(version requestedVersion: String, skip: Bool) async throws {
    try requireEnabled()
    guard !requestedVersion.isEmpty && requestedVersion == version && status != "installing" else {
      throw PolkaCoreError.invalid("Эта версия обновления больше недоступна")
    }
    guard !preferenceSaving else { throw PolkaCoreError.invalid("Дождитесь сохранения выбора") }
    preferenceSaving = true
    defer { preferenceSaving = false }
    let after = now() + Self.reminderDelay
    let preferences: [String: Any] =
      skip
      ? ["skippedVersion": requestedVersion]
      : ["reminder": ["version": requestedVersion, "after": after]]
    if let savePreferences {
      try await savePreferences(preferences)
    } else if let settings {
      try settings.set(key: "updatePreferences", value: preferences)
    }
    // Commit only after durable persistence. Each choice replaces the previous one,
    // so choosing Tomorrow after Skip makes the selected version visible tomorrow.
    skippedVersion = skip ? requestedVersion : nil
    reminder = skip ? nil : (requestedVersion, after)
    scheduleReminder()
    changed?()
  }
  private func scheduleReminder() {
    reminderTimer?.invalidate()
    reminderTimer = nil
    guard let reminder, reminder.after > now() else { return }
    reminderTimer = Timer.scheduledTimer(
      withTimeInterval: min((reminder.after - now()) / 1000, 2_147_483.647), repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reminderExpired() }
    }
  }
  func reminderExpired() {
    changed?()
    scheduleReminder()
  }
  func cancelForQuit(explicitUpdate: Bool = false) {
    guard enabled && !explicitUpdate else { return }
    generation += 1
    installationAuthorized = false
    reminderTimer?.invalidate()
    reminderTimer = nil
    let reply = readyReply
    let cancel = cancellation
    readyReply = nil
    cancellation = nil
    status = "idle"
    version = ""
    clearNotes()
    progress = 0
    message = ""
    // Skip is Sparkle's cancellation of staging; Dismiss consents to install on quit.
    if let reply { reply(.skip) } else { cancel?() }
    changed?()
  }
  static func releaseNotes(_ value: Any?) -> String? {
    guard let notes = parsedNotes(value) else { return nil }
    return notes.ru + "\n\nEnglish\n\n" + notes.en
  }
  private static func parsedNotes(_ value: Any?) -> (ru: String, en: String)? {
    let object: Any?
    if let text = value as? String, let data = text.data(using: .utf8) {
      object = try? JSONSerialization.jsonObject(with: data)
    } else {
      object = value
    }
    guard let notes = object as? [String: Any], let ru = notes["ru"] as? String,
      let en = notes["en"] as? String,
      ru.utf16.count <= 20_000, en.utf16.count <= 20_000
    else { return nil }
    let russian = ru.trimmingCharacters(in: .whitespacesAndNewlines)
    let english = en.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !russian.isEmpty && !english.isEmpty else { return nil }
    return (russian, english)
  }
  private func clearNotes() {
    notes = ""
    notesRussian = ""
    notesEnglish = ""
  }
  private func applyNotes(_ value: Any?, preserve: Bool = false) {
    if let parsed = Self.parsedNotes(value) {
      notesRussian = parsed.ru
      notesEnglish = parsed.en
      notes = parsed.ru + "\n\nEnglish\n\n" + parsed.en
    } else if !preserve {
      clearNotes()
    }
  }
  func receiveAvailable(version: String, releaseNotes: Any? = nil) {
    guard enabled && ["idle", "current", "error", "checking"].contains(status) else { return }
    self.version = version
    applyNotes(releaseNotes)
    status = "downloading"
    progress = 0
    message = ""
    changed?()
  }
  func receiveReady(
    version: String, releaseNotes: Any? = nil, reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    guard enabled && status != "installing" else { return }
    let sameVersion = self.version == version
    self.version = version
    applyNotes(releaseNotes, preserve: sameVersion)
    readyReply = reply
    cancellation = nil
    status = "ready"
    progress = 100
    message = ""
    changed?()
  }
  func receiveCurrent() {
    guard enabled && ["idle", "current", "error", "checking"].contains(status) else { return }
    readyReply = nil
    cancellation = nil
    status = "current"
    version = ""
    clearNotes()
    message = ""
    changed?()
  }
  func receiveError() {
    guard enabled else { return }
    if status == "installing" { restoreAfterInstallFailure?() }
    generation += 1
    installationAuthorized = false
    readyReply = nil
    cancellation = nil
    status = "error"
    message = Self.updateError
    changed?()
  }
  func show(
    _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }
  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    self.cancellation = cancellation
    if enabled && ["idle", "current", "error"].contains(status) {
      status = "checking"
      message = ""
      progress = 0
      changed?()
    }
  }
  func showUpdateFound(
    with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    guard !appcastItem.isInformationOnlyUpdate else {
      receiveError()
      reply(.dismiss)
      return
    }
    let version =
      appcastItem.displayVersionString.isEmpty
      ? appcastItem.versionString : appcastItem.displayVersionString
    if state.stage == .installing {
      // A recovered staged update must still wait for the explicit shelf command.
      receiveReady(version: version, releaseNotes: appcastItem.itemDescription, reply: reply)
    } else {
      receiveAvailable(version: version, releaseNotes: appcastItem.itemDescription)
      reply(.install)
    }
  }
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    receiveCurrent()
    acknowledgement()
  }
  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    receiveError()
    acknowledgement()
  }
  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    self.cancellation = cancellation
    expected = 0
    received = 0
    if status == "downloading" {
      progress = 0
      changed?()
    }
  }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    expected = expectedContentLength
  }
  func showDownloadDidReceiveData(ofLength length: UInt64) {
    let (sum, overflow) = received.addingReportingOverflow(length)
    received = overflow ? .max : sum
    if status == "downloading" {
      progress = expected == 0 ? 0 : min(100, Double(received) / Double(expected) * 100)
      changed?()
    }
  }
  func showDownloadDidStartExtractingUpdate() {
    if status == "downloading" {
      progress = 100
      changed?()
    }
  }
  func showExtractionReceivedProgress(_ progress: Double) {}
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    receiveReady(version: version, reply: reply)
  }
  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) { if status == "installing" { changed?() } }
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }
  func dismissUpdateInstallation() {
    cancellation = nil
    readyReply = nil
  }
  func showUpdateInFocus() { changed?() }
}
