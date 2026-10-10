import AppKit
import PolkaCore
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

@MainActor final class NativePlatform {
  let model: NativeUIModel
  let history: ClipboardHistory
  let settings: SettingsStore
  let capture: NativeClipboardCapture
  let files = FileShelf()
  let applications = InstalledApps()
  let shortcuts: GlobalShortcuts?
  let probe = HelperProcess()
  let fileProbe = HelperProcess()
  let updates: NativeUpdates
  let sync: NativeClipboardSync
  let fixture: Bool
  private let encryption: EncryptionCodec
  private var pasteToken: String?
  private var pasteEpoch = 0
  private var disposed = false
  private var startupTask: Task<Void, Never>?
  private var initializationTask: Task<Void, Never>?
  private var maintenance: Timer?
  private var launcherRegistered = false
  private(set) var clipboardRegistered = false
  private(set) var builtinApps = BuiltinAppAvailability()
  private var launcherAccelerator = "CommandOrControl+Shift+Space"
  private var usage: [String: LauncherUsage] = [:]
  private var calculationDate = Date()
  private var catalogRequests = 0
  var show: ((String?, String) async -> Void)?
  var hide: ((Bool) -> Void)?
  var openSettings: ((String?) -> Void)?
  var currentPanel: (() -> NSWindow?)?
  var showIncomingFiles: (() async -> Void)?
  var endIncomingFiles: (() -> Void)?
  var filesDropped: (() async -> Void)?
  var mediaTracking: ((String, Bool) throws -> Void)?
  var languageChanged: (() -> Void)?
  init(model: NativeUIModel, root: URL, fixture: Bool, encryption: EncryptionCodec? = nil) throws {
    self.model = model
    self.fixture = fixture
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    settings = try SettingsStore(root: root)
    let languagePreference =
      AppLanguagePreference(
        rawValue: (try settings.get(key: AppLanguagePreference.settingsKey)) as? String ?? "system")
      ?? .system
    AppLocalization.configure(languagePreference)
    model.settings.languagePreference = languagePreference
    model.settings.language = AppLocalization.language
    let historyPath = root.appendingPathComponent("clipboard-history/history.enc")
    let syncPath = root.appendingPathComponent("clipboard-history/sync.enc")
    let codec: EncryptionCodec
    if let encryption {
      codec = encryption
    } else if let update = NativeProfile.update {
      codec = NativeKeychainCodec(password: { update.password })
    } else if fixture {
      codec = SyntheticEncryptionCodec(key: Data(repeating: 0x71, count: 32))
    } else {
      let allowCreate =
        !FileManager.default.fileExists(atPath: historyPath.path)
        && !FileManager.default.fileExists(atPath: syncPath.path)
      codec =
        NativeDevelopmentKeychain.codec(allowCreate: allowCreate)
        ?? NativeKeychainCodec(allowCreate: allowCreate)
    }
    self.encryption = codec
    history = ClipboardHistory(
      path: historyPath, codec: codec,
      changed: { [weak model] in DispatchQueue.main.async { model?.searchRevision += 1 } })
    capture = NativeClipboardCapture(history: history, fixture: fixture)
    shortcuts = fixture ? nil : GlobalShortcuts()
    updates = NativeUpdates(settings: settings)
    sync = NativeClipboardSync(
      path: root.appendingPathComponent("clipboard-history/sync.enc"), codec: codec,
      history: history, discovery: !fixture,
      changed: { [weak model] in DispatchQueue.main.async { model?.searchRevision += 1 } })
    builtinApps = BuiltinAppAvailability(
      overrides: (try settings.get(key: BuiltinAppAvailability.settingsKey)) as? [String: Bool]
        ?? [:])
    model.settings.builtinApps = builtinApps
    capture.setEnabled(builtinApps.allows(destination: "clipboard"))
    model.action = { [weak self] command in
      guard let self else { return }
      try await self.handle(command)
    }
    model.searchProvider = { [weak self] query in self?.search(query) ?? [] }
    model.emojiProvider = { query, category, tone in
      EmojiCatalog.shared.results(query: query, category: category, tone: tone).map {
        NativeUIEmoji(
          id: $0.id, value: $0.value,
          name: AppLocalization.language == .russian ? $0.name : $0.englishName,
          englishName: $0.englishName)
      }
    }
    model.calculationStatusProvider = { [weak self] query in
      Calculator.calculate(
        query, context: CalculationContext(now: self?.calculationDate ?? Date()))?.message
    }
    model.fileDragURLs = { [weak self] ids in
      guard let self else { return [] }
      try self.requireEnabled("files")
      return try self.files.drag(ids)
    }
    model.fileDragStarted = { [weak self] in
      self?.model.outgoingFileDrag = true
      _ = self?.fileProbe.write(["enabled": false, "outgoing": true])
    }
    model.fileDragEnded = { [weak self] in
      guard let self else { return }
      self.model.outgoingFileDrag = false
      _ = self.fileProbe.write(["enabled": self.builtinApps.allows(destination: "files")])
    }
    updates.changed = { [weak self] in self?.refresh() }
    updates.beforeInstall = { [weak self] in
      self?.history.flush()
      self?.cancelPaste()
    }
    updates.restoreAfterInstallFailure = { [weak self] in
      self?.model.busy = false
      self?.refresh()
    }
    if let value = try settings.get(key: "launcherShortcut") as? String {
      launcherAccelerator = value
    }
    if let saved = try settings.get(key: "launcherUsage"),
      let data = try? JSONSerialization.data(withJSONObject: saved)
    {
      usage = (try? JSONDecoder().decode([String: LauncherUsage].self, from: data)) ?? [:]
    }
    model.settings.introduced = (try? settings.get(key: "shelfIntroduced")) as? Bool ?? false
    model.settingsPane = (try? settings.get(key: "settingsPane")) as? String ?? "general"
    model.settingsPaneChanged = { [weak self] pane in
      guard let self, !self.disposed else { return }
      do { try self.settings.set(key: "settingsPane", value: pane) } catch {
        self.model.error = error.localizedDescription
      }
    }
  }
  func initialize() async {
    if !fixture {
      startProbe()
      startFileProbe()
    } else {
      model.helperStatus = "running"
      model.pasteAccess = "granted"
      if NativeProfile.isolatedFixture,
        ProcessInfo.processInfo.environment["POLKA_NATIVE_EXTERNAL_FILE_DROP"] == "1",
        CommandLine.arguments.contains("--native-external-file-drop-smoke")
      {
        startFileProbe()
      }
    }
    // The shelf appears independently from history/Keychain/native-helper readiness.
    initializationTask = Task {
      do {
        if !fixture || CommandLine.arguments.contains("--native-notice-quit-smoke") {
          do { try await keychainNotice() } catch {
            guard !disposed, !Task.isCancelled else { return }
            _ = try? history.storage.run("decrypt") { throw error }
            throw error
          }
        }
        guard !disposed, !Task.isCancelled else { return }
        // Security may wait for a Keychain permission dialog. Resolve and cache
        // the key away from the UI thread before any store can use this codec.
        // No encrypted file is written by this preflight.
        let encryption = self.encryption
        do { _ = try await Task.detached { try encryption.encode(Data("{}".utf8)) }.value } catch {
          guard !disposed, !Task.isCancelled else { return }
          _ = try? history.storage.run("decrypt") { throw error }
          throw error
        }
        guard !disposed, !Task.isCancelled else { return }
        try history.initialize()
        try capture.capture()
        if fixture, NativeProfile.update == nil, history.snapshot().clips.isEmpty {
          try history.add(
            .text, content: "Синтетическая запись Полки", preview: "Синтетическая запись Полки")
        }
      } catch {
        guard !disposed, !Task.isCancelled else { return }
        model.error = error.localizedDescription
      }
      guard !disposed, !Task.isCancelled else { return }
      if history.storage.ready {
        do { try registerHistoryShortcut(history.getPreferences().accelerator) } catch {
          model.error = error.localizedDescription
        }
      }
      do { try await sync.initialize() } catch { model.error = error.localizedDescription }
      refresh()
      capture.indexImages()
    }
    do { try registerLauncherShortcut(launcherAccelerator) } catch {
      model.settings.launcherShortcutError = error.localizedDescription
    }
    Task {
      do { try await refreshCatalog() } catch { model.catalogError = error.localizedDescription }
    }
    maintenance = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        try? self.history.prune()
        self.files.refresh()
        self.refresh()
        self.capture.indexImages()
      }
    }
    if !fixture { updates.start() }
    refresh()
  }
  func refreshCatalog() async throws {
    guard !disposed else { return }
    if fixture {
      model.catalogLoading = false
      refresh()
      return
    }
    catalogRequests += 1
    model.catalogLoading = true
    defer {
      catalogRequests -= 1
      model.catalogLoading = catalogRequests > 0
    }
    do {
      let previous = applications.apps
      try await applications.refresh()
      if previous != applications.apps { model.searchRevision += 1 }
      model.catalogError = ""
      refresh()
    } catch {
      model.catalogError = error.localizedDescription
      throw error
    }
  }
  func waitForInitialization() async { await initializationTask?.value }
  func updateSystemLanguage(preferredLanguages: [String] = Locale.preferredLanguages) {
    guard !disposed else { return }
    AppLocalization.configure(
      model.settings.languagePreference, preferredLanguages: preferredLanguages)
    let language = AppLocalization.language
    guard model.settings.language != language else { return }
    model.settings.language = language
    model.searchRevision += 1
    refresh()
    languageChanged?()
  }
  private func keychainNotice() async throws {
    let root = URL(fileURLWithPath: history.storage.state().path).deletingLastPathComponent()
      .deletingLastPathComponent()
    let path = root.appendingPathComponent("keychain-notice-version")
    let version = updates.currentVersion
    guard
      (try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines)) != version
    else { return }
    let alert = NSAlert()
    // This explanatory prompt must not veto Quit before the application
    // delegate can cancel startup and release helpers.
    alert.window.preventsApplicationTerminationWhenModal = false
    alert.messageText = localized("Access to Encrypted History")
    alert.informativeText =
      localized(
        "Polka stores its encryption key in macOS Keychain. The system may ask for access to “polka Safe Storage”. Allow access to open history. If access is denied, encrypted files are preserved."
      )
    alert.addButton(withTitle: localized("Continue"))
    alert.addButton(withTitle: localized("Cancel"))
    alert.buttons[1].keyEquivalent = "\u{1b}"
    guard let panel = currentPanel?() else {
      throw PolkaCoreError.storage(localized("Could not show the history access prompt"))
    }
    if !panel.isVisible { await show?(nil, "") }
    guard !disposed, !Task.isCancelled else { throw CancellationError() }
    let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: panel) { continuation.resume(returning: $0) }
    }
    guard !disposed, !Task.isCancelled else { throw CancellationError() }
    guard response == .alertFirstButtonReturn else {
      throw PolkaCoreError.storage(
        localized("History access was cancelled. Restart Polka to try again."))
    }
    try version.write(to: path, atomically: true, encoding: .utf8)
  }
  private func startProbe() {
    model.helperStatus = "starting"
    probe.onMessage = { [weak self] message in
      guard let self, !self.disposed else { return }
      if message["type"] as? String == "ready" {
        self.model.helperStatus = "running"
        self.model.helperError = ""
        Task { _ = await self.pasteStatus() }
        self.refresh()
      }
      if message["type"] as? String == "clipboard" {
        do { try self.capture.capture() } catch { self.model.error = error.localizedDescription }
        self.refresh()
        self.capture.indexImages()
      }
    }
    probe.onExit = { [weak self] _ in
      guard let self, !self.disposed else { return }
      self.pasteToken = nil
      self.model.pasteReady = false
      self.model.helperStatus = "failed"
      self.model.helperError = localized("Clipboard monitoring has stopped. Restart Polka.")
    }
    startupTask = Task {
      let delays: [Double] = [5, 15, 30]
      for timeout in delays {
        guard !disposed, !Task.isCancelled else { return }
        do {
          try probe.start(
            NativeProfile.helper("clipboard-probe"),
            arguments: [String(ProcessInfo.processInfo.processIdentifier)])
          let deadline = Date().addingTimeInterval(timeout)
          while Date() < deadline, !disposed, !Task.isCancelled, model.helperStatus != "running",
            probe.running
          { try? await Task.sleep(nanoseconds: 50_000_000) }
          if model.helperStatus == "running" { return }
          probe.stop()
          model.helperStatus = "starting"
          pasteToken = nil
        } catch {
          model.helperStatus = "failed"
          model.helperError = error.localizedDescription
          return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      model.helperStatus = "failed"
      model.helperError = localized("The native helper did not start. Restart Polka.")
    }
  }
  private func startFileProbe() {
    fileProbe.onMessage = { [weak self] message in
      guard let self, !self.disposed else { return }
      guard self.builtinApps.allows(destination: "files") else { return }
      switch message["type"] as? String {
      case "enter": Task { await self.showIncomingFiles?() }
      case "drop":
        if let paths = message["paths"] as? [String] {
          do {
            try self.files.add(paths)
            self.refresh()
            Task { await self.filesDropped?() }
          } catch { self.model.error = error.localizedDescription }
        }
      case "incomingEnd": self.endIncomingFiles?()
      default: break
      }
    }
    fileProbe.onExit = { [weak self] _ in
      guard let self, !self.disposed else { return }
      self.model.error =
        localized(
          "The notch target is unavailable. Open files from the app list and drag them onto the open shelf."
        )
    }
    do {
      try fileProbe.start(NativeProfile.helper("file-shelf-probe"))
      _ = fileProbe.write(["enabled": builtinApps.allows(destination: "files")])
    } catch {
      model.error = error.localizedDescription
    }
  }
  func anchorCalculationDate(_ date: Date = Date()) {
    guard calculationDate != date else { return }
    calculationDate = date
    model.searchRevision += 1
  }
  func beginSession() async {
    if !fixture {
      Task {
        do { try await refreshCatalog() } catch {
          // Catalog error is rendered on the launcher.
        }
      }
    }
    pasteEpoch += 1
    let epoch = pasteEpoch
    pasteToken = nil
    model.pasteReady = false
    anchorCalculationDate()
    if fixture {
      pasteToken = UUID().uuidString
      model.pasteReady = true
      return
    }
    guard model.helperStatus == "running" else { return }
    let result = await probe.request("capture")
    guard epoch == pasteEpoch else { return }
    model.pasteAccess =
      result["trusted"] as? Bool == true
      ? "granted" : result["trusted"] as? Bool == false ? "required" : "unavailable"
    pasteToken = result["token"] as? String
    model.pasteReady = pasteToken != nil
  }
  func cancelPaste() {
    pasteEpoch += 1
    pasteToken = nil
    model.pasteReady = false
    _ = probe.write(["id": UUID().uuidString, "method": "cancel"])
  }
  private func pasteStatus(prompt: Bool = false) async -> String {
    guard !fixture else { return "granted" }
    let reply = await probe.request(prompt ? "requestAccess" : "status")
    model.pasteAccess =
      reply["trusted"] as? Bool == true
      ? "granted" : reply["trusted"] as? Bool == false ? "required" : "unavailable"
    return model.pasteAccess
  }
  func refresh() {
    guard !disposed else { return }
    let snapshot = history.snapshot(includeImageContent: false)
    let storage = history.storage.state()
    let clips = snapshot.clips.map(projectClip)
    let snippets = snapshot.snippets.map(projectClip)
    if model.clips != clips { model.clips = clips }
    if model.snippets != snippets { model.snippets = snippets }
    if let previewID = model.previewID,
      !(model.clips + model.snippets).contains(where: { $0.id == previewID })
    {
      model.previewID = nil
      model.previewImage = nil
      model.transformation = nil
    }
    if model.storageStatus != storage.status.rawValue {
      model.storageStatus = storage.status.rawValue
    }
    if model.storagePath != storage.path { model.storagePath = storage.path }
    if model.storageError != storage.diagnostic?.message ?? "" {
      model.storageError = storage.diagnostic?.message ?? ""
    }
    if model.preferencesAvailable != history.preferencesAvailable {
      model.preferencesAvailable = history.preferencesAvailable
    }
    if model.storageDiagnosticStage != storage.diagnostic?.stage ?? "" {
      model.storageDiagnosticStage = storage.diagnostic?.stage ?? ""
    }
    if model.storageDiagnosticCode != storage.diagnostic?.code ?? "" {
      model.storageDiagnosticCode = storage.diagnostic?.code ?? ""
    }
    let projectedFiles = files.items.map {
      NativeUIFile(
        id: $0.id, name: $0.name, path: $0.path, available: $0.available, directory: $0.directory)
    }
    if model.files != projectedFiles { model.files = projectedFiles }
    let selectedFiles = model.selectedFiles.intersection(Set(files.items.map(\.id)))
    if model.selectedFiles != selectedFiles { model.selectedFiles = selectedFiles }
    let apps = builtinApps.catalog(LauncherSearch.builtinApps + applications.apps).map {
      NativeUIApp(id: $0.id, name: $0.name, icon: $0.icon, detail: $0.description)
    }
    if model.apps != apps { model.apps = apps }
    var nextSettings = model.settings
    nextSettings.builtinApps = builtinApps
    nextSettings.paused = snapshot.preferences.paused
    nextSettings.pasteOnSelect = snapshot.preferences.pasteOnSelect
    nextSettings.hoverEnabled = snapshot.preferences.hoverEnabled
    nextSettings.retentionDays = snapshot.preferences.retentionDays
    nextSettings.clipboardShortcut = snapshot.preferences.accelerator
    nextSettings.launcherShortcut = launcherAccelerator
    nextSettings.login = !fixture && SMAppService.mainApp.status == .enabled
    let syncState = sync.state()
    nextSettings.syncEnabled = syncState.enabled
    nextSettings.syncStatus = syncState.status
    nextSettings.deviceName = syncState.deviceName
    nextSettings.syncError = syncState.error ?? ""
    nextSettings.syncStorageStatus = syncState.storage.status.rawValue
    nextSettings.syncStorageError = syncState.storage.diagnostic?.message ?? ""
    nextSettings.invitation = syncState.invitation?.code ?? ""
    nextSettings.invitationExpiresAt = syncState.invitation?.expiresAt ?? 0
    nextSettings.peers = syncState.peers.map {
      NativeUIPeer(
        id: $0.id, name: $0.name, status: $0.status, lastSync: $0.lastSync ?? 0,
        error: $0.error ?? "")
    }
    nextSettings.nearby = syncState.nearby.map(\.name)
    nextSettings.syncStoragePath = syncState.storage.path
    nextSettings.syncStorageStage = syncState.storage.diagnostic?.stage ?? ""
    nextSettings.syncStorageCode = syncState.storage.diagnostic?.code ?? ""
    nextSettings.currentVersion = updates.currentVersion
    nextSettings.updateStatus = updates.status
    nextSettings.updateVersion = updates.version
    nextSettings.updateNotes = updates.notes
    nextSettings.updateNotesRussian = updates.notesRussian
    nextSettings.updateNotesEnglish = updates.notesEnglish
    nextSettings.updateProgress = updates.progress
    nextSettings.updateMessage = updates.message
    nextSettings.updateNotification = updates.notification
    nextSettings.updateRemindAfter = updates.remindAfter
    if model.settings != nextSettings { model.settings = nextSettings }
  }
  private func projectClip(_ value: ClipboardClip) -> NativeUIClip {
    let ocr = value.ocr?.version == capture.ocrVersion ? value.ocr : nil
    return NativeUIClip(
      id: value.id, kind: value.kind.rawValue, content: value.content, preview: value.preview,
      createdAt: value.createdAt, pinned: value.pinned, snippet: value.isSnippet,
      name: value.name ?? "", sourceDevice: value.sourceDevice ?? "",
      ocrStatus: ocr?.status.rawValue ?? "", ocrText: ocr?.text ?? "",
      ocrLanguages: ocr?.languages ?? [])
  }
  private func redactedClip(_ value: ClipboardClip) -> ClipboardClip {
    var clip = value
    if clip.ocr?.version != capture.ocrVersion { clip.ocr = nil }
    return clip
  }
  private func validateFixtureShortcut(_ accelerator: String, other: String) throws {
    guard !accelerator.isEmpty else { return }
    let parsed = try GlobalShortcuts.parse(accelerator)
    if !other.isEmpty, let occupied = try? GlobalShortcuts.parse(other), parsed == occupied {
      throw PolkaCoreError.invalid(
        localized("This shortcut is already used by another Polka action. Choose another."))
    }
  }
  private func registerLauncherShortcut(_ accelerator: String) throws {
    if launcherRegistered, launcherAccelerator == accelerator { return }
    if fixture {
      try validateFixtureShortcut(
        accelerator,
        other: builtinApps.allows(destination: "clipboard")
          ? history.getPreferences().accelerator : "")
      try settings.set(key: "launcherShortcut", value: accelerator)
    } else {
      try shortcuts?.set(
        "launcher", accelerator: accelerator,
        persist: { try self.settings.set(key: "launcherShortcut", value: accelerator) },
        action: { [weak self] in
          guard let self, !self.model.busy, NSApp?.modalWindow == nil else { return }
          Task { await self.show?("toggle", "") }
        })
    }
    launcherAccelerator = accelerator
    launcherRegistered = true
    model.settings.launcherShortcutError = ""
  }
  private func registerHistoryShortcut(_ accelerator: String) throws {
    if !builtinApps.allows(destination: "clipboard") {
      if !accelerator.isEmpty { _ = try GlobalShortcuts.parse(accelerator) }
      var preferences = history.getPreferences()
      preferences.accelerator = accelerator
      try history.setPreferences(preferences)
      shortcuts?.remove("clipboard")
      clipboardRegistered = false
      model.settings.clipboardShortcutError = ""
      return
    }
    if clipboardRegistered, history.getPreferences().accelerator == accelerator { return }
    func persist() throws {
      var preferences = history.getPreferences()
      preferences.accelerator = accelerator
      try history.setPreferences(preferences)
    }
    if fixture {
      try validateFixtureShortcut(accelerator, other: launcherAccelerator)
      try persist()
    } else {
      try shortcuts?.set("clipboard", accelerator: accelerator, persist: persist) { [weak self] in
        guard let self, self.builtinApps.allows(destination: "clipboard"), !self.model.busy,
          NSApp?.modalWindow == nil,
          NSApp?.windows.contains(where: { $0.attachedSheet != nil }) != true
        else { return }
        Task { await self.show?("toggle-clipboard", "") }
      }
    }
    clipboardRegistered = true
    model.settings.clipboardShortcutError = ""
  }
  private func search(_ query: String) -> [NativeUISearchRow] {
    var rows: [NativeUISearchRow] = []
    if let value = Calculator.calculate(query, context: CalculationContext(now: calculationDate)),
      value.status == .result
    {
      rows.append(
        NativeUISearchRow(
          id: "calculation:" + query, kind: "calculation",
          title: value.displayValue ?? value.value ?? "",
          detail: value.interpretation ?? value.expression, expression: value.expression,
          sourceDate: value.sourceDate ?? ""))
    }
    rows += LauncherSearch.apps(
      builtinApps.catalog(LauncherSearch.builtinApps + applications.apps), query: query,
      usage: usage
    ).map {
      NativeUISearchRow(
        id: $0.id, kind: "app", title: $0.name, detail: $0.description, icon: $0.icon)
    }
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let snapshot = history.snapshot(includeImageContent: false)
      for (clips, more) in [(snapshot.clips, "more-clips"), (snapshot.snippets, "more-snippets")] {
        guard builtinApps.allows(destination: more == "more-clips" ? "clipboard" : "snippets")
        else { continue }
        let matches = clipboardResults(clips.map(redactedClip), query: query)
        rows += matches.prefix(3).map { clip in
          let preview = nativeClipboardSnippet(projectClip(clip), query: query)
          return NativeUISearchRow(
            id: "clip:" + clip.id, kind: "clip",
            title: clip.name ?? (clip.kind == .image ? localized("Image") : preview),
            detail: clip.name == nil && clip.kind == .text ? "" : preview,
            icon: clip.kind == .image ? clip.preview : "", clipID: clip.id, snippet: clip.isSnippet)
        }
        if matches.count > 3 {
          rows.append(
            NativeUISearchRow(
              id: more, kind: more,
              title: more == "more-clips"
                ? localized("Show All Items ({0})", String(describing: matches.count))
                : localized("Show All Snippets ({0})", String(describing: matches.count))))
        }
      }
    }
    return rows
  }
  private func copy(_ content: ClipboardClip, selection: Bool, transformation: String? = nil)
    async throws
  {
    if let transformation {
      guard content.kind == .text else {
        throw PolkaCoreError.invalid(localized("Only text can be transformed"))
      }
      guard ["upperCase", "lowerCase"].contains(transformation) else {
        throw PolkaCoreError.invalid(localized("Unknown text transformation"))
      }
    }
    if content.kind == .text {
      let text =
        transformation == "upperCase"
        ? content.content.uppercased()
        : transformation == "lowerCase" ? content.content.lowercased() : content.content
      capture.write(text: text)
    } else {
      guard transformation == nil, let image = Data(base64Encoded: content.content) else {
        throw PolkaCoreError.invalid(localized("Could not open the image"))
      }
      capture.write(image: image)
    }
    guard selection, history.getPreferences().pasteOnSelect else {
      model.notice = localized("Copied")
      hide?(true)
      return
    }
    guard let token = pasteToken, model.pasteAccess == "granted" else {
      model.notice = localized("Copied. Paste manually with ⌘V.")
      hide?(true)
      return
    }
    pasteToken = nil
    model.pasteReady = false
    let epoch = pasteEpoch
    hide?(false)
    if fixture { return }
    let reply = await probe.request("paste", fields: ["token": token])
    if epoch == pasteEpoch, reply["sent"] as? Bool != true {
      let reason = reply["reason"] as? String ?? ""
      let message =
        ["focus-not-restored", "field-changed", "window-changed"].contains(reason)
        ? localized("Could not restore focus to the previous field. Click it and press ⌘V.")
        : localized("Automatic paste failed. Return to the desired field and press ⌘V.")
      model.notice = message
      let content = UNMutableNotificationContent()
      content.title = localized("Copied")
      content.body = message
      let center = UNUserNotificationCenter.current()
      if await center.notificationSettings().authorizationStatus == .notDetermined {
        _ = try? await center.requestAuthorization(options: [.alert])
      }
      let request = UNNotificationRequest(
        identifier: "polka-paste-" + UUID().uuidString, content: content, trigger: nil)
      try? await center.add(request)
    }
  }
  func requireEnabled(_ destination: String) throws {
    guard builtinApps.allows(destination: destination) else {
      throw PolkaCoreError.invalid(
        localized("This app is disabled. Enable it in “Built-in Apps” settings."))
    }
  }
  private func validateAvailability(_ command: NativeUICommand) throws {
    let id = command.strings["id"] ?? ""
    switch command.name {
    case "launcher.show":
      if let destination = command.strings["destination"] {
        try requireEnabled(destination == "toggle-clipboard" ? "clipboard" : destination)
      }
    case "launcher.openMac":
      if id.hasPrefix("builtin:") { try requireEnabled(String(id.dropFirst(8))) }
    case "clipboardHistory.show", "clipboardHistory.clear": try requireEnabled("clipboard")
    case "shelf.showSnippets", "clipboardHistory.createSnippet", "clipboardHistory.edit":
      try requireEnabled("snippets")
    case "shelf.showEmoji", "shelf.selectEmoji", "shelf.copyEmoji": try requireEnabled("emoji")
    case "shelf.showFiles", "shelf.files.add", "shelf.files.remove", "shelf.files.clear":
      try requireEnabled("files")
    case "clipboardHistory.copy", "clipboardHistory.select", "clipboardHistory.preview",
      "clipboardHistory.pin", "clipboardHistory.remove", "clipboardHistory.openUrl",
      "clipboardHistory.saveImage", "clipboardHistory.copyImageText",
      "clipboardHistory.retryImageText":
      if let clip = history.find(id) {
        try requireEnabled(clip.isSnippet ? "snippets" : "clipboard")
      }
    default: break
    }
  }
  private func setBuiltinApp(_ id: String, enabled: Bool) async throws {
    guard LauncherSearch.builtinApps.contains(where: { $0.id == id }) else {
      throw PolkaCoreError.invalid(localized("Unknown built-in app"))
    }
    guard !model.busy || model.pendingCommand == "builtinApps.setEnabled",
      !model.outgoingFileDrag, !model.incomingFileDropPending, !model.incomingFileDropTargeted,
      NSApp?.modalWindow == nil, NSApp?.windows.contains(where: { $0.attachedSheet != nil }) != true
    else {
      throw PolkaCoreError.invalid(localized("Finish the current action before disabling the app"))
    }
    guard builtinApps.isEnabled(id) != enabled else { return }
    var next = builtinApps
    next.overrides[id] = enabled
    try settings.set(key: BuiltinAppAvailability.settingsKey, value: next.overrides)
    let destination = String(id.dropFirst(8))
    if !enabled { model.suspendBuiltinApp(destination) }
    builtinApps = next
    model.settings.builtinApps = next
    model.searchRevision += 1
    if destination == "clipboard" {
      capture.setEnabled(enabled)
      if enabled, history.storage.ready {
        do { try registerHistoryShortcut(history.getPreferences().accelerator) } catch {
          // Enabling the app succeeds even if another app has taken the stored shortcut.
          model.settings.clipboardShortcutError = error.localizedDescription
        }
      } else if !enabled {
        shortcuts?.remove("clipboard")
        clipboardRegistered = false
        model.settings.clipboardShortcutError = ""
      }
    }
    if destination == "files" { _ = fileProbe.write(["enabled": enabled]) }
    if !enabled, model.destination == destination {
      if model.visible {
        await show?("apps", "")
        if model.destination == destination { model.present(destination: "apps") }
      } else {
        model.present(destination: "apps")
        model.visible = false
      }
    }
  }
  func handle(_ command: NativeUICommand) async throws {
    try validateAvailability(command)
    guard updates.status != "installing" || command.name == "system.quit" else {
      throw PolkaCoreError.invalid(localized("An update is being installed"))
    }
    defer {
      refresh()
      capture.indexImages()
    }
    let id = command.strings["id"] ?? ""
    if [
      "clipboardHistory.select", "shelf.selectEmoji", "clipboardHistory.openUrl",
      "clipboardHistory.saveImage",
    ].contains(command.name) {
      guard model.visible, fixture || currentPanel?()?.isKeyWindow == true else {
        throw PolkaCoreError.invalid(localized("Open the shelf to paste the selection"))
      }
    }
    if [
      "clipboardHistory.copy", "clipboardHistory.select", "clipboardHistory.preview",
      "clipboardHistory.openUrl", "clipboardHistory.saveImage", "clipboardHistory.copyImageText",
    ].contains(command.name) {
      try history.prune()
    }
    switch command.name {
    case "builtinApps.setEnabled":
      try await setBuiltinApp(id, enabled: command.bools["enabled"] ?? true)
    case "launcher.show":
      await show?(command.strings["destination"], command.strings["query"] ?? "")
    case "launcher.hide", "clipboardHistory.hide": hide?(true)
    case "clipboardHistory.show": await show?("clipboard", command.strings["query"] ?? "")
    case "shelf.showEmoji": await show?("emoji", "")
    case "shelf.showFiles": await show?("files", "")
    case "shelf.showSnippets":
      let sourceID = command.strings["sourceClipId"]
      let source = sourceID.flatMap(history.find)
      if sourceID != nil {
        guard history.storage.ready, source?.kind == .text else {
          throw PolkaCoreError.invalid(localized("The original text item is no longer available"))
        }
      }
      await show?("snippets", command.strings["query"] ?? "")
      if let source, model.destination == "snippets", model.visible, model.draft == nil {
        model.draft = NativeSnippetDraft(
          id: source.isSnippet ? source.id : "", name: source.name ?? "", content: source.content,
          expectedName: source.name ?? "", expectedContent: source.content)
      }
    case "shelf.settings": openSettings?(command.strings["section"])
    case "launcher.openMac":
      if id.hasPrefix("builtin:") {
        await show?(String(id.dropFirst(8)), "")
        return
      }
      try await applications.open(id)
      let old = usage[id] ?? LauncherUsage()
      usage[id] = LauncherUsage(
        count: old.count + 1, lastLaunchedAt: Date().timeIntervalSince1970 * 1000)
      model.searchRevision += 1
      do {
        try settings.set(
          key: "launcherUsage",
          value: JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)))
      } catch { model.error = localized("Could not save launch statistics") }
      hide?(true)
    case "launcher.refresh": try await refreshCatalog()
    case "launcher.setShortcut": try registerLauncherShortcut(command.strings["accelerator"] ?? "")
    case "clipboardHistory.shortcut":
      try registerHistoryShortcut(command.strings["accelerator"] ?? "")
    case "clipboardHistory.preferences":
      var value = history.getPreferences()
      if let next = command.bools["paused"] { value.paused = next }
      if let next = command.bools["pasteOnSelect"] { value.pasteOnSelect = next }
      if let next = command.bools["hoverEnabled"] { value.hoverEnabled = next }
      if let next = command.ints["retentionDays"] { value.retentionDays = next }
      try history.setPreferences(value)
    case "clipboardHistory.createSnippet":
      _ = try history.createSnippet(
        content: command.strings["content"] ?? "", name: command.strings["name"] ?? "")
    case "clipboardHistory.edit":
      let expectedName = command.strings["expectedName"]
      _ = try history.edit(
        id, content: command.strings["content"] ?? "", name: command.strings["name"] ?? "",
        expected: SnippetExpected(
          content: command.strings["expectedContent"] ?? "",
          name: expectedName?.isEmpty == true ? nil : expectedName))
    case "clipboardHistory.pin": try history.pin(id, pinned: command.bools["pinned"] ?? false)
    case "clipboardHistory.remove":
      capture.cancel()
      try history.remove(id)
    case "clipboardHistory.clear":
      capture.cancel()
      try history.clear()
    case "clipboardHistory.copy", "clipboardHistory.select":
      guard let clip = history.find(id) else {
        throw PolkaCoreError.invalid(localized("This item has already been deleted"))
      }
      try await copy(
        clip, selection: command.name.hasSuffix("select"),
        transformation: command.strings["transformation"])
    case "clipboardHistory.preview":
      guard let clip = history.find(id), clip.kind == .image,
        let data = Data(base64Encoded: clip.content), let image = NSImage(data: data)
      else { throw PolkaCoreError.invalid(localized("The image has already been deleted")) }
      model.previewImage = image
    case "clipboardHistory.retryImageText": try history.retryImageText(id)
    case "clipboardHistory.copyImageText":
      guard let clip = history.find(id), let ocr = clip.ocr, ocr.version == capture.ocrVersion,
        ocr.status == .ready
      else { throw PolkaCoreError.invalid(localized("Recognized text is not available yet")) }
      capture.write(text: ocr.text)
      model.notice = localized("Text Copied")
      hide?(true)
    case "clipboardHistory.requestPasteAccess":
      hide?(true)
      _ = await pasteStatus(prompt: true)
    case "clipboardHistory.openUrl":
      guard let clip = history.find(id), clip.kind == .text, let url = nativeWebURL(clip.content)
      else {
        throw PolkaCoreError.invalid(
          localized(
            "The item must contain a single HTTP or HTTPS link without a username or password"))
      }
      if !fixture {
        guard NSWorkspace.shared.open(url) else {
          throw PolkaCoreError.invalid(localized("Could not open the link"))
        }
      }
      hide?(true)
    case "clipboardHistory.saveImage":
      guard let clip = history.find(id), clip.kind == .image,
        let data = Data(base64Encoded: clip.content), let owner = currentPanel?()
      else { throw PolkaCoreError.invalid(localized("The image has already been deleted")) }
      let revision = model.sessionRevision
      defer {
        if model.visible, model.sessionRevision == revision, owner.isVisible { owner.makeKey() }
      }
      let timestamp = ISO8601DateFormatter().string(
        from: Date(timeIntervalSince1970: clip.createdAt / 1000)
      ).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.png]
      panel.title = localized("Save Image")
      panel.prompt = localized("Save")
      panel.nameFieldStringValue = "Polka-\(timestamp).png"
      panel.canCreateDirectories = true
      let answer = await withCheckedContinuation { continuation in
        panel.beginSheetModal(for: owner) { continuation.resume(returning: $0) }
      }
      if answer == .OK, let url = panel.url {
        do {
          try data.write(to: url)
          model.notice = localized("Image Saved")
        } catch { throw PolkaCoreError.invalid(nativeImageSaveError(error)) }
      }
    case "clipboardHistory.revealStorage":
      let path =
        command.strings["store"] == "sync"
        ? sync.state().storage.path : history.storage.state().path
      if !fixture {
        if FileManager.default.fileExists(atPath: path) {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
          let root = URL(fileURLWithPath: history.storage.state().path).deletingLastPathComponent()
            .deletingLastPathComponent()
          guard NSWorkspace.shared.open(root) else {
            throw PolkaCoreError.invalid(localized("Could not open the storage folder"))
          }
        }
      }
    case "shelf.selectEmoji", "shelf.copyEmoji":
      guard let emoji = EmojiCatalog.shared.byID(id) else {
        throw PolkaCoreError.invalid(localized("Emoji not found"))
      }
      try await copy(
        ClipboardClip(
          id: id, kind: .text, content: emoji.value, preview: emoji.value, createdAt: 0),
        selection: command.name.contains("select"))
    case "shelf.copyCalculation":
      guard
        let value = Calculator.calculate(
          command.strings["expression"] ?? "",
          context: CalculationContext(
            now: calculationDate, sourceDate: command.strings["sourceDate"])),
        value.status == .result, let text = value.value
      else { throw PolkaCoreError.invalid(localized("Could not calculate the result")) }
      capture.write(text: text)
      model.notice = localized("Result Copied")
    case "shelf.files.add":
      try files.add(command.ids)
      await filesDropped?()
    case "shelf.files.remove": files.remove(command.ids)
    case "shelf.files.clear": files.clear()
    case "system.login":
      if !fixture {
        if command.bools["enabled"] == true {
          try SMAppService.mainApp.register()
        } else {
          try await SMAppService.mainApp.unregister()
        }
      }
    case "settings.language":
      guard let preference = AppLanguagePreference(rawValue: command.strings["value"] ?? "") else {
        throw PolkaCoreError.invalid(localized("Invalid settings"))
      }
      // Persist before updating presentation, so a failed write preserves the selection.
      try settings.set(key: AppLanguagePreference.settingsKey, value: preference.rawValue)
      model.settings.languagePreference = preference
      updateSystemLanguage()
    case "settings.set":
      let key = command.strings["key"] ?? ""
      try settings.set(
        key: key, value: command.bools["value"] ?? (command.strings["value"] == "true"))
      if key == "shelfIntroduced" { model.settings.introduced = true }
    case "clipboardHistory.syncEnabled":
      try await sync.setEnabled(command.bools["enabled"] ?? false)
    case "clipboardHistory.syncInvite": try sync.invite()
    case "clipboardHistory.syncCancelInvite": sync.cancelInvite()
    case "clipboardHistory.copyPairingCode":
      guard let code = sync.state().invitation?.code else {
        throw PolkaCoreError.invalid(localized("Get a new code"))
      }
      capture.write(text: code, concealed: true)
    case "clipboardHistory.syncPair": try await sync.pair(command.strings["code"] ?? "")
    case "clipboardHistory.syncForget": try await sync.forget(id)
    case "clipboardHistory.syncNow": await sync.syncNow()
    case "updates.check": try updates.check()
    case "updates.install": try await updates.install()
    case "updates.skip": try await updates.skip(version: command.strings["version"])
    case "updates.remind": try await updates.remind(version: command.strings["version"])
    case "mediaIndicator.setTracking":
      try mediaTracking?(command.strings["device"] ?? "", command.bools["enabled"] ?? false)
    case "system.quit": DispatchQueue.main.async { NSApp.terminate(nil) }
    default:
      throw PolkaCoreError.invalid(
        localized("Unknown operation: {0}", String(describing: command.name)))
    }
  }
  func shutdown() async {
    updates.cancelForQuit(explicitUpdate: updates.installationAuthorized)
    disposed = true
    startupTask?.cancel()
    initializationTask?.cancel()
    maintenance?.invalidate()
    capture.stop()
    probe.stop()
    fileProbe.stop()
    shortcuts?.stop()
    await sync.stop()
    await capture.waitForStop()
    history.flush()
    settings.close()
  }
}

func nativeImageSaveError(_ error: Error) -> String {
  var current = error as NSError
  var detail = localized("Choose another folder and try again.")
  for _ in 0..<4 {
    if current.domain == NSPOSIXErrorDomain {
      if current.code == ENOENT {
        detail = localized("The folder no longer exists. Choose another folder.")
      } else if current.code == EACCES || current.code == EPERM {
        detail = localized("No access to the file. Choose another folder or name.")
      } else if current.code == ENOSPC {
        detail = localized("There is no free disk space.")
      }
    } else if current.domain == NSCocoaErrorDomain {
      if [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(current.code) {
        detail = localized("The folder no longer exists. Choose another folder.")
      } else if [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(
        current.code)
      {
        detail = localized("No access to the file. Choose another folder or name.")
      } else if current.code == NSFileWriteOutOfSpaceError {
        detail = localized("There is no free disk space.")
      }
    }
    guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
    current = underlying
  }
  return localized("Could not save the image. ") + detail
}
