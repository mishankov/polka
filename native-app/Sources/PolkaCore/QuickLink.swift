import Foundation
import Network

public struct QuickLink: Codable, Equatable, Identifiable, Sendable {
  public enum ValidationError: Error, Equatable {
    case invalidURL
  }

  public let id: UUID
  public let name: String
  public let url: URL

  public var displayName: String { name.isEmpty ? url.absoluteString : name }

  public init(id: UUID = UUID(), name: String = "", url: String) throws {
    let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
    // Keep international URLs while checking the original ASCII syntax and escapes.
    guard !value.contains(where: \.isWhitespace),
      let asciiValue = value.addingPercentEncoding(withAllowedCharacters: Self.ascii),
      URL(string: asciiValue, encodingInvalidCharacters: false) != nil,
      let url = URL(string: value), let scheme = url.scheme?.lowercased(),
      !["file", "data", "javascript"].contains(scheme)
    else { throw ValidationError.invalidURL }
    if scheme == "http" || scheme == "https" {
      guard let host = url.host(percentEncoded: false), !host.isEmpty,
        !host.contains(where: \.isWhitespace),
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else { throw ValidationError.invalidURL }
      if parts.rangeOfPort != nil, !(0...65535).contains(parts.port ?? -1) {
        throw ValidationError.invalidURL
      }
      if parts.percentEncodedHost?.hasPrefix("[") == true, IPv6Address(host) == nil {
        throw ValidationError.invalidURL
      }
    }

    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.url = url
  }

  private static let ascii = CharacterSet(charactersIn: "\u{0}"..."\u{7F}")

  private enum CodingKeys: String, CodingKey {
    case id, name, url
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(UUID.self, forKey: .id),
      name: values.decode(String.self, forKey: .name),
      url: values.decode(String.self, forKey: .url))
  }
}
