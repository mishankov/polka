import CryptoKit
import Foundation

extension KeyedDecodingContainer {
  /// Optional persisted fields allow omission, but reject explicit JSON null.
  func decodeOptional<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
    guard contains(key) else { return nil }
    return try decode(type, forKey: key)
  }
}

public enum PolkaCoreError: Error, LocalizedError {
  case invalid(String)
  case storage(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let s), .storage(let s): return s
    }
  }
}
public struct ClipboardPreferences: Codable, Equatable {
  public var paused = false
  public var pasteOnSelect = true
  public var hoverEnabled = true
  public var retentionDays = 7
  public var accelerator = "CommandOrControl+Shift+V"
  public init() {}
  public init(
    paused: Bool = false, pasteOnSelect: Bool = true, hoverEnabled: Bool = true,
    retentionDays: Int = 7, accelerator: String = "CommandOrControl+Shift+V"
  ) {
    self.paused = paused
    self.pasteOnSelect = pasteOnSelect
    self.hoverEnabled = hoverEnabled
    self.retentionDays = retentionDays
    self.accelerator = accelerator
  }
  private enum CodingKeys: String, CodingKey {
    case paused, pasteOnSelect, hoverEnabled, retentionDays, accelerator
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    paused = try c.decode(Bool.self, forKey: .paused)
    pasteOnSelect = try c.decodeOptional(Bool.self, forKey: .pasteOnSelect) ?? true
    hoverEnabled = try c.decode(Bool.self, forKey: .hoverEnabled)
    retentionDays = try c.decode(Int.self, forKey: .retentionDays)
    accelerator = try c.decode(String.self, forKey: .accelerator)
    try validate()
  }
  public func validate() throws {
    guard [1, 7, 30].contains(retentionDays), accelerator.utf16.count <= 80 else {
      throw PolkaCoreError.invalid("Некорректные настройки буфера")
    }
  }
}
public struct ImageText: Codable, Equatable {
  public enum Status: String, Codable { case ready, empty, failed }
  public var version: String
  public var status: Status
  public var text: String
  public var languages: [String]
  public init(version: String, status: Status, text: String, languages: [String]) {
    self.version = version
    self.status = status
    self.text = text
    self.languages = languages
  }
  public func validate() throws {
    guard version.utf16.count <= 100, text.utf16.count <= 1_048_576, languages.count <= 20,
      languages.allSatisfy({ $0.utf16.count <= 40 })
    else { throw PolkaCoreError.invalid("Некорректные данные распознавания") }
  }
}
public struct ClipboardClip: Codable, Equatable, Identifiable {
  public enum Kind: String, Codable { case text, image }
  public var id: String
  public var kind: Kind
  public var content: String
  public var preview: String
  public var createdAt: Double
  public var pinned: Bool
  public var snippet: Bool?
  public var name: String?
  public var sourceDevice: String?
  public var ocr: ImageText?
  public init(
    id: String, kind: Kind, content: String, preview: String, createdAt: Double,
    pinned: Bool = false, snippet: Bool? = nil, name: String? = nil, sourceDevice: String? = nil,
    ocr: ImageText? = nil
  ) {
    self.id = id
    self.kind = kind
    self.content = content
    self.preview = preview
    self.createdAt = createdAt
    self.pinned = pinned
    self.snippet = snippet
    self.name = name
    self.sourceDevice = sourceDevice
    self.ocr = ocr
  }
  private enum CodingKeys: String, CodingKey {
    case id, kind, content, preview, createdAt, pinned, snippet, name, sourceDevice, ocr
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    kind = try c.decode(Kind.self, forKey: .kind)
    content = try c.decode(String.self, forKey: .content)
    preview = try c.decode(String.self, forKey: .preview)
    createdAt = try c.decode(Double.self, forKey: .createdAt)
    pinned = try c.decode(Bool.self, forKey: .pinned)
    snippet = try c.decodeOptional(Bool.self, forKey: .snippet)
    name = try c.decodeOptional(String.self, forKey: .name)
    sourceDevice = try c.decodeOptional(String.self, forKey: .sourceDevice)
    ocr = try c.decodeOptional(ImageText.self, forKey: .ocr)
  }
  public var isSnippet: Bool { snippet == true }
  public func validate(requireSnippet: Bool = false) throws {
    guard validClipID(id), content.utf16.count <= ClipboardLimits.maxClipBytes * 2,
      preview.utf16.count <= 200_000, createdAt.isFinite, snippet != false,
      (name?.utf16.count ?? 0) <= 120, (sourceDevice?.utf16.count ?? 0) <= 100
    else { throw PolkaCoreError.invalid("Некорректная запись буфера") }
    if requireSnippet {
      guard isSnippet, kind == .text, !content.isEmpty,
        content.utf16.count <= ClipboardLimits.maxSnippetTextBytes,
        content.utf8.count <= ClipboardLimits.maxSnippetTextBytes
      else { throw PolkaCoreError.invalid("Некорректный сниппет") }
    }
    try ocr?.validate()
  }
}
public enum ClipboardLimits {
  public static let maxImageBytes = 32 * 1024 * 1024
  public static let maxSnippetTextBytes = 1024 * 1024
  public static let maxClipBytes = ((maxImageBytes + 2) / 3) * 4
  public static let maxHistoryBytes = 128 * 1024 * 1024
  public static let maxHistoryItems = 200
  public static let maxSnippetItems = 200
  public static let maxSnippetsBytes = 128 * 1024 * 1024
}
public func clipId(_ kind: ClipboardClip.Kind, _ content: String) -> String {
  SHA256.hash(data: Data((kind.rawValue + "\0" + content).utf8)).map { String(format: "%02x", $0) }
    .joined()
}
public func validDeviceID(_ value: String) -> Bool {
  value.range(
    of:
      "^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$",
    options: .regularExpression) != nil
}
public func validClipID(_ id: String) -> Bool {
  id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
public func excludedClipboardType(_ types: [String]) -> Bool {
  types.contains {
    $0.range(
      of:
        "org\\.nspasteboard\\.(ConcealedType|TransientType|AutoGeneratedType)|com\\.agilebits\\.onepassword",
      options: [.regularExpression, .caseInsensitive]) != nil
  }
}
public func clipboardContentType(_ types: [String]) -> String? {
  let images = [
    "image/png", "image/jpeg", "image/tiff", "image/bmp", "image/webp", "public.png", "public.tiff",
    "electron application/osclipboard;format=\"public.png\"",
    "electron application/osclipboard;format=\"Apple PNG pasteboard type\"",
    "electron application/osclipboard;format=\"public.tiff\"",
    "electron application/osclipboard;format=\"NeXT TIFF v4.0 pasteboard type\"",
  ]
  if let image = images.first(where: types.contains) { return image }
  if types.contains(where: {
    $0.range(
      of: "public\\.file-url|NSFilenamesPboardType",
      options: [.regularExpression, .caseInsensitive]) != nil
  }) {
    return nil
  }
  return types.contains("text/plain") ? "text/plain" : nil
}
/// JavaScript string equality compares code units without Unicode normalization.
public func clipboardTextEqual(_ left: String?, _ right: String?) -> Bool {
  switch (left, right) {
  case (nil, nil): return true
  case (let left?, let right?): return left.utf8.elementsEqual(right.utf8)
  default: return false
  }
}
public func clipboardResults(_ clips: [ClipboardClip], query: String) -> [ClipboardClip] {
  let whitespace = CharacterSet(
    charactersIn:
      "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
  )
  let terms = query.lowercased().components(separatedBy: whitespace).filter { !$0.isEmpty }
  return clips.filter { clip in
    let text =
      (clip.kind == .text
      ? "\(clip.name ?? "") \(clip.content)" : "Изображение \(clip.ocr?.text ?? "")").lowercased()
    return terms.allSatisfy { text.range(of: $0, options: .literal) != nil }
  }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.createdAt > $1.createdAt }
}
public struct Stamp: Codable, Equatable {
  public var counter: Int64
  public var device: String
  public init(counter: Int64, device: String) {
    self.counter = counter
    self.device = device
  }
  public func validate() throws {
    guard counter >= 0, counter <= 9_007_199_252_740_991, validDeviceID(device) else {
      throw PolkaCoreError.invalid("Некорректный штамп синхронизации")
    }
  }
}
public func compareStamp(_ a: Stamp?, _ b: Stamp?) -> Int {
  guard let a else { return b == nil ? 0 : -1 }
  guard let b else { return 1 }
  if a.counter != b.counter { return a.counter > b.counter ? 1 : -1 }
  if a.device == b.device { return 0 }
  let comparison = a.device.compare(b.device, options: [], locale: Locale(identifier: "en"))
  return comparison == .orderedDescending ? 1 : comparison == .orderedAscending ? -1 : 0
}
public func newest(_ a: Stamp?, _ b: Stamp?) -> Stamp? { compareStamp(a, b) >= 0 ? a : b }
public struct SyncPin: Codable, Equatable {
  public var stamp: Stamp
  public var value: Bool
  public init(stamp: Stamp, value: Bool) {
    self.stamp = stamp
    self.value = value
  }
}
public struct SyncEntry: Codable, Equatable {
  public var snippet: Bool?
  public var added: Stamp?
  public var deleted: Stamp?
  public var pin: SyncPin?
  public var seen: Stamp?
  public init(
    snippet: Bool? = nil, added: Stamp? = nil, deleted: Stamp? = nil, pin: SyncPin? = nil,
    seen: Stamp? = nil
  ) {
    self.snippet = snippet
    self.added = added
    self.deleted = deleted
    self.pin = pin
    self.seen = seen
  }
  private enum CodingKeys: String, CodingKey { case snippet, added, deleted, pin, seen }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    snippet = try c.decodeOptional(Bool.self, forKey: .snippet)
    added = try c.decodeOptional(Stamp.self, forKey: .added)
    deleted = try c.decodeOptional(Stamp.self, forKey: .deleted)
    pin = try c.decodeOptional(SyncPin.self, forKey: .pin)
    seen = try c.decodeOptional(Stamp.self, forKey: .seen)
  }
  public func validate() throws {
    guard snippet != false else { throw PolkaCoreError.invalid("Некорректный тип синхронизации") }
    try added?.validate()
    try deleted?.validate()
    try seen?.validate()
    try pin?.stamp.validate()
  }
}
public func liveEntry(_ entry: SyncEntry, _ clear: Stamp?) -> Bool {
  entry.added != nil
    && compareStamp(entry.added, newest(entry.deleted, entry.snippet == true ? nil : clear)) > 0
}
private struct WireSyncEntry: Decodable {
  var snippet: Bool?
  var added: Stamp?
  var deleted: Stamp?
  var pin: SyncPin?
  private enum CodingKeys: String, CodingKey { case snippet, added, deleted, pin }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    snippet = try c.decodeOptional(Bool.self, forKey: .snippet)
    added = try c.decodeOptional(Stamp.self, forKey: .added)
    deleted = try c.decodeOptional(Stamp.self, forKey: .deleted)
    pin = try c.decodeOptional(SyncPin.self, forKey: .pin)
  }
  var entry: SyncEntry { SyncEntry(snippet: snippet, added: added, deleted: deleted, pin: pin) }
}
public struct SyncManifest: Codable, Equatable {
  public var version = 1
  public var snippets: Bool?
  public var clear: Stamp?
  public var entries: [String: SyncEntry]
  public var available: [String]
  public init(
    snippets: Bool? = true, clear: Stamp? = nil, entries: [String: SyncEntry], available: [String]
  ) {
    self.snippets = snippets
    self.clear = clear
    self.entries = entries.mapValues { value in
      var value = value
      value.seen = nil
      return value
    }
    self.available = available
  }
  private enum CodingKeys: String, CodingKey { case version, snippets, clear, entries, available }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(Int.self, forKey: .version)
    snippets = try c.decodeOptional(Bool.self, forKey: .snippets)
    clear = try c.decodeOptional(Stamp.self, forKey: .clear)
    entries = try c.decode([String: WireSyncEntry].self, forKey: .entries).mapValues(\.entry)
    available = try c.decode([String].self, forKey: .available)
  }
  public func validate() throws {
    guard version == 1, snippets != false, available.count <= 400,
      available.allSatisfy(validClipID), entries.keys.allSatisfy(validClipID)
    else { throw PolkaCoreError.invalid("Некорректный манифест") }
    try clear?.validate()
    for entry in entries.values { try entry.validate() }
  }
}
private struct WireClipboardClip: Codable {
  var id: String
  var kind: ClipboardClip.Kind
  var content: String
  var preview: String
  var createdAt: Double
  var pinned: Bool
  var snippet: Bool?
  var name: String?
  var sourceDevice: String?
  private enum CodingKeys: String, CodingKey {
    case id, kind, content, preview, createdAt, pinned, snippet, name, sourceDevice
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    kind = try c.decode(ClipboardClip.Kind.self, forKey: .kind)
    content = try c.decode(String.self, forKey: .content)
    preview = try c.decode(String.self, forKey: .preview)
    createdAt = try c.decode(Double.self, forKey: .createdAt)
    pinned = try c.decode(Bool.self, forKey: .pinned)
    snippet = try c.decodeOptional(Bool.self, forKey: .snippet)
    name = try c.decodeOptional(String.self, forKey: .name)
    sourceDevice = try c.decodeOptional(String.self, forKey: .sourceDevice)
  }
  var clip: ClipboardClip {
    ClipboardClip(
      id: id, kind: kind, content: content, preview: preview, createdAt: createdAt, pinned: pinned,
      snippet: snippet, name: name, sourceDevice: sourceDevice)
  }
}
public struct ClipTransfer: Codable, Equatable {
  public var clip: ClipboardClip
  public var stamp: Stamp
  private enum CodingKeys: String, CodingKey { case clip, stamp }
  public init(clip: ClipboardClip, stamp: Stamp) {
    var clip = clip
    clip.ocr = nil
    self.clip = clip
    self.stamp = stamp
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    clip = try c.decode(WireClipboardClip.self, forKey: .clip).clip
    stamp = try c.decode(Stamp.self, forKey: .stamp)
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    var wire = clip
    wire.ocr = nil
    try c.encode(wire, forKey: .clip)
    try c.encode(stamp, forKey: .stamp)
  }
}
public struct ClipboardSnapshot: Codable, Equatable {
  public var version = 1
  public var preferences: ClipboardPreferences
  public var clips: [ClipboardClip]
  public var snippets: [ClipboardClip]
  public init(
    version: Int = 1, preferences: ClipboardPreferences, clips: [ClipboardClip],
    snippets: [ClipboardClip]
  ) {
    self.version = version
    self.preferences = preferences
    self.clips = clips
    self.snippets = snippets
  }
}
public struct SnippetExpected {
  public var content: String
  public var name: String?
  public init(content: String, name: String? = nil) {
    self.content = content
    self.name = name
  }
}
public struct ImageTextImage {
  public var id: String
  public var content: String
  public var ocr: ImageText?
  public var incarnation: Int
}
