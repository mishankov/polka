import CryptoKit
import Foundation
import XCTest

@testable import PolkaTools

final class ReleaseTests: XCTestCase {
  private let metadata = PolkaMetadata(
    version: "0.2.0", build: .init(appId: "app.polka.release-test"))
  private func temporary() throws -> URL { try Files.temporary("polka-release-tests") }
  private func fixture(notes: BilingualNotes? = nil, tag: String? = nil) throws -> (
    URL, PolkaMetadata, String, String, Data
  ) {
    let directory = try temporary()
    var package = metadata
    package.releaseNotes = notes
    let key = Curve25519.Signing.PrivateKey()
    let bytes = Data("signed release bytes".utf8)
    let signature = try key.signature(for: bytes).base64EncodedString()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let xml = try ReleaseMetadata.appcast(
      metadata: package, repository: "owner/app", signature: signature,
      size: bytes.count, tag: tag, date: Date(timeIntervalSince1970: 0))
    for name in try ReleaseMetadata.artifactNames(metadata: package) {
      try bytes.write(to: directory.appendingPathComponent(name))
    }
    try Data(xml.utf8).write(to: directory.appendingPathComponent("appcast.xml"))
    return (directory, package, publicKey, xml, bytes)
  }
  func testSemanticTagsResolveVersionWithoutChangingMetadata() throws {
    for tag in ["v1.4.0", "1.4.0", "v1.4.0-beta.1"] {
      let result = try ReleaseTool.resolved(metadata, environment: ["RELEASE_TAG": tag])
      XCTAssertEqual(result.tag, tag)
      XCTAssertEqual(result.metadata.version, tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
      XCTAssertEqual(metadata.version, "0.2.0")
      XCTAssertTrue(
        try ReleaseMetadata.artifactNames(metadata: result.metadata).contains(
          "polka-\(result.metadata.version)-arm64.zip"))
    }
    XCTAssertEqual(try ReleaseTool.resolved(metadata, environment: [:]).tag, "v0.2.0")
    for tag in ["latest", "v1.4", "v1.4.0/path", "v01.4.0", "v1.4.0\n"] {
      XCTAssertThrowsError(try ReleaseVersion.parse(tag), tag)
    }
  }
  func testConfigurationValidatesPublicTrustAndNeverSerializesSecrets() throws {
    let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      .base64EncodedString()
    let environment = [
      "RELEASE_REPOSITORY": "owner/app", "SPARKLE_PUBLIC_KEY": publicKey,
      "POLKA_SIGNING_CERT_SHA1": String(repeating: "a", count: 40),
      "POLKA_SIGNING_P12": "private-certificate", "POLKA_SIGNING_PASSWORD": "private-password",
      "SPARKLE_PRIVATE_KEY": "secret",
    ]
    let configuration = try ReleaseTool.configuration(metadata: metadata, environment: environment)
    XCTAssertEqual(configuration.signing.fingerprint, String(repeating: "A", count: 40))
    XCTAssertEqual(
      configuration.release.feedUrl,
      "https://github.com/owner/app/releases/latest/download/appcast.xml")
    XCTAssertEqual(configuration.release.updater, "sparkle")
    XCTAssertEqual(configuration.minimumSystemVersion, "27.0")
    XCTAssertFalse(configuration.signing.notarize)
    let encoded = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
    for value in ["private-certificate", "private-password", "secret"] {
      XCTAssertFalse(encoded.contains(value))
    }
    for removed in ["RELEASE_REPOSITORY", "SPARKLE_PUBLIC_KEY", "POLKA_SIGNING_CERT_SHA1"] {
      var invalid = environment
      invalid.removeValue(forKey: removed)
      XCTAssertThrowsError(try ReleaseTool.configuration(metadata: metadata, environment: invalid))
    }
    for repository in ["owner/app/path", "owner", "owner/app?private=true", "owner/app\n"] {
      var invalid = environment
      invalid["RELEASE_REPOSITORY"] = repository
      XCTAssertThrowsError(try ReleaseTool.configuration(metadata: metadata, environment: invalid))
    }
    let adHoc = try ReleaseTool.configuration(
      metadata: metadata,
      environment: ["RELEASE_REPOSITORY": "smoke/app", "SPARKLE_PUBLIC_KEY": publicKey], adHoc: true
    )
    XCTAssertNil(adHoc.signing.fingerprint)
  }
  func testNotesValidateTranslationsAndUTF16Limit() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("notes.json")
    let notes = try ReleaseNotes(
      ru: "  • Исправлено <окно> & поиск.\nВторая строка.  ", en: "• Fixed <window> & search.")
    try JSONEncoder().encode(notes).write(to: path)
    XCTAssertEqual(try ReleaseNotes.read(version: "0.2.0", root: root, source: path), notes)
    XCTAssertEqual(
      try JSONDecoder().decode(ReleaseNotes.self, from: Data(notes.json().utf8)), notes)
    for value in [
      #"{"ru":"Без перевода"}"#, #"{"ru":" ","en":"English"}"#, #"{"ru":"Русский","en":null}"#,
    ] {
      try Data(value.utf8).write(to: path)
      XCTAssertThrowsError(try ReleaseNotes.read(version: "0.2.0", root: root, source: path))
    }
    XCTAssertNoThrow(try ReleaseNotes(ru: String(repeating: "😀", count: 10_000), en: "English"))
    XCTAssertThrowsError(try ReleaseNotes(ru: String(repeating: "😀", count: 10_001), en: "English"))
    XCTAssertThrowsError(try ReleaseNotes.read(version: "0.2.0", root: root))
  }
  func testNotesMarkdownIncludesBothLanguagesAndPinnedInstallation() throws {
    let notes = try ReleaseNotes(
      ru: "• Изменение.\n\nДля разработчиков\n• Инструмент.",
      en: "• Change.\n\nFor developers\n• Tool.")
    for tag in ["v1.4.0", "1.4.0", "v1.4.0-beta.1"] {
      let body = try notes.markdown(tag: tag, repository: "owner/app")
      XCTAssertTrue(body.hasPrefix("# Polka \(try ReleaseVersion.parse(tag))\n"))
      XCTAssertLessThan(
        body.range(of: "## English")!.lowerBound, body.range(of: "## Русский")!.lowerBound)
      XCTAssertEqual(body.components(separatedBy: "<details>").count - 1, 2)
      for number in [1, 2, 3] {
        XCTAssertEqual(body.components(separatedBy: "#### \(number).").count - 1, 2)
      }
      XCTAssertTrue(
        body.contains("releases/download/\(tag)/polka-\(try ReleaseVersion.parse(tag))-arm64.dmg"))
      XCTAssertTrue(body.contains("- Изменение.\n\nДля разработчиков\n- Инструмент."))
      XCTAssertTrue(body.contains("latest stable release"))
      XCTAssertTrue(body.contains("последний стабильный выпуск"))
      XCTAssertTrue(body.contains("⌘ ⇧ Space"))
      XCTAssertTrue(body.contains("⌘ ⇧ Пробел"))
    }
    XCTAssertThrowsError(try notes.markdown(tag: "latest"))
    XCTAssertThrowsError(try notes.markdown(tag: "v1.4.0", repository: "bad/path/more"))
  }
  func testSignedAppcastRejectsMetadataAndArchiveTampering() throws {
    let (directory, package, key, xml, bytes) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("appcast.xml")
    func check(_ key: String) throws -> [String] {
      try ReleaseMetadata.verify(
        metadata: package, directory: directory, repository: "owner/app", publicKey: key)
    }
    XCTAssertEqual(try check(key), try ReleaseMetadata.artifactNames(metadata: package))
    XCTAssertTrue(xml.contains("Thu, 01 Jan 1970 00:00:00 GMT"))
    for modified in [
      xml.replacingOccurrences(of: "/v0.2.0/polka-0.2.0-arm64.zip", with: "/v0.2.0/wrong.zip"),
      xml.replacingOccurrences(of: "<sparkle:version>0.2.0", with: "<sparkle:version>0.1.0"),
      xml.replacingOccurrences(of: "27.0", with: "26.0"),
      xml.replacingOccurrences(of: "length=\"\(bytes.count)\"", with: "length=\"1\""),
      xml.replacingOccurrences(of: "application/octet-stream", with: "text/plain"),
      xml.replacingOccurrences(
        of: "</item>", with: "<sparkle:version>0.2.0</sparkle:version></item>"),
      xml.replacingOccurrences(of: "xml-namespaces/sparkle", with: "xml-namespaces/evil"),
      xml.replacingOccurrences(of: "<channel>", with: "<channel><!DOCTYPE evil>"),
      xml.replacingOccurrences(of: "</rss>", with: ""),
    ] {
      try Data(modified.utf8).write(to: path)
      XCTAssertThrowsError(try check(key), modified)
    }
    try Data(xml.utf8).write(to: path)
    XCTAssertThrowsError(
      try check(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()))
    try Data(repeating: 1, count: bytes.count).write(
      to: directory.appendingPathComponent("polka-0.2.0-arm64.zip"))
    XCTAssertThrowsError(try check(key))
  }
  func testAppcastEscapesAndAuthenticatesBilingualText() throws {
    let notes = BilingualNotes(
      ru: "• Исправлено <окно> & поиск.\nСтрока \"вторая\".",
      en: "• Fixed <window> & search.\nSecond line.")
    let (directory, package, key, xml, _) = try fixture(notes: notes, tag: "0.2.0")
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertTrue(xml.contains("&lt;окно&gt;"))
    XCTAssertTrue(xml.contains("releases/download/0.2.0/"))
    XCTAssertNoThrow(
      try ReleaseMetadata.verify(
        metadata: package, directory: directory, repository: "owner/app", publicKey: key,
        tag: "0.2.0"))
    var other = package
    other.releaseNotes?.en = "Wrong version notes"
    XCTAssertThrowsError(
      try ReleaseMetadata.verify(
        metadata: other, directory: directory, repository: "owner/app", publicKey: key, tag: "0.2.0"
      ))
    XCTAssertThrowsError(
      try ReleaseMetadata.verify(
        metadata: package, directory: directory, repository: "owner/app", publicKey: key,
        tag: "v9.9.9"))
  }
  func testRejectsMultipleItemsAndSymlinkArchives() throws {
    let (directory, package, key, xml, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = xml.range(of: "<item>")!.lowerBound
    let end = xml.range(of: "</item>")!.upperBound
    let repeated = xml.replacingOccurrences(
      of: "</channel>", with: String(xml[start..<end]) + "</channel>")
    try Data(repeated.utf8).write(to: directory.appendingPathComponent("appcast.xml"))
    XCTAssertThrowsError(
      try ReleaseMetadata.verify(
        metadata: package, directory: directory, repository: "owner/app", publicKey: key))
    try Data(xml.utf8).write(to: directory.appendingPathComponent("appcast.xml"))
    let archive = directory.appendingPathComponent("polka-0.2.0-arm64.zip")
    let target = directory.appendingPathComponent("fixture.zip")
    try FileManager.default.moveItem(at: archive, to: target)
    try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: target)
    XCTAssertThrowsError(
      try ReleaseMetadata.verify(
        metadata: package, directory: directory, repository: "owner/app", publicKey: key))
  }
  func testExplicitSourceNotesWinOverCheckoutNotes() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try Files.mkdir(root.appendingPathComponent("release-notes"))
    let wrong = try ReleaseNotes(ru: "Неверный checkout", en: "Wrong checkout")
    let correct = try ReleaseNotes(ru: "Из выбранного commit", en: "From selected commit")
    try JSONEncoder().encode(wrong).write(
      to: root.appendingPathComponent("release-notes/0.2.0.json"))
    try JSONEncoder().encode(correct).write(to: root.appendingPathComponent("immutable.json"))
    try ReleaseTool.notesCommand(
      arguments: ["v0.2.0", "notes.md", "immutable.json"],
      context: ToolContext(root: root, environment: ["GITHUB_REPOSITORY": "fixture/app"]))
    let text = try String(contentsOf: root.appendingPathComponent("notes.md"), encoding: .utf8)
    XCTAssertTrue(text.contains("From selected commit"))
    XCTAssertFalse(text.contains("Wrong checkout"))
    XCTAssertTrue(text.contains("https://github.com/fixture/app/releases/download/v0.2.0/"))
    XCTAssertThrowsError(
      try ReleaseTool.notesCommand(arguments: ["v0.2.0"], context: ToolContext(root: root)))
  }
  func testReleaseStopsBeforePackagingWithoutSigningKeyOrPublishAuthorization() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent("polka.json"))
    try Files.mkdir(root.appendingPathComponent("release-notes"))
    try JSONEncoder().encode(ReleaseNotes(ru: "Изменение", en: "Change")).write(
      to: root.appendingPathComponent("release-notes/0.2.0.json"))
    var environment = [
      "RELEASE_REPOSITORY": "fixture/app",
      "POLKA_SIGNING_CERT_SHA1": String(repeating: "A", count: 40),
      "SPARKLE_PUBLIC_KEY": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        .base64EncodedString(),
    ]
    XCTAssertThrowsError(
      try ReleaseTool.release(context: ToolContext(root: root, environment: environment))
    ) { error in
      XCTAssertTrue(String(describing: error).contains("SPARKLE_PRIVATE_KEY"))
    }
    environment["SPARKLE_PRIVATE_KEY"] = "not-used-synthetic-key"
    XCTAssertThrowsError(
      try ReleaseTool.release(
        options: ReleaseOptions(publish: true),
        context: ToolContext(root: root, environment: environment))
    ) { error in
      XCTAssertTrue(String(describing: error).contains("GH_TOKEN"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts").path))
  }
  func testPublicEnvironmentRetainsExplicitGitHubAuthorizationButRemovesPrivateSigningInputs() {
    let environment = [
      "POLKA_SIGNING_P12": "p12", "POLKA_SIGNING_PASSWORD": "password",
      "SPARKLE_PRIVATE_KEY": "key",
      "CSC_LINK": "certificate", "CSC_KEY_PASSWORD": "password",
      "GH_TOKEN": "explicit-publish-token", "RELEASE_TAG": "v0.2.0",
    ]
    XCTAssertEqual(
      ReleaseTool.publicEnvironment(environment),
      ["GH_TOKEN": "explicit-publish-token", "RELEASE_TAG": "v0.2.0"])
    XCTAssertEqual(environment["POLKA_SIGNING_P12"], "p12")
  }

  func testCertificateCommandRejectsRelativeBackupBeforeCreatingFiles() {
    XCTAssertThrowsError(
      try ReleaseTool.createSigningCertificate(arguments: ["certificate-backup"]))
    XCTAssertThrowsError(try ReleaseTool.createSigningCertificate(arguments: []))
  }

}
