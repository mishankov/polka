import CryptoKit
import Foundation

enum NativeProfile {
  struct UpdateFixture {
    let profile: URL
    let receipt: URL
    let password: Data
    let mode: String
  }
  static let update = updateFixture()
  static func updateFixture(bundle: Bundle = .main) -> UpdateFixture? {
    guard bundle.bundleIdentifier?.hasPrefix("app.polka.native-update-test.") == true,
      let value = bundle.object(forInfoDictionaryKey: "PolkaUpdateFixture") as? [String: String],
      let profilePath = value["profile"], let receiptPath = value["receipt"],
      let passwordValue = value["password"], let password = Data(base64Encoded: passwordValue),
      !password.isEmpty,
      profilePath.hasPrefix("/"), receiptPath.hasPrefix("/")
    else { return nil }
    let profile = URL(fileURLWithPath: profilePath).standardizedFileURL.resolvingSymlinksInPath()
    let receipt = URL(fileURLWithPath: receiptPath).standardizedFileURL.resolvingSymlinksInPath()
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    guard profile.path.hasPrefix(temporary + "/"), receipt.path.hasPrefix(profile.path + "/") else {
      return nil
    }
    return UpdateFixture(
      profile: profile, receipt: receipt, password: password, mode: value["mode"] ?? "receipt")
  }
  static var isolatedFixture: Bool {
    if update != nil { return true }
    guard ProcessInfo.processInfo.environment["POLKA_NATIVE_FIXTURE"] == "1",
      let override = ProcessInfo.processInfo.environment["POLKA_PROFILE"], !override.isEmpty
    else { return false }
    let root = URL(fileURLWithPath: override).standardizedFileURL.resolvingSymlinksInPath()
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    return root.path.hasPrefix(temporary.path + "/")
  }
  static func path(
    environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main
  ) -> URL {
    if let update = updateFixture(bundle: bundle) { return update.profile }
    if let override = environment["POLKA_PROFILE"], !override.isEmpty {
      return URL(fileURLWithPath: override).standardizedFileURL
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    if bundle.object(forInfoDictionaryKey: "PolkaDevelopment") as? Bool != true {
      return support.appendingPathComponent("Polka", isDirectory: true)
    }
    let checkout =
      bundle.object(forInfoDictionaryKey: "PolkaCheckout") as? String
      ?? FileManager.default.currentDirectoryPath
    let hash = SHA256.hash(data: Data(checkout.utf8)).map { String(format: "%02x", $0) }.joined()
      .prefix(12)
    return support.appendingPathComponent("polka-development").appendingPathComponent(
      "native-\(URL(fileURLWithPath: checkout).lastPathComponent)-\(hash)")
  }
  static func helper(_ name: String) -> URL {
    Bundle.main.resourceURL!.appendingPathComponent(name)
  }
}
