import Foundation

/// Local references only: copying a file does not snapshot its bytes.
public struct ClipboardFiles: Equatable {
  public let urls: [URL]
  public let content: String
  public init(urls: [URL]) throws {
    guard !urls.isEmpty, urls.count <= 1000,
      urls.allSatisfy({ url in
        url.isFileURL && [nil, "", "localhost"].contains(url.host)
          && url.user == nil && url.password == nil && url.port == nil
          && url.query == nil && url.fragment == nil && url.path.hasPrefix("/")
          && !url.path(percentEncoded: false).contains("\0")
      })
    else { throw PolkaCoreError.invalid(localized("Invalid copied file references")) }
    self.urls = urls
    content = String(decoding: try JSONEncoder().encode(urls.map(\.absoluteString)), as: UTF8.self)
    guard content.utf8.count <= 1024 * 1024 else {
      throw PolkaCoreError.invalid(localized("Invalid copied file references"))
    }
  }
  public init(content: String) throws {
    guard content.utf8.count <= 1024 * 1024,
      let values = try? JSONDecoder().decode([String].self, from: Data(content.utf8))
    else { throw PolkaCoreError.invalid(localized("Invalid copied file references")) }
    let urls = values.compactMap { URL(string: $0) }
    guard urls.count == values.count else {
      throw PolkaCoreError.invalid(localized("Invalid copied file references"))
    }
    try self.init(urls: urls)
  }
  public var names: String { urls.map(\.lastPathComponent).joined(separator: ", ") }
  public var preview: String { String(names.prefix(400)) }
  public var searchText: String { urls.map(\.path).joined(separator: "\n") }
}
