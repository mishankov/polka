import AppKit
import Combine
import SwiftUI

/// Commands deliberately follow the existing public feature names. Platform services
/// are injected, which also permits keyboard tests without a system pasteboard.
struct NativeUICommand {
  var name: String
  var strings: [String: String] = [:]
  var bools: [String: Bool] = [:]
  var ints: [String: Int] = [:]
  var ids: [String] = []
  init(
    _ name: String, strings: [String: String] = [:], bools: [String: Bool] = [:],
    ints: [String: Int] = [:], ids: [String] = []
  ) {
    self.name = name
    self.strings = strings
    self.bools = bools
    self.ints = ints
    self.ids = ids
  }
}
struct NativeUIClip: Identifiable, Equatable {
  var id: String
  var kind: String = "text"
  var content: String = ""
  var preview: String = ""
  var createdAt: Double = 0
  var pinned: Bool = false
  var snippet: Bool = false
  var name: String = ""
  var sourceDevice: String = ""
  var ocrStatus: String = ""
  var ocrText: String = ""
  var ocrLanguages: [String] = []
}
struct NativeUIApp: Identifiable, Equatable {
  var id: String
  var name: String
  var icon: String = ""
  var detail: String = ""
}
struct NativeUIEmoji: Identifiable {
  var id: String
  var value: String
  var name: String
  var englishName: String = ""
}
struct NativeUIFile: Identifiable, Equatable {
  var id: String
  var name: String
  var path: String
  var available: Bool = true
  var directory: Bool = false
}
struct NativeUISearchRow: Identifiable, Equatable {
  var id: String
  var kind: String  // app, clip, calculation, more-clips, more-snippets
  var title: String
  var detail: String = ""
  var icon: String = ""
  var clipID: String = ""
  var expression: String = ""
  var sourceDate: String = ""
  var snippet: Bool = false
}
struct NativeUIPeer: Identifiable, Equatable {
  var id: String
  var name: String
  var status: String = "offline"
  var lastSync: Double = 0
  var error: String = ""
}
struct NativeUISettings: Equatable {
  var login = false
  var paused = false
  var pasteOnSelect = true
  var hoverEnabled = true
  var retentionDays = 7
  var launcherShortcut = "CommandOrControl+Shift+Space"
  var clipboardShortcut = "CommandOrControl+Shift+V"
  var launcherShortcutError = ""
  var cameraEnabled = true
  var microphoneEnabled = true
  var mediaActivity = ""
  var syncEnabled = false
  var syncStatus = "disabled"
  var syncStorageStatus = "ready"
  var syncStorageError = ""
  var syncStoragePath = ""
  var syncStorageStage = ""
  var syncStorageCode = ""
  var syncError = ""
  var deviceName = ""
  var peers: [NativeUIPeer] = []
  var nearby: [String] = []
  var invitation = ""
  var invitationExpiresAt: Double = 0
  var updateStatus = "idle"
  var currentVersion = ""
  var updateVersion = ""
  var updateMessage = ""
  var updateNotes = ""
  var updateNotesRussian = ""
  var updateNotesEnglish = ""
  var updateProgress = 0.0
  var updateNotification = ""
  var updateRemindAfter: Double = 0
  var introduced = false
}
struct NativeSnippetDraft: Equatable {
  var id: String = ""
  var name: String = ""
  var content: String = ""
  var expectedName: String = ""
  var expectedContent: String = ""
}
struct NativeBrowseContext {
  var query: String
  var selectedID: String?
  var previewID: String?
  var transformation: String?
  var draft: NativeSnippetDraft?
  var category: String
  var tone: String
  var scrollID: String?
  var listScrollOffset: CGFloat
  var previewScrollOffset: CGFloat
  var selectedFiles: Set<String>
  var fileAnchor: String?
  var savedAt: Date
}

@MainActor final class NativeUIModel: ObservableObject {
  @Published var destination = "apps"
  @Published var visible = false
  @Published var topInset: CGFloat = 0
  @Published var query = ""
  @Published var clips: [NativeUIClip] = [] {
    didSet {
      if clips != oldValue {
        cachedSearch = nil
        cachedClips = nil
      }
    }
  }
  @Published var snippets: [NativeUIClip] = [] {
    didSet {
      if snippets != oldValue {
        cachedSearch = nil
        cachedClips = nil
      }
    }
  }
  @Published var files: [NativeUIFile] = []
  @Published var incomingFileDropTargeted = false
  @Published var incomingFileDropPending = false
  var incomingFileDropToken: UUID?
  @Published var apps: [NativeUIApp] = [] { didSet { if apps != oldValue { cachedSearch = nil } } }
  @Published var settings = NativeUISettings()
  @Published var storageStatus = "starting"
  @Published var preferencesAvailable = false
  @Published var storageDiagnosticStage = ""
  @Published var storageDiagnosticCode = ""
  @Published var storagePath = ""
  @Published var storageError = ""
  @Published var helperStatus = "starting"
  @Published var helperError = ""
  @Published var pasteAccess = "required"
  @Published var pasteReady = false
  @Published var busy = false
  @Published var error = ""
  @Published var notice = ""
  @Published var selectedID: String?
  @Published var previewID: String?
  @Published var previewImage: NSImage?
  @Published var transformation: String?
  @Published var draft: NativeSnippetDraft?
  @Published var confirmClear = false
  @Published var selectedFiles: Set<String> = []
  @Published var emojiCategory = "all"
  @Published var emojiTone = "default"
  @Published var listScrollOffset: CGFloat = 0
  @Published var previewScrollOffset: CGFloat = 0
  @Published var scrollID: String?
  @Published var catalogLoading = true
  @Published var catalogError = ""
  @Published var searchRevision = 0
  @Published var pairingCode = ""
  @Published var selectedPeerID: String?
  @Published var settingsPane = "general"
  var settingsPaneChanged: ((String) -> Void)?
  var action: ((NativeUICommand) async throws -> Void)?
  var searchProvider: ((String) -> [NativeUISearchRow])? { didSet { cachedSearch = nil } }
  var emojiProvider: ((String, String, String) -> [NativeUIEmoji])? { didSet { cachedEmoji = nil } }
  var calculationStatusProvider: ((String) -> String?)? { didSet { cachedCalculationStatus = nil } }
  var fileDragURLs: (([String]) throws -> [URL])?
  var fileDragStarted: (() -> Void)?
  var fileDragEnded: (() -> Void)?
  private var cachedClips: (destination: String, query: String, rows: [NativeUIClip])?
  private var cachedEmoji: (query: String, category: String, tone: String, rows: [NativeUIEmoji])?
  private var cachedSearch: (query: String, revision: Int, rows: [NativeUISearchRow])?
  private var cachedCalculationStatus: (query: String, revision: Int, value: String?)?
  private var contexts: [String: NativeBrowseContext] = [:]
  private var pending = false
  private var presentationRevision = 0
  var sessionRevision: Int { presentationRevision }
  var fileAnchor: String?
  var writable: Bool { storageStatus == "ready" }
  var canPaste: Bool { settings.pasteOnSelect && pasteAccess == "granted" && pasteReady }
  var preview: NativeUIClip? { (clips + snippets).first { $0.id == previewID } }
  var clipResults: [NativeUIClip] {
    if let cachedClips, cachedClips.destination == destination, cachedClips.query == query {
      return cachedClips.rows
    }
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
    let rows = (destination == "snippets" ? snippets : clips).filter { clip in
      let text =
        (clip.name + " " + (clip.kind == "image" ? "Изображение " + clip.ocrText : clip.content))
        .lowercased()
      return terms.allSatisfy { text.contains($0) }
    }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.createdAt > $1.createdAt }
    cachedClips = (destination, query, rows)
    return rows
  }
  // Rendering, hover selection and scrolling share one result snapshot. Only
  // search inputs invalidate it; selection must never repeat catalog ranking.
  var searchResults: [NativeUISearchRow] {
    if let cachedSearch, cachedSearch.query == query, cachedSearch.revision == searchRevision {
      return cachedSearch.rows
    }
    let rows =
      searchProvider?(query)
      ?? apps.map {
        NativeUISearchRow(id: $0.id, kind: "app", title: $0.name, detail: $0.detail, icon: $0.icon)
      }
    cachedSearch = (query, searchRevision, rows)
    return rows
  }
  var calculationStatus: String? {
    if let cachedCalculationStatus, cachedCalculationStatus.query == query,
      cachedCalculationStatus.revision == searchRevision
    {
      return cachedCalculationStatus.value
    }
    let value = calculationStatusProvider?(query)
    cachedCalculationStatus = (query, searchRevision, value)
    return value
  }
  var emojiResults: [NativeUIEmoji] {
    if let cachedEmoji, cachedEmoji.query == query, cachedEmoji.category == emojiCategory,
      cachedEmoji.tone == emojiTone
    {
      return cachedEmoji.rows
    }
    let rows = emojiProvider?(query, emojiCategory, emojiTone) ?? []
    cachedEmoji = (query, emojiCategory, emojiTone, rows)
    return rows
  }
  var selectedClip: NativeUIClip? {
    let rows = clipResults
    return rows.first { $0.id == selectedID } ?? rows.first
  }
  var selectedSearch: NativeUISearchRow? {
    let rows = searchResults
    return rows.first { $0.id == selectedID } ?? rows.first
  }
  var selectedEmoji: NativeUIEmoji? {
    let rows = emojiResults
    return rows.first { $0.id == selectedID } ?? rows.first
  }
  var previewText: String {
    guard let clip = preview else { return "" }
    return transformed(clip.content)
  }
  func transformed(_ text: String) -> String {
    transformation == "upperCase"
      ? text.uppercased() : transformation == "lowerCase" ? text.lowercased() : text
  }
  func perform(_ command: NativeUICommand, completion: (() -> Void)? = nil) {
    guard !pending else { return }
    pending = true
    busy = true
    error = ""
    let revision = presentationRevision
    Task { @MainActor in
      defer {
        pending = false
        busy = false
      }
      do {
        guard let action else {
          throw NSError(
            domain: "Polka", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Действие пока недоступно."])
        }
        try await action(command)
        if revision == presentationRevision { completion?() }
      } catch { if revision == presentationRevision { self.error = error.localizedDescription } }
    }
  }
  func saveContext(now: Date = Date()) {
    guard ["apps", "clipboard", "snippets", "emoji", "files"].contains(destination) else { return }
    contexts[destination] = NativeBrowseContext(
      query: query, selectedID: selectedID, previewID: previewID, transformation: transformation,
      draft: draft, category: emojiCategory, tone: emojiTone, scrollID: scrollID,
      listScrollOffset: listScrollOffset, previewScrollOffset: previewScrollOffset,
      selectedFiles: selectedFiles, fileAnchor: fileAnchor, savedAt: now)
  }
  /// Call only after a panel presentation commits, preserving drafts when a
  /// preparation is superseded. Shelf apps resume their browsing context for 60 s.
  func present(
    destination next: String, resume: Bool = false, searchQuery: String? = nil,
    sourceClipID: String? = nil, now: Date = Date()
  ) {
    if visible { saveContext(now: now) }
    presentationRevision += 1
    incomingFileDropTargeted = false
    incomingFileDropPending = false
    incomingFileDropToken = nil
    destination = next
    visible = true
    error = ""
    notice = ""
    confirmClear = false
    query = searchQuery ?? ""
    selectedID = nil
    previewID = nil
    previewImage = nil
    transformation = nil
    draft = nil
    scrollID = nil
    listScrollOffset = 0
    previewScrollOffset = 0
    emojiCategory = "all"
    emojiTone = "default"
    selectedFiles = []
    fileAnchor = nil
    if resume, let context = contexts[next], now.timeIntervalSince(context.savedAt) <= 60 {
      query = context.query
      selectedID = context.selectedID
      previewID = context.previewID
      transformation = context.transformation
      draft = context.draft
      emojiCategory = context.category
      emojiTone = context.tone
      scrollID = context.scrollID
      listScrollOffset = context.listScrollOffset
      previewScrollOffset = context.previewScrollOffset
      let currentFiles = Set(files.map(\.id))
      selectedFiles = context.selectedFiles.intersection(currentFiles)
      fileAnchor = context.fileAnchor.flatMap { currentFiles.contains($0) ? $0 : nil }
    }
    // An unsaved editor survives fresh invocations too; deliberate cancellation
    // is the only local operation that discards its text.
    if next == "snippets", draft == nil, let context = contexts[next],
      let savedDraft = context.draft
    {
      draft = savedDraft
    }
    if draft == nil, let sourceClipID,
      let clip = (clips + snippets).first(where: { $0.id == sourceClipID }), clip.kind == "text"
    {
      draft = NativeSnippetDraft(
        id: clip.snippet ? clip.id : "", name: clip.name, content: clip.content,
        expectedName: clip.name, expectedContent: clip.content)
    }
  }
  func conceal(now: Date = Date()) {
    saveContext(now: now)
    visible = false
    incomingFileDropTargeted = false
    incomingFileDropPending = false
    incomingFileDropToken = nil
  }
  func navigate(_ destination: String) {
    guard !busy else { return }
    if visible { saveContext() }
    perform(NativeUICommand("launcher.show", strings: ["destination": destination]))
  }
  func back() {
    guard !busy else { return }
    if draft != nil {
      draft = nil
      contexts[destination]?.draft = nil
    } else if confirmClear {
      confirmClear = false
    } else if previewID != nil {
      previewID = nil
      transformation = nil
      previewImage = nil
    } else {
      navigate("apps")
    }
  }
  func edit(_ clip: NativeUIClip) {
    guard writable, !busy, clip.kind == "text" else { return }
    if destination != "snippets" {
      perform(NativeUICommand("shelf.showSnippets", strings: ["sourceClipId": clip.id]))
      return
    }
    draft = NativeSnippetDraft(
      id: clip.snippet ? clip.id : "", name: clip.name, content: clip.content,
      expectedName: clip.name, expectedContent: clip.content)
  }
  func createSnippet() {
    guard writable, !busy, draft == nil else { return }
    draft = NativeSnippetDraft()
  }
  func saveSnippet() {
    guard writable, !busy, let draft, !draft.content.isEmpty else { return }
    let method = draft.id.isEmpty ? "clipboardHistory.createSnippet" : "clipboardHistory.edit"
    perform(
      NativeUICommand(
        method,
        strings: [
          "id": draft.id, "name": draft.name, "content": draft.content,
          "expectedName": draft.expectedName, "expectedContent": draft.expectedContent,
        ])
    ) { [weak self] in
      self?.draft = nil
      self?.contexts[self?.destination ?? ""]?.draft = nil
    }
  }
  func openPreview(_ clip: NativeUIClip) {
    guard !busy else { return }
    previewID = clip.id
    transformation = nil
    previewImage = nil
    previewScrollOffset = 0
    if clip.kind == "image" {
      perform(NativeUICommand("clipboardHistory.preview", strings: ["id": clip.id]))
    }
  }
  func removeClip(_ clip: NativeUIClip) {
    guard writable, !busy else { return }
    perform(NativeUICommand("clipboardHistory.remove", strings: ["id": clip.id])) { [weak self] in
      if self?.previewID == clip.id {
        self?.previewID = nil
        self?.transformation = nil
      }
    }
  }
  func chooseClip(_ clip: NativeUIClip, copyOnly: Bool = false) {
    var params = ["id": clip.id]
    if previewID != nil, let transformation { params["transformation"] = transformation }
    perform(
      NativeUICommand(
        copyOnly ? "clipboardHistory.copy" : "clipboardHistory.select", strings: params))
  }
  func activateSearch(_ row: NativeUISearchRow, copyOnly: Bool = false) {
    switch row.kind {
    case "clip":
      perform(
        NativeUICommand(
          copyOnly ? "clipboardHistory.copy" : "clipboardHistory.select",
          strings: ["id": row.clipID.isEmpty ? row.id : row.clipID]))
    case "calculation":
      perform(
        NativeUICommand(
          "shelf.copyCalculation",
          strings: ["expression": row.expression, "sourceDate": row.sourceDate])
      ) { [weak self] in self?.notice = "Результат скопирован" }
    case "more-clips", "more-snippets":
      perform(
        NativeUICommand(
          row.kind == "more-clips" ? "clipboardHistory.show" : "shelf.showSnippets",
          strings: ["query": query]))
    default: perform(NativeUICommand("launcher.openMac", strings: ["id": row.id]))
    }
  }
  func chooseEmoji(_ emoji: NativeUIEmoji, copyOnly: Bool = false) {
    perform(
      NativeUICommand(copyOnly ? "shelf.copyEmoji" : "shelf.selectEmoji", strings: ["id": emoji.id])
    )
  }
  func installUpdate() {
    guard !busy, settings.updateStatus == "ready" else { return }
    perform(NativeUICommand("updates.install", strings: ["version": settings.updateVersion]))
  }
  func preference(_ key: String, _ value: Bool) {
    perform(NativeUICommand("clipboardHistory.preferences", bools: [key: value]))
  }
  func selectFile(_ id: String, modifiers: NSEvent.ModifierFlags) {
    guard !busy else { return }
    if modifiers.contains(.shift), let anchor = fileAnchor,
      let first = files.firstIndex(where: { $0.id == anchor }),
      let last = files.firstIndex(where: { $0.id == id })
    {
      selectedFiles = Set(files[min(first, last)...max(first, last)].map(\.id))
    } else if modifiers.contains(.command) || modifiers.contains(.control) {
      if selectedFiles.contains(id) { selectedFiles.remove(id) } else { selectedFiles.insert(id) }
      fileAnchor = id
    } else {
      selectedFiles = [id]
      fileAnchor = id
    }
  }
  func removeSelectedFiles(clear: Bool = false) {
    guard !busy, clear ? !files.isEmpty : !selectedFiles.isEmpty else { return }
    perform(
      NativeUICommand(clear ? "shelf.files.clear" : "shelf.files.remove", ids: Array(selectedFiles))
    )
  }
}

func nativeShortcutLabel(_ value: String) -> String {
  value.replacingOccurrences(of: "CommandOrControl+", with: "⌘").replacingOccurrences(
    of: "Command+", with: "⌘"
  ).replacingOccurrences(of: "Control+", with: "⌃").replacingOccurrences(of: "Alt+", with: "⌥")
    .replacingOccurrences(of: "Shift+", with: "⇧").replacingOccurrences(of: "Space", with: "Пробел")
}
func nativeClipDate(_ milliseconds: Double) -> String {
  let date = Date(timeIntervalSince1970: milliseconds / 1000)
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "ru_RU")
  formatter.dateFormat =
    Calendar.current.isDateInToday(date)
    ? "'Сегодня,' HH:mm"
    : Calendar.current.isDateInYesterday(date) ? "'Вчера,' HH:mm" : "d MMM, HH:mm"
  return formatter.string(from: date)
}
func nativeWebURL(_ text: String) -> URL? {
  let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard
    !value.contains(where: {
      $0.isWhitespace || $0 == "\\"
        || $0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }), let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
    let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
  else { return nil }
  return url
}

func nativeClipboardSnippet(_ clip: NativeUIClip, query: String) -> String {
  if clip.kind == "image", clip.ocrText.isEmpty { return "Изображение" }
  let source = clip.kind == "image" ? clip.ocrText : clip.content
  let text = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  let term = query.lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
  let characters = Array(text)
  let lower = text.lowercased()
  let offset =
    lower.range(of: term).map { lower.distance(from: lower.startIndex, to: $0.lowerBound) } ?? 0
  let start = min(characters.count, max(0, offset - 30))
  let end = min(characters.count, start + 160)
  return (start > 0 ? "…" : "") + String(characters[start..<end])
    + (end < characters.count ? "…" : "")
}
