import Foundation
import Security

private struct SavedSync: Codable, Equatable {
  var device: String
  var counter: Int64
  var clear: Stamp?
  var entries: [String: SyncEntry]
  private enum CodingKeys: String, CodingKey { case device, counter, clear, entries }
  init(device: String, counter: Int64, clear: Stamp? = nil, entries: [String: SyncEntry]) {
    self.device = device
    self.counter = counter
    self.clear = clear
    self.entries = entries
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    device = try c.decode(String.self, forKey: .device)
    counter = try c.decode(Int64.self, forKey: .counter)
    clear = try c.decodeOptional(Stamp.self, forKey: .clear)
    entries = try c.decode([String: SyncEntry].self, forKey: .entries)
  }
}
private struct SavedHistory: Codable, Equatable {
  var version = 1
  var preferences = ClipboardPreferences()
  var clips: [ClipboardClip] = []
  var snippets: [ClipboardClip] = []
  var sync: SavedSync?
  private enum CodingKeys: String, CodingKey { case version, preferences, clips, snippets, sync }
  init() {}
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(Int.self, forKey: .version)
    preferences = try c.decode(ClipboardPreferences.self, forKey: .preferences)
    clips = try c.decode([ClipboardClip].self, forKey: .clips)
    snippets = try c.decodeOptional([ClipboardClip].self, forKey: .snippets) ?? []
    sync = try c.decodeOptional(SavedSync.self, forKey: .sync)
  }
  func validate() throws {
    guard version == 1, clips.count <= ClipboardLimits.maxHistoryItems else {
      throw PolkaCoreError.invalid("Некорректный формат истории")
    }
    try preferences.validate()
    for clip in clips { try clip.validate() }
    for clip in snippets { try clip.validate(requireSnippet: true) }
    try validateSnippets()
    if let sync {
      guard validDeviceID(sync.device), sync.counter >= 0, sync.counter <= 9_007_199_253_740_991,
        sync.entries.keys.allSatisfy(validClipID)
      else { throw PolkaCoreError.invalid("Некорректные данные синхронизации") }
      try sync.clear?.validate()
      for entry in sync.entries.values { try entry.validate() }
    }
  }
  func validateSnippets() throws {
    guard snippets.count <= ClipboardLimits.maxSnippetItems else {
      throw PolkaCoreError.invalid("Можно сохранить не больше 200 сниппетов")
    }
    guard
      snippets.reduce(0, { $0 + $1.content.utf8.count + $1.preview.utf8.count })
        <= ClipboardLimits.maxSnippetsBytes
    else { throw PolkaCoreError.invalid("Хранилище сниппетов не должно превышать 128 МБ") }
  }
  var records: [ClipboardClip] { clips + snippets }
}
/// Serialized, encrypted, atomic history. Codec and clock injection keep tests isolated from user data.
public final class ClipboardHistory {
  private var state = SavedHistory()
  private let path: URL
  private let codec: EncryptionCodec
  private let changed: () -> Void
  private let now: () -> Double
  private let lock = NSRecursiveLock()
  private var incarnations: [String: Int] = [:]
  public let storage: ClipboardStorage
  public private(set) var preferencesAvailable = false
  public init(
    path: URL, codec: EncryptionCodec, changed: @escaping () -> Void = {},
    now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }
  ) {
    self.path = path
    self.codec = codec
    self.changed = changed
    self.now = now
    storage = ClipboardStorage(path: path, changed: changed)
  }
  private func serialized<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }
  public func initialize() throws {
    try serialized {
      let data: Data? = try storage.run("read") {
        try readEncryptedFile(
          path,
          maximumBytes: (ClipboardLimits.maxHistoryBytes + ClipboardLimits.maxSnippetsBytes) * 3)
      }
      if let data {
        let decoded = try storage.run("decrypt") { try codec.decode(data) }
        state = try storage.run("parse") {
          let saved = try decodeClipboardJSON(SavedHistory.self, from: decoded)
          try saved.validate()
          return saved
        }
      }
      if state.sync == nil {
        state.sync = SavedSync(device: UUID().uuidString.lowercased(), counter: 0, entries: [:])
        for clip in state.records {
          let s = stamp(&state)
          state.sync!.entries[clip.id] = SyncEntry(
            snippet: clip.snippet, added: s, pin: SyncPin(stamp: s, value: clip.pinned), seen: s)
        }
      }
      preferencesAvailable = true
      try storage.loaded()
      if state.clips.contains(where: { $0.isSnippet }) {
        try update { next in
          var merged: [String: ClipboardClip] = [:]
          var order: [String] = []
          for clip in next.clips.filter({ $0.isSnippet }) + next.snippets {
            try clip.validate(requireSnippet: true)
            if merged[clip.id] == nil { order.append(clip.id) }
            merged[clip.id] = clip
          }
          next.snippets = order.compactMap { merged[$0] }
          next.clips.removeAll { $0.isSnippet }
          for clip in next.snippets {
            var entry = next.sync!.entries[clip.id] ?? SyncEntry()
            let s = entry.added ?? self.stamp(&next)
            if entry.added == nil { entry.added = s }
            if entry.seen == nil { entry.seen = s }
            if entry.pin == nil { entry.pin = SyncPin(stamp: s, value: clip.pinned) }
            entry.snippet = true
            next.sync!.entries[clip.id] = entry
          }
        }
      }
      try prune()
    }
  }
  private func stamp(_ next: inout SavedHistory) -> Stamp {
    next.sync!.counter = max(next.sync!.counter + 1, Int64(now().rounded(.down)))
    return Stamp(counter: next.sync!.counter, device: next.sync!.device)
  }
  public var deviceId: String { serialized { state.sync?.device ?? "" } }
  public func getPreferences() -> ClipboardPreferences {
    serialized {
      guard preferencesAvailable else {
        return ClipboardPreferences(
          paused: true, pasteOnSelect: false, hoverEnabled: false, accelerator: "")
      }
      return state.preferences
    }
  }
  public func snapshot(includeImageContent: Bool = true) -> ClipboardSnapshot {
    serialized {
      var clips = state.clips.filter { !$0.isSnippet }
      if !includeImageContent {
        for i in clips.indices where clips[i].kind == .image { clips[i].content = "" }
      }
      return ClipboardSnapshot(
        preferences: getPreferences(), clips: clips,
        snippets: state.records.filter { $0.isSnippet && $0.kind == .text })
    }
  }
  public func find(_ id: String) -> ClipboardClip? {
    serialized { state.records.first { $0.id == id } }
  }
  private func trim(_ next: inout SavedHistory) {
    next.clips = next.clips.filter {
      $0.pinned || now() - $0.createdAt < Double(next.preferences.retentionDays) * 86_400_000
    }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.createdAt > $1.createdAt }
    var size = 0
    next.clips = next.clips.enumerated().filter { index, clip in
      size += clip.content.utf8.count + clip.preview.utf8.count + (clip.ocr?.text.utf8.count ?? 0)
      return index < ClipboardLimits.maxHistoryItems && size <= ClipboardLimits.maxHistoryBytes
    }.map(\.element)
  }
  private func update(force: Bool = false, _ operation: (inout SavedHistory) throws -> Void) throws
  {
    try serialized {
      try storage.requireReady()
      var next = state
      try operation(&next)
      try next.validateSnippets()
      trim(&next)
      guard force || next != state else { return }
      let encoded = try storage.run("encrypt") { try codec.encode(JSONEncoder().encode(next)) }
      try storage.run("write") {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
          at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = path.appendingPathExtension("tmp")
        do {
          try encoded.write(to: temp)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
          guard rename(temp.path, path.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
          }
        } catch {
          try? FileManager.default.removeItem(at: temp)
          throw error
        }
      }
      for clip in state.clips where !next.clips.contains(where: { $0.id == clip.id }) {
        incarnations[clip.id, default: 0] += 1
      }
      state = next
      changed()
    }
  }
  public func persistIdentity() throws { try update(force: true) { _ in } }
  public func add(_ kind: ClipboardClip.Kind, content: String, preview: String) throws {
    guard !content.isEmpty, content.utf8.count <= ClipboardLimits.maxClipBytes,
      preview.utf16.count <= 200_000
    else { return }
    try update { next in
      guard !next.preferences.paused else { return }
      let id = clipId(kind, content)
      let existing = next.clips.first { $0.id == id }
      next.clips.removeAll { $0.id == id }
      let s = self.stamp(&next)
      var entry = next.sync!.entries[id] ?? SyncEntry()
      entry.added = s
      entry.seen = s
      entry.pin = SyncPin(stamp: s, value: existing?.pinned ?? false)
      next.sync!.entries[id] = entry
      next.clips.insert(
        ClipboardClip(
          id: id, kind: kind, content: content, preview: preview, createdAt: self.now(),
          pinned: existing?.pinned ?? false, ocr: existing?.ocr), at: 0)
    }
  }
  private func snippetText(_ content: String, _ name: String) throws -> String {
    guard !content.isEmpty, content.utf16.count <= ClipboardLimits.maxSnippetTextBytes,
      content.utf8.count <= ClipboardLimits.maxSnippetTextBytes
    else { throw PolkaCoreError.invalid("Текст сниппета не должен превышать 1 МБ") }
    guard name.utf16.count <= 120 else {
      throw PolkaCoreError.invalid("Название не должно превышать 120 символов")
    }
    return name.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private func randomID() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw PolkaCoreError.invalid("Не удалось создать идентификатор")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
  @discardableResult public func createSnippet(content: String, name: String = "") throws -> String
  {
    let name = try snippetText(content, name)
    let id = try randomID()
    try update { next in
      let s = self.stamp(&next)
      next.sync!.entries[id] = SyncEntry(
        snippet: true, added: s, pin: SyncPin(stamp: s, value: true), seen: s)
      next.snippets.insert(
        ClipboardClip(
          id: id, kind: .text, content: content, preview: self.prefix(content, 400),
          createdAt: self.now(), pinned: true, snippet: true, name: name.isEmpty ? nil : name),
        at: 0)
    }
    return id
  }
  private func prefix(_ text: String, _ count: Int) -> String {
    String(decoding: text.utf16.prefix(count), as: UTF16.self)
  }
  @discardableResult public func edit(
    _ id: String, content: String, name: String = "", expected: SnippetExpected? = nil
  ) throws -> String {
    let name = try snippetText(content, name)
    var editedID = id
    try update { next in
      guard var clip = next.records.first(where: { $0.id == id }) else {
        throw PolkaCoreError.invalid("Запись уже удалена")
      }
      guard clip.kind == .text else {
        throw PolkaCoreError.invalid("Редактирование доступно только для текста")
      }
      if let expected,
        !clipboardTextEqual(clip.content, expected.content)
          || !clipboardTextEqual(clip.name, expected.name)
      {
        throw PolkaCoreError.invalid(
          "Сниппет изменился на другом Mac. Откройте его заново перед сохранением.")
      }
      if clip.isSnippet && clipboardTextEqual(clip.content, content)
        && clipboardTextEqual(clip.name ?? "", name)
      {
        return
      }
      let s = self.stamp(&next)
      if !clip.isSnippet {
        editedID = try self.randomID()
        clip.id = editedID
        clip.snippet = true
        clip.pinned = true
        clip.createdAt = self.now()
        next.sync!.entries[editedID] = SyncEntry(snippet: true, pin: SyncPin(stamp: s, value: true))
      }
      clip.content = content
      clip.preview = self.prefix(content, 400)
      clip.name = name.isEmpty ? nil : name
      if let index = next.snippets.firstIndex(where: { $0.id == editedID }) {
        next.snippets[index] = clip
      } else {
        next.snippets.insert(clip, at: 0)
      }
      next.sync!.entries[editedID]!.added = s
      next.sync!.entries[editedID]!.seen = s
    }
    return editedID
  }
  public func setPreferences(_ preferences: ClipboardPreferences) throws {
    try preferences.validate()
    try update { $0.preferences = preferences }
  }
  public func pin(_ id: String, pinned: Bool) throws {
    try update { next in
      guard next.records.contains(where: { $0.id == id }) else {
        throw PolkaCoreError.invalid("Запись уже удалена")
      }
      if let index = next.clips.firstIndex(where: { $0.id == id }) {
        next.clips[index].pinned = pinned
      }
      if let index = next.snippets.firstIndex(where: { $0.id == id }) {
        next.snippets[index].pinned = pinned
      }
      let s = self.stamp(&next)
      var entry = next.sync!.entries[id] ?? SyncEntry()
      entry.pin = SyncPin(stamp: s, value: pinned)
      next.sync!.entries[id] = entry
    }
  }
  public func remove(_ id: String) throws {
    try update { next in
      next.clips.removeAll { $0.id == id }
      next.snippets.removeAll { $0.id == id }
      let s = self.stamp(&next)
      var entry = next.sync!.entries[id] ?? SyncEntry()
      entry.deleted = s
      next.sync!.entries[id] = entry
    }
  }
  public func clear() throws {
    try update { next in
      next.clips = []
      next.sync!.clear = self.stamp(&next)
    }
  }
  public func prune() throws {
    try serialized {
      guard storage.ready,
        state.clips.contains(where: {
          !$0.pinned && now() - $0.createdAt >= Double(state.preferences.retentionDays) * 86_400_000
        })
      else { return }
      try update { _ in }
    }
  }
  public func flush() { serialized {} }
  public func manifest(snippets: Bool = true) throws -> SyncManifest {
    try serialized {
      try storage.requireReady()
      let sync = state.sync!
      let entries = sync.entries.filter { snippets || $0.value.snippet != true }.mapValues {
        entry -> SyncEntry in
        var entry = entry
        entry.seen = nil
        return entry
      }
      return SyncManifest(
        snippets: snippets ? true : nil, clear: sync.clear, entries: entries,
        available: state.records.filter { snippets || !$0.isSnippet }.map(\.id))
    }
  }
  public func mergeManifest(_ remote: SyncManifest) throws -> [String] {
    try serialized {
      try storage.requireReady()
      try remote.validate()
      let current = state.sync!
      let modified =
        compareStamp(remote.clear, current.clear) > 0
        || remote.entries.contains { id, entry in
          guard let local = current.entries[id] else { return true }
          return compareStamp(entry.added, local.added) > 0
            || compareStamp(entry.deleted, local.deleted) > 0
            || compareStamp(entry.pin?.stamp, local.pin?.stamp) > 0
        }
      if modified {
        try update { next in
          var sync = next.sync!
          if compareStamp(remote.clear, sync.clear) > 0 {
            for id in sync.entries.keys where sync.entries[id]!.snippet != true {
              sync.entries[id]!.deleted = newest(
                sync.entries[id]!.deleted, newest(sync.entries[id]!.added, remote.clear))
            }
          }
          sync.clear = newest(sync.clear, remote.clear)
          if let clear = remote.clear { sync.counter = max(sync.counter, clear.counter) }
          for (id, incoming) in remote.entries {
            var local = sync.entries[id] ?? SyncEntry()
            for stamp in [incoming.added, incoming.deleted, incoming.pin?.stamp].compactMap({ $0 })
            { sync.counter = max(sync.counter, stamp.counter) }
            if incoming.pin?.value == true, compareStamp(incoming.pin?.stamp, local.pin?.stamp) > 0,
              !next.records.contains(where: { $0.id == id })
            {
              local.seen = nil
            }
            local.snippet = local.snippet == true || incoming.snippet == true ? true : nil
            local.added = newest(local.added, incoming.added)
            local.deleted = newest(local.deleted, incoming.deleted)
            if compareStamp(incoming.pin?.stamp, local.pin?.stamp) > 0 { local.pin = incoming.pin }
            sync.entries[id] = local
          }
          next.sync = sync
          next.clips = next.clips.filter { liveEntry(sync.entries[$0.id]!, sync.clear) }.map {
            var c = $0
            c.pinned = sync.entries[c.id]?.pin?.value ?? false
            return c
          }
          next.snippets = next.snippets.filter { liveEntry(sync.entries[$0.id]!, sync.clear) }.map {
            var c = $0
            c.pinned = sync.entries[c.id]?.pin?.value ?? false
            return c
          }
        }
      }
      return remote.available.filter { id in
        guard let entry = state.sync!.entries[id] else { return false }
        return liveEntry(entry, state.sync!.clear) && compareStamp(entry.added, entry.seen) > 0
      }
    }
  }
  public func transfer(_ id: String) -> ClipTransfer? {
    serialized {
      guard var clip = state.records.first(where: { $0.id == id }),
        let stamp = state.sync?.entries[id]?.seen
      else { return nil }
      clip.ocr = nil
      return ClipTransfer(clip: clip, stamp: stamp)
    }
  }
  public func receive(_ transfer: ClipTransfer, sourceDevice: String) throws {
    try serialized {
      try storage.requireReady()
      var clip = transfer.clip
      clip.ocr = nil
      try clip.validate()
      try transfer.stamp.validate()
      guard !clip.content.isEmpty, clip.content.utf8.count <= ClipboardLimits.maxClipBytes else {
        throw PolkaCoreError.invalid("Некорректная запись буфера")
      }
      if clip.isSnippet {
        guard clip.kind == .text, clip.content.utf8.count <= ClipboardLimits.maxSnippetTextBytes,
          state.sync?.entries[clip.id]?.snippet == true
        else { throw PolkaCoreError.invalid("Некорректный сниппет") }
      } else {
        guard clipId(clip.kind, clip.content) == clip.id else {
          throw PolkaCoreError.invalid("Некорректная запись буфера")
        }
      }
      if clip.kind == .image {
        guard clip.content.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil,
          let png = Data(base64Encoded: clip.content), png.count <= ClipboardLimits.maxImageBytes,
          png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
          clip.preview.range(
            of: "^data:image/png;base64,[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil
        else { throw PolkaCoreError.invalid("Некорректное изображение буфера") }
      } else {
        clip.preview = prefix(clip.content, 400)
      }
      try update { next in
        guard var entry = next.sync!.entries[clip.id], clip.isSnippet == (entry.snippet == true),
          compareStamp(transfer.stamp, entry.added) == 0, liveEntry(entry, next.sync!.clear),
          compareStamp(transfer.stamp, entry.seen) > 0
        else { return }
        entry.seen = transfer.stamp
        next.sync!.entries[clip.id] = entry
        clip.ocr = next.clips.first(where: { $0.id == clip.id })?.ocr
        next.clips.removeAll { $0.id == clip.id }
        next.snippets.removeAll { $0.id == clip.id }
        clip.pinned = entry.pin?.value ?? false
        clip.sourceDevice = clip.sourceDevice ?? sourceDevice
        if clip.isSnippet { next.snippets.append(clip) } else { next.clips.append(clip) }
      }
    }
  }
  public func imageTextImages() -> [ImageTextImage] {
    serialized {
      state.clips.filter { $0.kind == .image }.map {
        ImageTextImage(
          id: $0.id, content: $0.content, ocr: $0.ocr, incarnation: incarnations[$0.id] ?? 0)
      }
    }
  }
  public func saveImageText(_ id: String, incarnation: Int, result: ImageText) throws {
    try result.validate()
    try update { next in
      if let index = next.clips.firstIndex(where: { $0.id == id && $0.kind == .image }),
        (self.incarnations[id] ?? 0) == incarnation
      {
        next.clips[index].ocr = result
      }
    }
  }
  public func retryImageText(_ id: String) throws {
    try update { next in
      guard let index = next.clips.firstIndex(where: { $0.id == id && $0.kind == .image }) else {
        throw PolkaCoreError.invalid("Запись уже удалена")
      }
      guard next.clips[index].ocr?.status == .failed else {
        throw PolkaCoreError.invalid("Распознавание не требует повтора")
      }
      next.clips[index].ocr = nil
    }
  }
}
