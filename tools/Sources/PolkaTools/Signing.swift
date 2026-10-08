import Darwin
import Foundation

public enum SigningTool {
  public static let nativeHelpers = [
    "clipboard-probe", "media-probe", "sync-discovery", "image-text", "file-shelf-probe",
  ]
  public static func publicEnvironment(_ environment: [String: String]) -> [String: String] {
    environment.filter {
      !["POLKA_SIGNING_P12", "POLKA_SIGNING_PASSWORD", "SPARKLE_PRIVATE_KEY"].contains($0.key)
    }
  }
  public static func fingerprint(_ environment: [String: String]) throws -> String {
    let value =
      environment["POLKA_SIGNING_CERT_SHA1"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard ToolFiles.matches(value, "^[A-Fa-f0-9]{40}$") else {
      throw ToolError(
        "POLKA_SIGNING_CERT_SHA1 must pin the persistent code-signing certificate (40 hex digits).")
    }
    return value.uppercased()
  }
  static func certificateFingerprint(_ certificate: Data, environment: [String: String]) throws
    -> String
  {
    let text = try Command.capture(
      "openssl", ["x509", "-noout", "-fingerprint", "-sha1"], environment: environment,
      input: certificate)
    guard let suffix = text.split(separator: "=").last else {
      throw ToolError("Invalid signing certificate.")
    }
    return try fingerprint([
      "POLKA_SIGNING_CERT_SHA1": suffix.replacingOccurrences(of: ":", with: "")
    ])
  }
  static func validateCertificate(
    _ certificate: Data, environment: [String: String], expectedName: String? = nil
  ) throws {
    let text = try Command.capture(
      "openssl", ["x509", "-noout", "-dates", "-subject", "-nameopt", "RFC2253"],
      environment: environment, input: certificate)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
    let lines = text.components(separatedBy: .newlines)
    func date(_ prefix: String) -> Date? {
      lines.first(where: { $0.hasPrefix(prefix) }).flatMap {
        formatter.date(from: String($0.dropFirst(prefix.count)))
      }
    }
    guard let start = date("notBefore="), let end = date("notAfter="), start <= Date(), end > Date()
    else {
      throw ToolError("Code-signing certificate is not currently valid.")
    }
    if let expectedName {
      let subject = lines.first(where: { $0.hasPrefix("subject=") }) ?? ""
      guard
        subject.components(separatedBy: ",").contains(where: {
          $0 == "CN=" + expectedName || $0 == "subject=CN=" + expectedName
        })
      else {
        throw ToolError("Unexpected development signing certificate name.")
      }
    }
  }
  public static func createCertificate(
    directory: URL, name: String = "Polka Release Signing",
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> String {
    guard directory.path.hasPrefix("/"),
      ToolFiles.matches(name, "^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$")
    else {
      throw ToolError("Use an absolute certificate backup directory and plain certificate name.")
    }
    guard mkdir(directory.path, 0o700) == 0 else { throw ToolFiles.posixError() }
    let scratch = try ToolFiles.temporary("polka-certificate-")
    defer { try? ToolFiles.remove(scratch) }
    do {
      let password = ToolFiles.random().base64EncodedString()
      let key = scratch.appendingPathComponent("private.pem")
      let certificate = directory.appendingPathComponent("certificate.pem")
      _ = try Command.capture(
        "openssl",
        [
          "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256", "-days", "3650", "-subj",
          "/CN=\(name)/O=Polka", "-keyout", key.path, "-out", certificate.path, "-addext",
          "basicConstraints=critical,CA:FALSE", "-addext", "keyUsage=critical,digitalSignature",
          "-addext", "extendedKeyUsage=critical,codeSigning",
        ], environment: publicEnvironment(environment))
      var secretEnvironment = publicEnvironment(environment)
      secretEnvironment["POLKA_SIGNING_PASSWORD"] = password
      let p12 = directory.appendingPathComponent("identity.p12")
      _ = try Command.capture(
        "openssl",
        [
          "pkcs12", "-export", "-inkey", key.path, "-in", certificate.path, "-out", p12.path,
          "-name", name, "-passout", "env:POLKA_SIGNING_PASSWORD", "-keypbe", "PBE-SHA1-3DES",
          "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
        ], environment: secretEnvironment)
      let fingerprint = try certificateFingerprint(
        Data(contentsOf: certificate), environment: publicEnvironment(environment))
      try ToolFiles.write(password, to: directory.appendingPathComponent("password.txt"))
      try ToolFiles.write(
        fingerprint + "\n", to: directory.appendingPathComponent("fingerprint.txt"))
      guard chmod(p12.path, 0o600) == 0 else { throw ToolFiles.posixError() }
      return fingerprint
    } catch {
      try? ToolFiles.remove(directory)
      throw error
    }
  }
  public static func withKeychain<T>(
    _ environment: [String: String], work: ([String: String]) throws -> T
  ) throws -> T {
    let fingerprint = try self.fingerprint(environment)
    guard let backup = environment["POLKA_SIGNING_P12"],
      let backupPassword = environment["POLKA_SIGNING_PASSWORD"], !backupPassword.isEmpty
    else {
      throw ToolError("POLKA_SIGNING_P12 and POLKA_SIGNING_PASSWORD are required.")
    }
    let scratch = try ToolFiles.temporary("polka-signing-")
    let keychain = scratch.appendingPathComponent("signing.keychain-db")
    var created = false
    defer {
      if created {
        _ = try? Command.capture(
          "/usr/bin/security", ["delete-keychain", keychain.path],
          environment: publicEnvironment(environment), cancellable: false)
      }
      try? ToolFiles.remove(scratch)
    }
    let p12 = scratch.appendingPathComponent("identity.p12")
    let bytes: Data
    if backup.hasPrefix("/") {
      bytes = try Data(contentsOf: URL(fileURLWithPath: backup))
    } else if let decoded = Data(base64Encoded: backup), !decoded.isEmpty {
      bytes = decoded
    } else {
      throw ToolError("Invalid signing certificate backup.")
    }
    try ToolFiles.write(bytes, to: p12)
    var passwordEnvironment = publicEnvironment(environment)
    passwordEnvironment["POLKA_SIGNING_PASSWORD"] = backupPassword
    let certificate = try Command.capture(
      "openssl",
      ["pkcs12", "-in", p12.path, "-passin", "env:POLKA_SIGNING_PASSWORD", "-clcerts", "-nokeys"],
      environment: passwordEnvironment)
    guard
      try certificateFingerprint(
        Data(certificate.utf8), environment: publicEnvironment(environment)) == fingerprint
    else {
      throw ToolError(
        "Signing certificate does not match POLKA_SIGNING_CERT_SHA1. Refusing identity rotation.")
    }
    try validateCertificate(Data(certificate.utf8), environment: publicEnvironment(environment))
    let password = ToolFiles.random().base64EncodedString()
    let publicEnvironment = self.publicEnvironment(environment)
    _ = try Command.capture(
      "/usr/bin/security", ["create-keychain", "-p", password, keychain.path],
      environment: publicEnvironment)
    created = true
    _ = try Command.capture(
      "/usr/bin/security", ["set-keychain-settings", "-lut", "21600", keychain.path],
      environment: publicEnvironment)
    _ = try Command.capture(
      "/usr/bin/security", ["unlock-keychain", "-p", password, keychain.path],
      environment: publicEnvironment)
    _ = try Command.capture(
      "/usr/bin/security",
      ["import", p12.path, "-k", keychain.path, "-P", backupPassword, "-T", "/usr/bin/codesign"],
      environment: publicEnvironment)
    _ = try Command.capture(
      "/usr/bin/security",
      ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain.path],
      environment: publicEnvironment)
    try ToolFiles.remove(p12)
    var buildEnvironment = publicEnvironment
    buildEnvironment["POLKA_SIGNING_KEYCHAIN"] = keychain.path
    buildEnvironment["POLKA_SIGNING_CERT_SHA1"] = fingerprint
    return try work(buildEnvironment)
  }
  static func requirement(_ identifier: String, _ fingerprint: String) -> String {
    "identifier \(ToolFiles.jsonString(identifier)) and certificate leaf = H\"\(fingerprint)\""
  }
  static func codesign(
    _ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> String {
    let result = try Command.execute(
      "/usr/bin/codesign", args, environment: publicEnvironment(environment))
    guard result.status == 0 else {
      throw ToolError("codesign failed (\(result.status)).", exitCode: result.status)
    }
    return result.output + result.error
  }
  public static func verify(bundle: URL, appId: String, fingerprint: String) throws -> [String:
    String]
  {
    let fingerprint = try self.fingerprint(["POLKA_SIGNING_CERT_SHA1": fingerprint])
    var requirements: [String: String] = [:]
    for (path, identifier) in [(bundle, appId)]
      + nativeHelpers.map({
        (bundle.appendingPathComponent("Contents/Resources/" + $0), appId + "." + $0)
      })
    {
      _ = try codesign([
        "--verify", "--strict", "-R", "=" + requirement(identifier, fingerprint), path.path,
      ])
      let details = try codesign(["--display", "-r-", path.path])
      guard
        let designated = details.components(separatedBy: .newlines).first(where: {
          $0.hasPrefix("designated => ")
        }).map({ String($0.dropFirst(14)) }),
        !designated.lowercased().contains("cdhash"), designated.uppercased().contains(fingerprint)
      else {
        throw ToolError("Unstable designated requirement for \(identifier).")
      }
      requirements[identifier] = designated
    }
    _ = try codesign(["--verify", "--deep", "--strict", bundle.path])
    return requirements
  }
  public static func targets(bundle: URL) throws -> [URL] {
    var targets: [URL] = []
    func visit(_ directory: URL) throws {
      for name in try ToolFiles.manager.contentsOfDirectory(atPath: directory.path) {
        let url = directory.appendingPathComponent(name)
        guard let info = try ToolFiles.metadata(url) else { continue }
        if info.st_mode & S_IFMT == S_IFLNK { continue }
        if info.st_mode & S_IFMT == S_IFDIR {
          try visit(url)
          if ["framework", "app", "xpc"].contains(url.pathExtension) { targets.append(url) }
        } else if ToolFiles.regular(info) {
          let file = try FileHandle(forReadingFrom: url)
          let bytes = try file.read(upToCount: 4) ?? Data()
          try file.close()
          let magic = bytes.map { String(format: "%02x", $0) }.joined()
          if [
            "feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca", "cafebabf",
            "bfbafeca",
          ].contains(magic) {
            targets.append(url)
          }
        }
      }
    }
    try visit(bundle)
    return targets.sorted {
      $0.pathComponents.count == $1.pathComponents.count
        ? $0.path < $1.path : $0.pathComponents.count > $1.pathComponents.count
    } + [bundle]
  }
  public static func sign(
    bundle: URL, appId: String, entitlements: URL? = nil, environment: [String: String]
  ) throws {
    let fingerprint = try self.fingerprint(environment)
    guard let keychain = environment["POLKA_SIGNING_KEYCHAIN"], !keychain.isEmpty else {
      throw ToolError("Release signing requires an isolated POLKA_SIGNING_KEYCHAIN.")
    }
    guard ToolFiles.matches(appId, "^[A-Za-z0-9][A-Za-z0-9.-]+$") else {
      throw ToolError("Invalid native app identifier.")
    }
    let targets = try self.targets(bundle: bundle)
    let helperIDs = Dictionary(
      uniqueKeysWithValues: nativeHelpers.map {
        (bundle.appendingPathComponent("Contents/Resources/" + $0).path, appId + "." + $0)
      })
    for path in helperIDs.keys {
      guard targets.contains(where: { $0.path == path }) else {
        throw ToolError(
          "Missing native helper code: \(URL(fileURLWithPath: path).lastPathComponent) (\(targets.count) signing targets)."
        )
      }
    }
    for path in targets {
      var identifier = path == bundle ? appId : helperIDs[path.path]
      if identifier == nil, ["framework", "app", "xpc"].contains(path.pathExtension) {
        let info = path.appendingPathComponent(
          path.pathExtension == "framework" ? "Resources/Info.plist" : "Contents/Info.plist")
        if let plist = try? Data(contentsOf: info),
          let dictionary = try? PropertyListSerialization.propertyList(from: plist, format: nil)
            as? [String: Any]
        {
          identifier = dictionary["CFBundleIdentifier"] as? String
        }
      }
      if identifier == nil {
        let display = try Command.execute(
          "/usr/bin/codesign", ["--display", "--verbose=2", path.path],
          environment: publicEnvironment(environment))
        identifier = (display.output + display.error).components(separatedBy: .newlines).first(
          where: { $0.hasPrefix("Identifier=") }).map { String($0.dropFirst(11)) }
      }
      let id =
        identifier ?? appId + "."
        + ToolFiles.relative(path, to: bundle).replacingOccurrences(of: "/", with: ".")
        .replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression)
      var arguments = [
        "--force", "--sign", fingerprint, "--keychain", keychain, "--timestamp=none", "--options",
        "0", "--identifier", id, "--requirements", "=designated => " + requirement(id, fingerprint),
      ]
      if path.path.contains("/Sparkle.framework/"),
        ToolFiles.matches(path.path, #"/Downloader\.xpc(?:/Contents/MacOS/Downloader)?$"#)
      {
        arguments.append("--preserve-metadata=entitlements")
      }
      if path == bundle, let entitlements { arguments += ["--entitlements", entitlements.path] }
      _ = try codesign(arguments + [path.path], environment: environment)
      _ = try codesign(
        ["--verify", "--strict", "-R", "=" + requirement(id, fingerprint), path.path],
        environment: environment)
    }
    _ = try verify(bundle: bundle, appId: appId, fingerprint: fingerprint)
  }
}
