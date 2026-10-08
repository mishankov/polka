import AppKit
import Foundation
import PolkaCore
import Security

/// The dev executable changes on every build; the broker's signed bytes stay
/// fixed so Keychain's separate cdhash partition check retains Always Allow.
/// Passwords exist only in memory and the inherited anonymous pipe.
final class NativeDevelopmentKeychain {
  private let broker: URL
  private let fingerprint: String
  private let appId: String
  private let lock = NSLock()
  private var child: Process?
  private var stopped = false
  private var terminationObserver: NSObjectProtocol?

  init(broker: URL, fingerprint: String, appId: String) {
    self.broker = broker
    self.fingerprint = fingerprint
    self.appId = appId
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { [weak self] _ in self?.stop() }
  }

  deinit {
    if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    stop()
  }

  static func codec(bundle: Bundle = .main, allowCreate: Bool) -> NativeKeychainCodec? {
    guard bundle.object(forInfoDictionaryKey: "PolkaDevelopment") as? Bool == true,
      let fingerprint = bundle.object(forInfoDictionaryKey: "PolkaDevelopmentSigningFingerprint")
        as? String
    else { return nil }
    let reader = NativeDevelopmentKeychain(
      broker: bundle.resourceURL!.appendingPathComponent("polka-keychain-broker"),
      fingerprint: fingerprint, appId: bundle.bundleIdentifier ?? "")
    return NativeKeychainCodec(password: { try reader.password(allowCreate: allowCreate) })
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    stopped = true
    if let child, child.isRunning { child.terminate() }
  }

  private func verifySignatures() throws {
    guard fingerprint.range(of: "^[A-Fa-f0-9]{40}$", options: .regularExpression) != nil,
      appId.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    else { throw failure() }
    func requirement(_ identifier: String) throws -> SecRequirement {
      var result: SecRequirement?
      let expression = "identifier \"\(identifier)\" and certificate leaf = H\"\(fingerprint)\""
      guard SecRequirementCreateWithString(expression as CFString, [], &result) == errSecSuccess,
        let result
      else { throw failure() }
      return result
    }
    // Pin signed metadata to the actual app certificate before accepting its
    // broker pin. An altered Info.plist must not redefine who we trust.
    var ownCode: SecCode?
    guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
      SecCodeCheckValidity(
        ownCode, SecCSFlags(rawValue: kSecCSStrictValidate), try requirement(appId))
        == errSecSuccess
    else { throw failure() }
    var helperCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(broker as CFURL, [], &helperCode) == errSecSuccess,
      let helperCode,
      SecStaticCodeCheckValidity(
        helperCode, SecCSFlags(rawValue: kSecCSStrictValidate),
        try requirement(appId + ".keychain-broker")) == errSecSuccess
    else { throw failure() }
  }

  func password(allowCreate: Bool) throws -> Data {
    try verifySignatures()
    let process = Process()
    let pipe = Pipe()
    process.executableURL = broker
    process.arguments = allowCreate ? ["--allow-create"] : []
    // No dynamic loader overrides may replace the verified broker's code.
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    lock.lock()
    guard !stopped, child == nil else {
      lock.unlock()
      throw failure()
    }
    do {
      try process.run()
      child = process
      lock.unlock()
    } catch {
      lock.unlock()
      throw failure()
    }
    pipe.fileHandleForWriting.closeFile()
    defer {
      pipe.fileHandleForReading.closeFile()
      lock.lock()
      child = nil
      lock.unlock()
    }
    var password = Data()
    do {
      while let chunk = try pipe.fileHandleForReading.read(upToCount: 4097 - password.count),
        !chunk.isEmpty
      {
        password.append(chunk)
        guard password.count <= 4096 else { throw failure() }
      }
    } catch {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      throw failure()
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0,
      !password.isEmpty, password.count <= 4096
    else { throw failure() }
    return password
  }

  private func failure() -> PolkaCoreError {
    .storage(
      "Не удалось получить ключ шифрования из Связки ключей через помощник development-сборки")
  }
}
