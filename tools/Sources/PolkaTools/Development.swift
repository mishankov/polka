import CryptoKit
import Darwin
import Foundation

public struct DevelopmentSigning: Equatable {
  public var fingerprint: String
  public var keychain: URL
  public init(fingerprint: String, keychain: URL) {
    self.fingerprint = fingerprint
    self.keychain = keychain
  }
}
public struct DevelopmentBroker: Equatable {
  public let path: URL
  public let identifier: String
  public let requirement: String
}
public enum DevelopmentTool {
  public static let signingDirectory = ToolFiles.manager.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/polka-development/signing")
  public static let brokerDirectory = ToolFiles.manager.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/polka-development/keychain-broker")
  static let certificateName = "Polka Native Development Signing"
  static let identityFiles = ["identity.p12", "password.txt", "fingerprint.txt", "certificate.pem"]
  static let compileOptions = [
    "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-framework", "Security", "-framework",
    "CoreFoundation",
  ]
  public static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #else
      return "x86_64"
    #endif
  }
  static func cacheError(_ directory: URL) -> ToolError {
    ToolError(
      "Development signing cache is incomplete or invalid: \(directory.path). Preserve and repair the original identity; it must not be regenerated silently."
    )
  }
  static func loadIdentity(_ directory: URL, environment: [String: String]) throws -> (
    fingerprint: String, password: String, p12: URL
  ) {
    do {
      guard let info = try ToolFiles.metadata(directory), info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == getuid()
      else { throw cacheError(directory) }
      for file in identityFiles {
        guard let info = try ToolFiles.metadata(directory.appendingPathComponent(file)),
          ToolFiles.regular(info), info.st_uid == getuid(), info.st_nlink == 1, info.st_size > 0
        else { throw cacheError(directory) }
      }
      guard chmod(directory.path, 0o700) == 0 else { throw ToolFiles.posixError() }
      for file in identityFiles {
        guard chmod(directory.appendingPathComponent(file).path, 0o600) == 0 else {
          throw ToolFiles.posixError()
        }
      }
      let password = try String(
        contentsOf: directory.appendingPathComponent("password.txt"), encoding: .utf8)
      guard !password.isEmpty, !password.contains("\0"), password.utf8.count <= 4096 else {
        throw cacheError(directory)
      }
      let fingerprint = try SigningTool.fingerprint([
        "POLKA_SIGNING_CERT_SHA1": String(
          contentsOf: directory.appendingPathComponent("fingerprint.txt"), encoding: .utf8)
      ])
      let certificate = try Data(contentsOf: directory.appendingPathComponent("certificate.pem"))
      let publicEnvironment = SigningTool.publicEnvironment(environment)
      guard
        try SigningTool.certificateFingerprint(certificate, environment: publicEnvironment)
          == fingerprint
      else { throw cacheError(directory) }
      try SigningTool.validateCertificate(
        certificate, environment: publicEnvironment, expectedName: certificateName)
      var secretEnvironment = publicEnvironment
      secretEnvironment["POLKA_SIGNING_PASSWORD"] = password
      let p12 = directory.appendingPathComponent("identity.p12")
      let backupCertificate = try Command.capture(
        "openssl",
        [
          "pkcs12", "-in", p12.path, "-passin", "env:POLKA_SIGNING_PASSWORD", "-clcerts", "-nokeys",
        ], environment: secretEnvironment)
      guard
        try SigningTool.certificateFingerprint(
          Data(backupCertificate.utf8), environment: publicEnvironment) == fingerprint
      else { throw cacheError(directory) }
      let privateKey = try Command.capture(
        "openssl",
        ["pkcs12", "-in", p12.path, "-passin", "env:POLKA_SIGNING_PASSWORD", "-nocerts", "-nodes"],
        environment: secretEnvironment)
      let privatePublic = try Command.capture(
        "openssl", ["pkey", "-pubout"], environment: publicEnvironment, input: Data(privateKey.utf8)
      )
      let certificatePublic = try Command.capture(
        "openssl", ["x509", "-pubkey", "-noout"], environment: publicEnvironment, input: certificate
      )
      guard privatePublic == certificatePublic else { throw cacheError(directory) }
      return (fingerprint, password, p12)
    } catch { throw cacheError(directory) }
  }
  static func identity(_ directory: URL, environment: [String: String]) throws -> (
    fingerprint: String, password: String, p12: URL
  ) {
    guard directory.path.hasPrefix("/") else { throw cacheError(directory) }
    try ToolFiles.noSymlinks(directory)
    if try ToolFiles.metadata(directory) != nil {
      return try loadIdentity(directory, environment: environment)
    }
    let parent = directory.deletingLastPathComponent()
    try ToolFiles.directory(parent)
    guard let info = try ToolFiles.metadata(parent), info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid()
    else { throw cacheError(directory) }
    guard chmod(parent.path, 0o700) == 0 else { throw ToolFiles.posixError() }
    let lock = parent.appendingPathComponent("." + directory.lastPathComponent + "-creation-lock")
    let deadline = Date().addingTimeInterval(30)
    while true {
      if try ToolFiles.metadata(directory) != nil {
        return try loadIdentity(directory, environment: environment)
      }
      if mkdir(lock.path, 0o700) == 0 { break }
      guard errno == EEXIST, Date() < deadline else { throw cacheError(directory) }
      Thread.sleep(forTimeInterval: 0.05)
    }
    defer { try? ToolFiles.remove(lock) }
    if try ToolFiles.metadata(directory) != nil {
      return try loadIdentity(directory, environment: environment)
    }
    let staging = try ToolFiles.temporary(
      "." + directory.lastPathComponent + "-pending-", parent: parent)
    defer { try? ToolFiles.remove(staging) }
    let identity = staging.appendingPathComponent("identity")
    _ = try SigningTool.createCertificate(
      directory: identity, name: certificateName, environment: environment)
    for file in identityFiles {
      guard chmod(identity.appendingPathComponent(file).path, 0o600) == 0 else {
        throw ToolFiles.posixError()
      }
    }
    _ = try loadIdentity(identity, environment: environment)
    if try ToolFiles.metadata(directory) == nil {
      if rename(identity.path, directory.path) != 0, errno != EEXIST && errno != ENOTEMPTY {
        throw ToolFiles.posixError()
      }
    }
    return try loadIdentity(directory, environment: environment)
  }
  public static func withSigning<T>(
    _ environment: [String: String], directory: URL = signingDirectory,
    work: ([String: String], DevelopmentSigning) throws -> T
  ) throws -> T {
    let identity = try self.identity(directory, environment: environment)
    var signingEnvironment = environment
    signingEnvironment["POLKA_SIGNING_P12"] = identity.p12.path
    signingEnvironment["POLKA_SIGNING_PASSWORD"] = identity.password
    signingEnvironment["POLKA_SIGNING_CERT_SHA1"] = identity.fingerprint
    return try SigningTool.withKeychain(signingEnvironment) { publicEnvironment in
      try work(
        publicEnvironment,
        DevelopmentSigning(
          fingerprint: identity.fingerprint,
          keychain: URL(fileURLWithPath: publicEnvironment["POLKA_SIGNING_KEYCHAIN"]!)))
    }
  }
  /// Match the existing cache digest exactly, retaining unchanged broker bytes.
  public static func brokerDigest(source: Data, appId: String, architecture: String = architecture)
    -> String
  {
    let options = "[" + compileOptions.map(ToolFiles.jsonString).joined(separator: ",") + "]"
    let configuration =
      "{\"format\":1,\"architecture\":\"\(architecture)\",\"compileOptions\":\(options)}"
    return ToolFiles.sha256(
      source + Data([0]) + Data(appId.utf8) + Data([0]) + Data(configuration.utf8))
  }
  static func validateBroker(_ path: URL, requirement: String, environment: [String: String]) throws
  {
    try ToolFiles.noSymlinks(path)
    guard let directory = try ToolFiles.metadata(path.deletingLastPathComponent()),
      ToolFiles.privateDirectory(directory),
      let binary = try ToolFiles.metadata(path), ToolFiles.regular(binary),
      binary.st_uid == getuid(), binary.st_mode & 0o777 == 0o700, binary.st_nlink == 1
    else {
      throw ToolError(
        "Development Keychain broker cache has unsafe ownership, type or permissions.")
    }
    _ = try SigningTool.codesign(
      ["--verify", "--strict", "--all-architectures", "-R", "=" + requirement, path.path],
      environment: environment)
    let details = try SigningTool.codesign(
      ["--display", "-r-", path.path], environment: environment)
    guard details.contains("designated => "), !details.lowercased().contains("cdhash") else {
      throw ToolError("Development Keychain broker must have a stable designated requirement.")
    }
  }
  public static func prepareBroker(
    _ signing: DevelopmentSigning, directory: URL = brokerDirectory,
    appId: String = "app.everything.desktop.native-development", sourcePath: URL? = nil,
    context: ToolContext = ToolContext()
  ) throws -> DevelopmentBroker {
    let fingerprint = try SigningTool.fingerprint(["POLKA_SIGNING_CERT_SHA1": signing.fingerprint])
    guard ToolFiles.matches(appId, "^[A-Za-z0-9][A-Za-z0-9.-]{0,199}$"),
      signing.keychain.path.hasPrefix("/")
    else { throw ToolError("Invalid development Keychain broker configuration.") }
    let sourcePath =
      sourcePath ?? context.root.appendingPathComponent("native-app/Development/KeychainBroker.c")
    try ToolFiles.noSymlinks(sourcePath)
    guard let sourceInfo = try ToolFiles.metadata(sourcePath), ToolFiles.regular(sourceInfo) else {
      throw ToolError("Development Keychain broker source must be a regular file.")
    }
    let source = try Data(contentsOf: sourcePath)
    let cache = directory.appendingPathComponent(
      fingerprint + "-" + brokerDigest(source: source, appId: appId), isDirectory: true)
    let path = cache.appendingPathComponent("polka-keychain-broker")
    let identifier = appId + ".keychain-broker"
    let requirement = SigningTool.requirement(identifier, fingerprint)
    let parentRequirement = SigningTool.requirement(appId, fingerprint)
    try ToolFiles.noSymlinks(directory)
    try ToolFiles.directory(directory)
    guard let info = try ToolFiles.metadata(directory), ToolFiles.privateDirectory(info) else {
      throw ToolError("Development broker cache directory requires owner-only mode 0700.")
    }
    if try ToolFiles.metadata(cache) != nil {
      try validateBroker(path, requirement: requirement, environment: context.environment)
      return DevelopmentBroker(path: path, identifier: identifier, requirement: requirement)
    }
    let staging = try ToolFiles.temporary(".broker-", parent: directory)
    defer { try? ToolFiles.remove(staging) }
    let binary = staging.appendingPathComponent("polka-keychain-broker")
    try ToolFiles.write(source, to: staging.appendingPathComponent("KeychainBroker.c"))
    try ToolFiles.write(
      "#define POLKA_PARENT_REQUIREMENT " + ToolFiles.jsonString(parentRequirement) + "\n",
      to: staging.appendingPathComponent("PolkaBrokerConfiguration.h"))
    _ = try Command.capture(
      "/usr/bin/xcrun",
      ["clang", "-arch", architecture] + compileOptions + [
        staging.appendingPathComponent("KeychainBroker.c").path, "-o", binary.path,
      ], environment: SigningTool.publicEnvironment(context.environment))
    guard chmod(binary.path, 0o700) == 0 else { throw ToolFiles.posixError() }
    _ = try SigningTool.codesign(
      [
        "--force", "--sign", fingerprint, "--keychain", signing.keychain.path, "--timestamp=none",
        "--identifier", identifier, "--requirements", "=designated => " + requirement, binary.path,
      ], environment: context.environment)
    try ToolFiles.remove(staging.appendingPathComponent("KeychainBroker.c"))
    try ToolFiles.remove(staging.appendingPathComponent("PolkaBrokerConfiguration.h"))
    try validateBroker(binary, requirement: requirement, environment: context.environment)
    if rename(staging.path, cache.path) != 0, errno != EEXIST && errno != ENOTEMPTY {
      throw ToolFiles.posixError()
    }
    try validateBroker(path, requirement: requirement, environment: context.environment)
    return DevelopmentBroker(path: path, identifier: identifier, requirement: requirement)
  }
}
