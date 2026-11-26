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
      throw PolkaCoreError.invalid(localized("Invalid history format"))
    }
    try preferences.validate()
    for clip in clips { try clip.validate() }
    for clip in snippets { try clip.validate(requireSnippet: true) }
    try validateSnippets()
    if let sync {
      guard validDeviceID(sync.device), sync.counter >= 0, sync.counter <= 9_007_199_253_740_991,
        sync.entries.keys.allSatisfy(validClipID)
      else { throw PolkaCoreError.invalid(localized("Invalid sync data")) }
      try sync.clear?.validate()
      for entry in sync.entries.values { try entry.validate() }
    }
  }
  func validateSnippets() throws {
    guard snippets.count <= ClipboardLimits.maxSnippetItems else {
      throw PolkaCoreError.invalid(localized("You can save up to 200 snippets"))
    }
    guard
      snippets.reduce(0, { $0 + $1.content.utf8.count + $1.preview.utf8.count })
        <= ClipboardLimits.maxSnippetsBytes
    else { throw PolkaCoreError.invalid(localized("Snippet storage must not exceed 128 MB")) }
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
  private var textGroupIDs: [String: String] = [:]
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
      let hadSync = state.sync != nil
      if state.sync == nil {
        state.sync = SavedSync(device: UUID().uuidString.lowercased(), counter: 0, entries: [:])
        let ordered = state.records.filter { $0.kind != .files }.sorted {
          $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id
        }
        for clip in ordered {
          let s = stamp(&state)
          let group =
            clip.kind == .text && !clip.isSnippet
            ? textGroupID(id: clip.id, content: clip.content) : nil
          state.sync!.entries[clip.id] = SyncEntry(
            snippet: clip.snippet, added: s, pin: SyncPin(stamp: s, value: clip.pinned), seen: s,
            group: group)
        }
      }
      textGroupIDs = [:]
      for clip in state.clips where clip.kind == .text && !clip.isSnippet {
        if let persisted = state.sync?.entries[clip.id]?.group {
          textGroupIDs[clip.id] = persisted
        } else {
          let group = textGroupID(id: clip.id, content: clip.content)
          state.sync?.entries[clip.id]?.group = group
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
            entry.group = nil
            next.sync!.entries[clip.id] = entry
          }
        }
      }
      try deduplicateExistingClips(useSyncOrder: hadSync)
      try prune()
      try promoteFileReferences()
    }
  }
  private func textGroupID(id: String, content: String) -> String {
    if let cached = textGroupIDs[id] { return cached }
    let group = clipId(.text, clipboardTextComparisonKey(content))
    textGroupIDs[id] = group
    return group
  }
  private func comparisonGroup(_ clip: ClipboardClip) -> String {
    clip.kind == .text ? textGroupID(id: clip.id, content: clip.content) : clip.id
  }
  private func isClipOrderedBefore(
    _ a: ClipboardClip, _ b: ClipboardClip, in history: SavedHistory, useSyncOrder: Bool
  ) -> Bool {
    if useSyncOrder {
      let order = compareStamp(
        history.sync?.entries[a.id]?.added, history.sync?.entries[b.id]?.added)
      if order != 0 { return order < 0 }
    }
    if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
    return a.id < b.id
  }
  private func isIncomingPreferred(
    clipID: String, stamp: Stamp, createdAt: Double, over local: ClipboardClip,
    in history: SavedHistory
  ) -> Bool {
    let order = compareStamp(stamp, history.sync?.entries[local.id]?.added)
    if order != 0 { return order > 0 }
    if createdAt != local.createdAt { return createdAt > local.createdAt }
    return clipID > local.id
  }
  private func reconcileGroupEntries(_ next: inout SavedHistory, groups: Set<String>) {
    guard !groups.isEmpty else { return }
    var membersByGroup: [String: [String]] = [:]
    for (id, entry) in next.sync!.entries {
      guard let group = entry.group, groups.contains(group),
        entry.snippet != true, entry.files != true
      else { continue }
      membersByGroup[group, default: []].append(id)
    }
    let clear = next.sync!.clear
    for (_, memberIDs) in membersByGroup where memberIDs.count > 1 {
      var maxDeleted: Stamp?
      for id in memberIDs {
        maxDeleted = newest(maxDeleted, next.sync!.entries[id]?.deleted)
      }
      let allAdded = memberIDs.compactMap { next.sync!.entries[$0]?.added }
      if let maxDeleted {
        let isExplicitMaxDelete = !allAdded.contains(where: { compareStamp($0, maxDeleted) == 0 })
        for id in memberIDs {
          guard var entry = next.sync!.entries[id], let added = entry.added,
            compareStamp(maxDeleted, added) > 0
          else { continue }
          entry.deleted = newest(entry.deleted, maxDeleted)
          if isExplicitMaxDelete { entry.superseded = nil }
          next.sync!.entries[id] = entry
        }
      }
      let liveIDs = memberIDs.filter { id in
        guard let entry = next.sync!.entries[id] else { return false }
        return liveEntry(entry, clear)
      }
      guard
        let survivorID = liveIDs.max(by: { a, b in
          let order = compareStamp(next.sync!.entries[a]?.added, next.sync!.entries[b]?.added)
          return order != 0 ? order < 0 : a < b
        }),
        var survivor = next.sync!.entries[survivorID],
        let survivorAdded = survivor.added
      else { continue }
      for id in liveIDs where id != survivorID {
        guard var older = next.sync!.entries[id] else { continue }
        let deleteStamp =
          compareStamp(survivorAdded, older.added) > 0 ? survivorAdded : self.stamp(&next)
        older.deleted = newest(older.deleted, deleteStamp)
        older.superseded = true
        next.sync!.entries[id] = older
      }
      let explicitDeletes: [Stamp] = memberIDs.compactMap { id -> Stamp? in
        guard let deleted = next.sync!.entries[id]?.deleted else { return nil }
        return allAdded.contains(where: { compareStamp($0, deleted) == 0 }) ? nil : deleted
      }
      var latestExplicitPin: SyncPin?
      for id in memberIDs {
        guard let member = next.sync!.entries[id], let pin = member.pin else { continue }
        let isExplicit = pin.value || compareStamp(pin.stamp, member.added) != 0
        guard isExplicit else { continue }
        if id != survivorID {
          if let clear, let memberAdded = member.added, compareStamp(memberAdded, clear) <= 0,
            compareStamp(clear, survivorAdded) < 0
          {
            continue
          }
          let invalidatedByExplicitDelete = explicitDeletes.contains { deleted in
            compareStamp(pin.stamp, deleted) <= 0 && compareStamp(deleted, survivorAdded) < 0
          }
          guard !invalidatedByExplicitDelete else { continue }
        }
        if latestExplicitPin == nil || compareStamp(pin.stamp, latestExplicitPin?.stamp) > 0 {
          latestExplicitPin = pin
        }
      }
      if let latestExplicitPin {
        let currentValue = survivor.pin?.value ?? false
        if latestExplicitPin.value != currentValue {
          if compareStamp(latestExplicitPin.stamp, survivor.pin?.stamp) > 0 {
            survivor.pin = latestExplicitPin
            if latestExplicitPin.value, !next.records.contains(where: { $0.id == survivorID }) {
              survivor.seen = nil
            }
            next.sync!.entries[survivorID] = survivor
          } else if latestExplicitPin.value,
            survivor.pin == nil || compareStamp(survivor.pin?.stamp, survivorAdded) == 0
          {
            survivor.pin = SyncPin(stamp: self.stamp(&next), value: true)
            if !next.records.contains(where: { $0.id == survivorID }) { survivor.seen = nil }
            next.sync!.entries[survivorID] = survivor
          }
        }
      }
    }
  }
  private func deduplicateExistingClips(useSyncOrder: Bool) throws {
    var seen = Set<String>()
    let hasDuplicates = state.clips.contains { clip in
      !clip.isSnippet && !seen.insert(comparisonGroup(clip)).inserted
    }
    guard hasDuplicates else { return }
    try update { next in
      var groups: [String: [ClipboardClip]] = [:]
      var order: [String] = []
      for clip in next.clips where !clip.isSnippet {
        let key = self.comparisonGroup(clip)
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(clip)
      }
      var kept: [ClipboardClip] = []
      for key in order {
        let group = groups[key]!
        guard group.count > 1 else {
          kept.append(group[0])
          continue
        }
        var winner = group.max {
          self.isClipOrderedBefore($0, $1, in: next, useSyncOrder: useSyncOrder)
        }!
        let wasPinned = winner.pinned
        winner.pinned = group.contains(where: \.pinned)
        winner.ocr = winner.ocr ?? group.first(where: { $0.ocr != nil })?.ocr
        winner.createdAt = group.map(\.createdAt).max() ?? winner.createdAt
        let winnerGroup =
          winner.kind == .text ? self.textGroupID(id: winner.id, content: winner.content) : nil
        let winnerAdded = next.sync!.entries[winner.id]?.added
        if winner.kind != .files || winner.fileSource != nil {
          var winnerEntry = next.sync!.entries[winner.id] ?? SyncEntry()
          if let winnerGroup { winnerEntry.group = winnerGroup }
          winnerEntry.superseded = nil
          if winner.pinned, !wasPinned {
            winnerEntry.pin = SyncPin(stamp: self.stamp(&next), value: true)
          }
          next.sync!.entries[winner.id] = winnerEntry
        }
        for old in group where old.id != winner.id && (old.kind != .files || old.fileSource != nil)
        {
          var oldEntry = next.sync!.entries[old.id] ?? SyncEntry()
          if let winnerGroup { oldEntry.group = winnerGroup }
          let deleteStamp: Stamp
          if let winnerAdded, compareStamp(winnerAdded, oldEntry.added) > 0 {
            deleteStamp = winnerAdded
          } else {
            deleteStamp = self.stamp(&next)
          }
          oldEntry.deleted = newest(oldEntry.deleted, deleteStamp)
          oldEntry.superseded = true
          next.sync!.entries[old.id] = oldEntry
        }
        kept.append(winner)
      }
      next.clips = kept
    }
  }
  /// Upgrade local references created before file metadata sync existed.
  private func promoteFileReferences() throws {
    let upgrades = state.clips.filter { $0.kind == .files && $0.fileSource == nil }.compactMap {
      clip -> (String, ClipboardFileSource)? in
      guard let files = try? ClipboardFiles(content: clip.content),
        let source = try? ClipboardFileSource.inspect(files, device: deviceId)
      else { return nil }
      return (clip.id, source)
    }
    guard !upgrades.isEmpty else { return }
    try update { next in
      for (id, source) in upgrades {
        guard let index = next.clips.firstIndex(where: { $0.id == id }) else { continue }
        next.clips[index].fileSource = source
        let stamp = self.stamp(&next)
        next.sync!.entries[id] = SyncEntry(
          files: true, added: stamp, pin: SyncPin(stamp: stamp, value: next.clips[index].pinned),
          seen: stamp)
      }
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
      size +=
        clip.content.utf8.count + clip.preview.utf8.count + (clip.ocr?.text.utf8.count ?? 0)
        + (clip.fileSource.flatMap { try? JSONEncoder().encode($0).count } ?? 0)
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
        textGroupIDs.removeValue(forKey: clip.id)
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
    let fileSource: ClipboardFileSource?
    if kind == .files {
      let files = try ClipboardFiles(content: content)
      fileSource = try? ClipboardFileSource.inspect(files, device: deviceId)
    } else {
      fileSource = nil
    }
    try update { next in
      guard !next.preferences.paused else { return }
      let id = clipId(kind, kind == .files ? self.deviceId + "\0" + content : content)
      let group = kind == .text ? self.textGroupID(id: id, content: content) : nil
      let matching: [ClipboardClip]
      if let group {
        matching = next.clips.filter {
          $0.kind == .text && !$0.isSnippet
            && self.textGroupID(id: $0.id, content: $0.content) == group
        }
      } else {
        matching = next.clips.filter { !$0.isSnippet && $0.id == id }
      }
      let pinned = matching.contains(where: \.pinned)
      let ocr =
        matching.first(where: { $0.id == id })?.ocr ?? matching.first(where: { $0.ocr != nil })?.ocr
      let matchingIDs = Set(matching.map(\.id))
      if !matchingIDs.isEmpty {
        next.clips.removeAll { !$0.isSnippet && matchingIDs.contains($0.id) }
      }
      if kind != .files || fileSource != nil {
        let s = self.stamp(&next)
        for old in matching where old.id != id && (old.kind != .files || old.fileSource != nil) {
          var oldEntry = next.sync!.entries[old.id] ?? SyncEntry()
          if let group { oldEntry.group = group }
          oldEntry.deleted = newest(oldEntry.deleted, s)
          oldEntry.superseded = true
          next.sync!.entries[old.id] = oldEntry
        }
        if let group, !matching.isEmpty {
          for otherID in Array(next.sync!.entries.keys) where otherID != id {
            guard var other = next.sync!.entries[otherID], other.group == group,
              other.superseded == true, other.snippet != true, other.files != true
            else { continue }
            other.deleted = newest(other.deleted, s)
            next.sync!.entries[otherID] = other
          }
        }
        var entry = next.sync!.entries[id] ?? SyncEntry()
        let previousAdded = entry.added
        entry.files = kind == .files ? true : nil
        entry.group = group
        entry.superseded = nil
        entry.added = s
        entry.seen = s
        if pinned {
          let inheritedPin = matching.compactMap { next.sync!.entries[$0.id]?.pin }
            .filter(\.value)
            .max { compareStamp($0.stamp, $1.stamp) < 0 }
          if let inheritedPin,
            entry.pin == nil || compareStamp(inheritedPin.stamp, entry.pin?.stamp) >= 0
          {
            entry.pin = inheritedPin
          } else {
            entry.pin = SyncPin(stamp: s, value: true)
          }
        } else if entry.pin?.value == true {
          entry.pin = SyncPin(stamp: s, value: false)
        } else if let existingPin = entry.pin, compareStamp(existingPin.stamp, previousAdded) == 0 {
          entry.pin = SyncPin(stamp: s, value: false)
        }
        next.sync!.entries[id] = entry
      }
      next.clips.insert(
        ClipboardClip(
          id: id, kind: kind, content: content, preview: preview, createdAt: self.now(),
          pinned: pinned, ocr: ocr, fileSource: fileSource), at: 0)
    }
  }
  private func snippetText(_ content: String, _ name: String) throws -> String {
    guard !content.isEmpty, content.utf16.count <= ClipboardLimits.maxSnippetTextBytes,
      content.utf8.count <= ClipboardLimits.maxSnippetTextBytes
    else { throw PolkaCoreError.invalid(localized("Snippet text must not exceed 1 MB")) }
    guard name.utf16.count <= 120 else {
      throw PolkaCoreError.invalid(localized("The name must not exceed 120 characters"))
    }
    return name.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private func randomID() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw PolkaCoreError.invalid(localized("Could not create an identifier"))
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
        throw PolkaCoreError.invalid(localized("This item has already been deleted"))
      }
      guard clip.kind == .text else {
        throw PolkaCoreError.invalid(localized("Only text can be edited"))
      }
      if let expected,
        !clipboardTextEqual(clip.content, expected.content)
          || !clipboardTextEqual(clip.name, expected.name)
      {
        throw PolkaCoreError.invalid(
          localized("This snippet changed on another Mac. Open it again before saving."))
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
        throw PolkaCoreError.invalid(localized("This item has already been deleted"))
      }
      if let index = next.clips.firstIndex(where: { $0.id == id }) {
        next.clips[index].pinned = pinned
      }
      if let index = next.snippets.firstIndex(where: { $0.id == id }) {
        next.snippets[index].pinned = pinned
      }
      guard
        next.records.first(where: { $0.id == id }).map({ $0.kind != .files || $0.fileSource != nil }
        ) == true
      else { return }
      let s = self.stamp(&next)
      var entry = next.sync!.entries[id] ?? SyncEntry()
      entry.pin = SyncPin(stamp: s, value: pinned)
      next.sync!.entries[id] = entry
    }
  }
  public func remove(_ id: String) throws {
    try update { next in
      let removedClip = next.clips.first(where: { $0.id == id })
      let localFile = removedClip.map { $0.kind == .files && $0.fileSource == nil } ?? false
      let group =
        removedClip.flatMap {
          $0.kind == .text && !$0.isSnippet
            ? self.textGroupID(id: $0.id, content: $0.content) : nil
        } ?? next.sync!.entries[id]?.group
      next.clips.removeAll { $0.id == id }
      next.snippets.removeAll { $0.id == id }
      guard !localFile else { return }
      let s = self.stamp(&next)
      var entry = next.sync!.entries[id] ?? SyncEntry()
      if let group, entry.snippet != true, entry.files != true { entry.group = group }
      entry.deleted = s
      entry.superseded = nil
      next.sync!.entries[id] = entry
      if let group {
        var tombstonedIDs = Set<String>()
        for otherID in Array(next.sync!.entries.keys) where otherID != id {
          guard var other = next.sync!.entries[otherID], other.group == group,
            other.snippet != true, other.files != true
          else { continue }
          other.deleted = newest(other.deleted, s)
          other.superseded = nil
          next.sync!.entries[otherID] = other
          tombstonedIDs.insert(otherID)
        }
        if !tombstonedIDs.isEmpty {
          next.clips.removeAll { !$0.isSnippet && tombstonedIDs.contains($0.id) }
        }
      }
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
  public func manifest(snippets: Bool = true, files: Bool = false) throws -> SyncManifest {
    try serialized {
      try storage.requireReady()
      let sync = state.sync!
      let entries = sync.entries.filter {
        (snippets || $0.value.snippet != true) && (files || $0.value.files != true)
      }.mapValues {
        entry -> SyncEntry in
        var entry = entry
        entry.seen = nil
        entry.group = nil
        entry.superseded = nil
        return entry
      }
      return SyncManifest(
        snippets: snippets ? true : nil, files: files ? true : nil, clear: sync.clear,
        entries: entries,
        available: state.records.filter {
          ($0.kind != .files || (files && $0.fileSource != nil)) && (snippets || !$0.isSnippet)
        }.map(
          \.id))
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
          var touchedGroups = Set<String>()
          for (id, incoming) in remote.entries {
            if let record = next.records.first(where: { $0.id == id }),
              (record.kind == .files) != (incoming.files == true)
            {
              throw PolkaCoreError.invalid(localized("Invalid sync type"))
            }
            let existingLocal = sync.entries[id]
            var local = existingLocal ?? SyncEntry()
            let entryChanged =
              existingLocal == nil
              || compareStamp(incoming.added, local.added) > 0
              || compareStamp(incoming.deleted, local.deleted) > 0
              || compareStamp(incoming.pin?.stamp, local.pin?.stamp) > 0
            for stamp in [incoming.added, incoming.deleted, incoming.pin?.stamp].compactMap({ $0 })
            { sync.counter = max(sync.counter, stamp.counter) }
            if incoming.pin?.value == true, compareStamp(incoming.pin?.stamp, local.pin?.stamp) > 0,
              !next.records.contains(where: { $0.id == id })
            {
              local.seen = nil
            }
            guard local.files == nil || incoming.files == true,
              local.snippet == nil || incoming.snippet == true,
              !(local.files == true && incoming.snippet == true),
              !(local.snippet == true && incoming.files == true)
            else {
              throw PolkaCoreError.invalid(localized("Invalid sync type"))
            }
            local.files = local.files == true || incoming.files == true ? true : nil
            local.snippet = local.snippet == true || incoming.snippet == true ? true : nil
            local.added = newest(local.added, incoming.added)
            local.deleted = newest(local.deleted, incoming.deleted)
            if compareStamp(incoming.pin?.stamp, local.pin?.stamp) > 0 { local.pin = incoming.pin }
            sync.entries[id] = local
            if entryChanged, let group = local.group, local.snippet != true, local.files != true {
              touchedGroups.insert(group)
            }
          }
          next.sync = sync
          self.reconcileGroupEntries(&next, groups: touchedGroups)
          sync = next.sync!
          next.clips = next.clips.filter {
            $0.kind == .files && $0.fileSource == nil || liveEntry(sync.entries[$0.id]!, sync.clear)
          }.map {
            guard $0.kind != .files || $0.fileSource != nil else { return $0 }
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
  public func transfer(_ id: String, files: Bool = false) -> ClipTransfer? {
    serialized {
      guard var clip = state.records.first(where: { $0.id == id }),
        clip.kind != .files || (files && clip.fileSource != nil),
        let stamp = state.sync?.entries[id]?.seen
      else { return nil }
      clip.ocr = nil
      if clip.kind == .files { clip.content = "" }
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
      guard clip.kind == .files || !clip.content.isEmpty,
        clip.content.utf8.count <= ClipboardLimits.maxClipBytes
      else {
        throw PolkaCoreError.invalid(localized("Invalid clipboard item"))
      }
      if clip.kind == .files {
        guard clip.content.isEmpty, let source = clip.fileSource,
          source.device == transfer.stamp.device, !clip.isSnippet,
          state.sync?.entries[clip.id]?.files == true
        else {
          throw PolkaCoreError.invalid(localized("Invalid file transfer metadata"))
        }
      } else if clip.isSnippet {
        guard clip.kind == .text, clip.content.utf8.count <= ClipboardLimits.maxSnippetTextBytes,
          state.sync?.entries[clip.id]?.snippet == true
        else { throw PolkaCoreError.invalid(localized("Invalid snippet")) }
      } else {
        guard clipId(clip.kind, clip.content) == clip.id else {
          throw PolkaCoreError.invalid(localized("Invalid clipboard item"))
        }
      }
      if clip.kind == .image {
        guard clip.content.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil,
          let png = Data(base64Encoded: clip.content), png.count <= ClipboardLimits.maxImageBytes,
          png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
          clip.preview.range(
            of: "^data:image/png;base64,[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil
        else { throw PolkaCoreError.invalid(localized("Invalid clipboard image")) }
      } else if clip.kind == .files {
        clip.preview = prefix(clip.fileSource!.names, 400)
      } else {
        clip.preview = prefix(clip.content, 400)
      }
      try update { next in
        guard var entry = next.sync!.entries[clip.id], clip.isSnippet == (entry.snippet == true),
          (clip.kind == .files) == (entry.files == true),
          compareStamp(transfer.stamp, entry.added) == 0, liveEntry(entry, next.sync!.clear),
          compareStamp(transfer.stamp, entry.seen) > 0
        else { return }
        entry.seen = transfer.stamp
        let group =
          !clip.isSnippet && clip.kind == .text
          ? self.textGroupID(id: clip.id, content: clip.content) : nil
        if let group { entry.group = group }
        next.sync!.entries[clip.id] = entry
        var mergedOCR: ImageText?
        if let group {
          let equivalent = next.clips.filter {
            $0.kind == .text && !$0.isSnippet && $0.id != clip.id
              && self.textGroupID(id: $0.id, content: $0.content) == group
          }
          if !equivalent.isEmpty {
            let preferredLocal = equivalent.max {
              self.isClipOrderedBefore($0, $1, in: next, useSyncOrder: true)
            }!
            if !self.isIncomingPreferred(
              clipID: clip.id, stamp: transfer.stamp, createdAt: clip.createdAt,
              over: preferredLocal, in: next)
            {
              let winnerStamp = next.sync!.entries[preferredLocal.id]?.added
              let deleteStamp: Stamp
              if let winnerStamp, compareStamp(winnerStamp, transfer.stamp) > 0 {
                deleteStamp = winnerStamp
              } else {
                deleteStamp = self.stamp(&next)
              }
              entry.deleted = newest(entry.deleted, deleteStamp)
              entry.superseded = true
              next.sync!.entries[clip.id] = entry
              self.reconcileGroupEntries(&next, groups: [group])
              if let index = next.clips.firstIndex(where: { $0.id == preferredLocal.id }) {
                next.clips[index].pinned =
                  next.sync!.entries[preferredLocal.id]?.pin?.value ?? false
              }
              return
            }
            let equivalentIDs = Set(equivalent.map(\.id))
            for old in equivalent {
              if mergedOCR == nil { mergedOCR = old.ocr }
              var oldEntry = next.sync!.entries[old.id] ?? SyncEntry()
              oldEntry.group = group
              let deleteStamp =
                compareStamp(transfer.stamp, oldEntry.added) > 0
                ? transfer.stamp : self.stamp(&next)
              oldEntry.deleted = newest(oldEntry.deleted, deleteStamp)
              oldEntry.superseded = true
              next.sync!.entries[old.id] = oldEntry
            }
            next.clips.removeAll { !$0.isSnippet && equivalentIDs.contains($0.id) }
          }
          self.reconcileGroupEntries(&next, groups: [group])
          guard var reconciled = next.sync!.entries[clip.id],
            liveEntry(reconciled, next.sync!.clear)
          else { return }
          reconciled.superseded = nil
          next.sync!.entries[clip.id] = reconciled
          entry = reconciled
        }
        clip.ocr = next.clips.first(where: { $0.id == clip.id })?.ocr ?? mergedOCR
        // Receiving metadata echoed by another peer must not replace our originals.
        if clip.kind == .files, let local = next.clips.first(where: { $0.id == clip.id }),
          local.fileSource == clip.fileSource, !local.content.isEmpty
        {
          clip.content = local.content
        }
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
        throw PolkaCoreError.invalid(localized("This item has already been deleted"))
      }
      guard next.clips[index].ocr?.status == .failed else {
        throw PolkaCoreError.invalid(localized("Text recognition does not need to be retried"))
      }
      next.clips[index].ocr = nil
    }
  }
}
