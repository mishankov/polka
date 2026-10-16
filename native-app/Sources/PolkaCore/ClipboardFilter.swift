import Foundation

/// Views of existing text/image records, never new storage or sync kinds.
public enum ClipboardFilter: String, CaseIterable, Sendable {
  case all, text, images, links, colors

  public var label: String {
    switch self {
    case .all: return localized("All")
    case .text: return localized("Text")
    case .images: return localized("Images")
    case .links: return localized("Links")
    case .colors: return localized("Colors")
    }
  }

  public func matches(kind: ClipboardClip.Kind, content: String) -> Bool {
    switch self {
    case .all: return true
    case .text: return kind == .text
    case .images: return kind == .image
    case .links: return kind == .text && clipboardWebURL(content) != nil
    case .colors: return kind == .text && ClipboardColor.parse(content) != nil
    }
  }
}

/// Whole-value validation shared by link actions, previews and filtering.
public func clipboardWebURL(_ text: String) -> URL? {
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
