import Foundation

public struct PolkaMetadata: Codable, Equatable {
  public struct Mac: Codable, Equatable {
    public var minimumSystemVersion: String
    public var category: String
    public var icon: String
    public init(
      minimumSystemVersion: String = "27.0", category: String = "public.app-category.productivity",
      icon: String = "build/Everything.icon"
    ) {
      self.minimumSystemVersion = minimumSystemVersion
      self.category = category
      self.icon = icon
    }
  }
  public struct Build: Codable, Equatable {
    public var appId: String
    public var productName: String
    public var mac: Mac
    public init(
      appId: String = "app.everything.desktop", productName: String = "Polka", mac: Mac = Mac()
    ) {
      self.appId = appId
      self.productName = productName
      self.mac = mac
    }
  }
  public var name: String
  public var version: String
  public var description: String
  public var author: String
  public var license: String
  public var build: Build
  public var releaseNotes: BilingualNotes?
  public init(
    name: String = "polka", version: String, description: String = "",
    author: String = "Polka contributors", license: String = "MIT", build: Build = Build(),
    releaseNotes: BilingualNotes? = nil
  ) {
    self.name = name
    self.version = version
    self.description = description
    self.author = author
    self.license = license
    self.build = build
    self.releaseNotes = releaseNotes
  }
  public static func load(
    root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws -> Self {
    try JSONDecoder().decode(
      Self.self, from: Data(contentsOf: root.appendingPathComponent("polka.json")))
  }
}
public typealias AppMetadata = PolkaMetadata
public struct BilingualNotes: Codable, Equatable {
  public var ru: String
  public var en: String
  public init(ru: String, en: String) {
    self.ru = ru
    self.en = en
  }
}
public struct BundleMetadata: Codable, Equatable {
  public struct Signing: Codable, Equatable {
    public var fingerprint: String?
    public var timestamp: String = "none"
    public var hardenedRuntime: Bool = false
    public var notarize: Bool = false
    public init(fingerprint: String? = nil) { self.fingerprint = fingerprint }
  }
  public struct Release: Codable, Equatable {
    public var repository: String
    public var updater: String = "sparkle"
    public var feedUrl: String
    public var publicKey: String
    public init(repository: String, feedUrl: String, publicKey: String) {
      self.repository = repository
      self.feedUrl = feedUrl
      self.publicKey = publicKey
    }
  }
  public var appId: String
  public var productName: String
  public var version: String
  public var minimumSystemVersion: String
  public var signing: Signing
  public var release: Release
  public init(
    appId: String, productName: String, version: String, minimumSystemVersion: String,
    signing: Signing = Signing(), release: Release
  ) {
    self.appId = appId
    self.productName = productName
    self.version = version
    self.minimumSystemVersion = minimumSystemVersion
    self.signing = signing
    self.release = release
  }
}
