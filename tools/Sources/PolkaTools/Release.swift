import CryptoKit
import Foundation

public enum ReleaseMetadata {
  public static func artifactNames(metadata: PolkaMetadata) throws -> [String] {
    let base = "\(metadata.name)-\(metadata.version)-arm64"
    guard base.range(of: #"^[A-Za-z0-9._-]+\z"#, options: .regularExpression) != nil else {
      throw ReleaseError.invalid("Release artifact name must be safe for GitHub.")
    }
    return ["\(base).dmg", "\(base).zip", "appcast.xml"]
  }
  public static func publicKey(_ value: String) throws -> Curve25519.Signing.PublicKey {
    guard value.range(of: #"^[A-Za-z0-9+/]{43}=\z"#, options: .regularExpression) != nil,
      let bytes = Data(base64Encoded: value), bytes.count == 32,
      bytes.base64EncodedString() == value
    else {
      throw ReleaseError.invalid(
        "SPARKLE_PUBLIC_KEY must be the base64 Ed25519 public key from generate_keys.")
    }
    return try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
  }
  public static func archiveURL(metadata: PolkaMetadata, repository: String, tag: String? = nil)
    throws -> String
  {
    _ = try ReleaseVersion.repository(repository)
    let selected = tag ?? "v\(metadata.version)"
    guard try ReleaseVersion.parse(selected) == metadata.version else {
      throw ReleaseError.invalid("Release tag does not match the bundle version.")
    }
    let name = try artifactNames(metadata: metadata)[1]
    return
      "https://github.com/\(repository)/releases/download/\(ReleaseVersion.encodedTag(selected))/\(name)"
  }
  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
  public static func appcast(
    metadata: PolkaMetadata, repository: String, signature: String,
    size: Int, tag: String? = nil, date: Date = Date()
  ) throws -> String {
    guard size >= 0,
      signature.range(of: #"^[A-Za-z0-9+/]{86}==\z"#, options: .regularExpression) != nil,
      let bytes = Data(base64Encoded: signature), bytes.count == 64,
      bytes.base64EncodedString() == signature
    else {
      throw ReleaseError.invalid("Missing or invalid Ed25519 update signature.")
    }
    let url = try archiveURL(metadata: metadata, repository: repository, tag: tag)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    let notes = try metadata.releaseNotes.map { try ReleaseNotes(ru: $0.ru, en: $0.en).json() }
    return """
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
          <title>\(escape(metadata.build.productName)) updates</title>
          <link>https://github.com/\(escape(repository))/releases</link>
          <item>
            <title>\(escape(metadata.build.productName)) \(escape(metadata.version))</title>
            <pubDate>\(formatter.string(from: date))</pubDate>
            <sparkle:version>\(escape(metadata.version))</sparkle:version>
            <sparkle:shortVersionString>\(escape(metadata.version))</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>\(escape(metadata.build.mac.minimumSystemVersion))</sparkle:minimumSystemVersion>
      \(notes.map { "      <description>\(escape($0))</description>\n" } ?? "")      <enclosure url="\(escape(url))" length="\(size)" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
          </item>
        </channel>
      </rss>

      """
  }
  public static func verify(
    metadata: PolkaMetadata, directory: URL, repository: String,
    publicKey: String, tag: String? = nil
  ) throws -> [String] {
    let names = try artifactNames(metadata: metadata)
    for name in names {
      let url = directory.appendingPathComponent(name)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ReleaseError.invalid("Missing regular release artifact: \(name)")
      }
    }
    let data = try Data(contentsOf: directory.appendingPathComponent("appcast.xml"))
    let parsed = try AppcastDocument.parse(data)
    if let notes = metadata.releaseNotes {
      let expected = try ReleaseNotes(ru: notes.ru, en: notes.en).json()
      guard parsed.fields["description"] == expected else {
        throw ReleaseError.invalid("Appcast release notes do not match this release.")
      }
    }
    guard parsed.fields["sparkle:version"] == metadata.version,
      parsed.fields["sparkle:shortVersionString"] == metadata.version,
      parsed.fields["sparkle:minimumSystemVersion"] == metadata.build.mac.minimumSystemVersion
    else {
      throw ReleaseError.invalid(
        "Appcast version or minimum system version does not match this release.")
    }
    guard
      parsed.enclosure["url"]
        == (try archiveURL(metadata: metadata, repository: repository, tag: tag)),
      parsed.enclosure["type"] == "application/octet-stream"
    else {
      throw ReleaseError.invalid("Appcast URL does not match the uploaded ZIP asset.")
    }
    let bytes = try Data(contentsOf: directory.appendingPathComponent(names[1]))
    guard parsed.enclosure["length"] == String(bytes.count) else {
      throw ReleaseError.invalid("Appcast ZIP size mismatch.")
    }
    guard let encoded = parsed.enclosure["sparkle:edSignature"],
      encoded.range(of: #"^[A-Za-z0-9+/]{86}==\z"#, options: .regularExpression) != nil,
      let signature = Data(base64Encoded: encoded), signature.count == 64,
      signature.base64EncodedString() == encoded
    else {
      throw ReleaseError.invalid("Missing or invalid Ed25519 update signature.")
    }
    let key = try self.publicKey(publicKey)
    guard key.isValidSignature(signature, for: bytes) else {
      throw ReleaseError.invalid(
        "Update signature does not match the ZIP bytes and embedded public key.")
    }
    return names
  }
}

// A single release item is required. Duplicate fields, namespace changes and DTDs
// are rejected rather than letting a parser and Sparkle choose different values.
private final class AppcastDocument: NSObject, XMLParserDelegate {
  var path: [String] = []
  var fields: [String: String] = [:]
  var enclosure: [String: String] = [:]
  private var channels = 0, items = 0, enclosures = 0
  private var invalid = false
  private var seen = Set<String>()
  private let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
  static func parse(_ data: Data) throws -> AppcastDocument {
    guard data.count <= 1_048_576, let source = String(data: data, encoding: .utf8),
      source.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil
    else {
      throw ReleaseError.invalid("Invalid appcast XML.")
    }
    let document = AppcastDocument()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = document
    guard parser.parse(), !document.invalid, document.channels == 1,
      document.items == 1, document.enclosures == 1, document.path.isEmpty
    else {
      throw ReleaseError.invalid("Invalid appcast XML or ambiguous release item.")
    }
    return document
  }
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    path.append(elementName)
    if path.count > 4, path.prefix(3).elementsEqual(["rss", "channel", "item"]),
      [
        "sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion",
        "description",
      ].contains(path[3])
    {
      invalid = true
    }
    if path == ["rss"] {
      if attributeDict["xmlns:sparkle"] != namespace { invalid = true }
    } else if attributeDict.keys.contains(where: { $0 == "xmlns:sparkle" }) {
      if attributeDict["xmlns:sparkle"] != namespace { invalid = true }
    }
    if path == ["rss", "channel"] { channels += 1 }
    if path == ["rss", "channel", "item"] { items += 1 }
    if path == ["rss", "channel", "item", "enclosure"] {
      enclosures += 1
      enclosure = attributeDict
    }
    if path.count == 4, path.prefix(3).elementsEqual(["rss", "channel", "item"]),
      [
        "sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion",
        "description",
      ].contains(elementName)
    {
      if !seen.insert(elementName).inserted { invalid = true }
      fields[elementName] = ""
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if path.count == 4, let field = path.last, fields[field] != nil { fields[field]! += string }
  }
  func parser(_ parser: XMLParser, foundCDATA block: Data) {
    if let string = String(data: block, encoding: .utf8) {
      self.parser(parser, foundCharacters: string)
    } else {
      invalid = true
    }
  }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard path.last == elementName else {
      invalid = true
      return
    }
    path.removeLast()
  }
}

public enum ReleaseTool {
  public static func resolved(_ metadata: PolkaMetadata, environment: [String: String]) throws -> (
    metadata: PolkaMetadata, tag: String
  ) {
    let tag = environment["RELEASE_TAG"].flatMap { $0.isEmpty ? nil : $0 } ?? "v\(metadata.version)"
    var result = metadata
    result.version = try ReleaseVersion.parse(tag)
    return (result, tag)
  }
  public static func configuration(
    metadata: PolkaMetadata, environment: [String: String], adHoc: Bool = false
  ) throws -> BundleMetadata {
    let repository = try ReleaseVersion.repository(environment["RELEASE_REPOSITORY"] ?? "")
    let key = environment["SPARKLE_PUBLIC_KEY"] ?? ""
    _ = try ReleaseMetadata.publicKey(key)
    let fingerprint = adHoc ? nil : try SigningTool.fingerprint(environment)
    return BundleMetadata(
      appId: metadata.build.appId, productName: metadata.build.productName,
      version: metadata.version, minimumSystemVersion: metadata.build.mac.minimumSystemVersion,
      signing: .init(fingerprint: fingerprint),
      release: .init(
        repository: repository,
        feedUrl: "https://github.com/\(repository)/releases/latest/download/appcast.xml",
        publicKey: key))
  }
}

public struct ReleaseOptions {
  public var prebuilt = false
  public var desktop = false
  public var publish = false
  public init(prebuilt: Bool = false, desktop: Bool = false, publish: Bool = false) {
    self.prebuilt = prebuilt
    self.desktop = desktop
    self.publish = publish
  }
}

extension ReleaseTool {
  public static func publicEnvironment(_ environment: [String: String]) -> [String: String] {
    environment.filter {
      ![
        "POLKA_SIGNING_P12", "POLKA_SIGNING_PASSWORD", "SPARKLE_PRIVATE_KEY", "CSC_LINK",
        "CSC_KEY_PASSWORD",
      ].contains($0.key)
    }
  }
  @discardableResult public static func verifyRelease(context: ToolContext = ToolContext()) throws
    -> [String]
  {
    let original = try PolkaMetadata.load(root: context.root)
    var selected = try resolved(original, environment: context.environment)
    let configuration = try self.configuration(
      metadata: selected.metadata, environment: context.environment)
    selected.metadata.releaseNotes = try ReleaseNotes.read(
      version: selected.metadata.version, root: context.root
    ).bilingual
    let bundle = context.root.appendingPathComponent(
      "release/native/\(selected.metadata.build.productName).app")
    _ = try SigningTool.verify(
      bundle: bundle, appId: selected.metadata.build.appId,
      fingerprint: SigningTool.fingerprint(context.environment))
    let directory = context.root.appendingPathComponent("release")
    let names = try ReleaseMetadata.verify(
      metadata: selected.metadata, directory: directory,
      repository: configuration.release.repository, publicKey: configuration.release.publicKey,
      tag: selected.tag)
    try Command.run(
      "/usr/bin/hdiutil", ["verify", directory.appendingPathComponent(names[0]).path],
      environment: publicEnvironment(context.environment), directory: context.root)
    return names
  }
  @discardableResult public static func release(
    options: ReleaseOptions = ReleaseOptions(),
    context: ToolContext = ToolContext()
  ) throws -> PackageResult {
    let original = try PolkaMetadata.load(root: context.root)
    var selected = try resolved(original, environment: context.environment)
    let configuration = try self.configuration(
      metadata: selected.metadata, environment: context.environment)
    let notes = try ReleaseNotes.read(version: selected.metadata.version, root: context.root)
    selected.metadata.releaseNotes = notes.bilingual
    guard !(context.environment["SPARKLE_PRIVATE_KEY"] ?? "").isEmpty else {
      throw ToolError("SPARKLE_PRIVATE_KEY is required to sign update archives.")
    }
    if options.publish && (context.environment["GH_TOKEN"] ?? "").isEmpty {
      throw ToolError("GH_TOKEN is required for draft release upload.")
    }
    let artifactsDirectory = context.root.appendingPathComponent("artifacts")
    try Files.mkdir(artifactsDirectory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(configuration).write(
      to: artifactsDirectory.appendingPathComponent("release-config.json"), options: .atomic)
    try Data(notes.markdown(tag: selected.tag, repository: configuration.release.repository).utf8)
      .write(to: artifactsDirectory.appendingPathComponent("release-notes.md"), options: .atomic)
    let result = try PackageTool.package(
      options: PackageOptions(official: true, prebuilt: options.prebuilt, desktop: options.desktop),
      context: context)
    let names = try verifyRelease(context: context)
    let archives = names.filter { $0.hasSuffix(".dmg") || $0.hasSuffix(".zip") }
    let checksumLines =
      try archives.map { name in
        let digest = SHA256.hash(
          data: try Data(contentsOf: result.output.appendingPathComponent(name)))
        return digest.map { String(format: "%02x", $0) }.joined() + "  " + name
      }.joined(separator: "\n") + "\n"
    try Data(checksumLines.utf8).write(
      to: result.output.appendingPathComponent("checksums.txt"), options: .atomic)
    if options.publish {
      let environment = publicEnvironment(context.environment)
      let sha = try Command.capture(
        "git", ["rev-parse", "HEAD"], environment: environment, directory: context.root
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
      guard sha.range(of: #"^[0-9a-f]{40,64}\z"#, options: .regularExpression) != nil else {
        throw ToolError("Release must be built from a Git commit.")
      }
      let tagged = try Command.execute(
        "git", ["rev-parse", "refs/tags/\(selected.tag)^{commit}"], environment: environment,
        directory: context.root)
      if tagged.status == 0 && tagged.output.trimmingCharacters(in: .whitespacesAndNewlines) != sha
      {
        throw ToolError("Release tag does not resolve to the source that was packaged.")
      }
      let paths = (names + ["checksums.txt"]).map { result.output.appendingPathComponent($0).path }
      try Command.run(
        "gh",
        ["release", "create", selected.tag] + paths + [
          "--draft", "--repo", configuration.release.repository,
          "--target", sha, "--title",
          "\(selected.metadata.build.productName) \(selected.metadata.version)",
          "--notes-file", artifactsDirectory.appendingPathComponent("release-notes.md").path,
        ], environment: environment, directory: context.root)
    }
    var packaged = result
    packaged.artifacts.append(result.output.appendingPathComponent("checksums.txt"))
    return packaged
  }
  public static func notesCommand(arguments: [String], context: ToolContext = ToolContext()) throws
  {
    if arguments.count == 2 && arguments[0] == "--version" {
      print(try ReleaseVersion.parse(arguments[1]))
      return
    }
    guard (2...3).contains(arguments.count) else {
      throw ToolError("Usage: polka release-notes TAG OUTPUT.md [SOURCE.json]")
    }
    let tag = arguments[0]
    let version = try ReleaseVersion.parse(tag)
    func path(_ value: String) -> URL {
      value.hasPrefix("/")
        ? URL(fileURLWithPath: value).standardizedFileURL
        : context.root.appendingPathComponent(value).standardizedFileURL
    }
    let source = arguments.count == 3 ? path(arguments[2]) : nil
    let notes = try ReleaseNotes.read(version: version, root: context.root, source: source)
    let repository =
      [context.environment["RELEASE_REPOSITORY"], context.environment["GITHUB_REPOSITORY"]]
      .compactMap { $0 }.first { !$0.isEmpty } ?? "mishankov/polka"
    try Data(notes.markdown(tag: tag, repository: repository).utf8).write(
      to: path(arguments[1]), options: .atomic)
  }
  public static func createSigningCertificate(
    arguments: [String], context: ToolContext = ToolContext()
  ) throws {
    guard arguments.count == 1, arguments[0].hasPrefix("/") else {
      throw ToolError("Usage: polka create-signing-certificate /absolute/secure/backup/directory")
    }
    let directory = URL(fileURLWithPath: arguments[0], relativeTo: context.root).standardizedFileURL
    let fingerprint = try SigningTool.createCertificate(
      directory: directory, environment: context.environment)
    print("Persistent signing identity created in \(directory.path).")
    print("Certificate SHA-1 (public): \(fingerprint)")
    print("Back up this directory securely. Reuse this certificate for every release.")
  }
}
