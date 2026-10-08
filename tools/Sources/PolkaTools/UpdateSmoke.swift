import CCommonCrypto
import CryptoKit
import Foundation

public enum UpdateSmoke {
  /// Synthetic v10 data exercises the real shared encrypted-history migration.
  static func envelope(_ plaintext: Data, password: Data) throws -> Data {
    let salt = Data("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: 16)
    let derived = password.withUnsafeBytes { secret in
      salt.withUnsafeBytes { bytes in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress!.assumingMemoryBound(to: Int8.self),
          password.count,
          bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, 16)
      }
    }
    guard derived == kCCSuccess else { throw DesktopFailure("Synthetic history derivation failed") }
    var output = [UInt8](repeating: 0, count: plaintext.count + 16)
    var moved = 0
    let capacity = output.count
    let iv = [UInt8](repeating: 32, count: 16)
    let status = plaintext.withUnsafeBytes { source in
      key.withUnsafeBytes { keyBytes in
        iv.withUnsafeBytes { vector in
          CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            keyBytes.baseAddress, 16, vector.baseAddress, source.baseAddress, plaintext.count,
            &output, capacity, &moved)
        }
      }
    }
    guard status == kCCSuccess else { throw DesktopFailure("Synthetic history encryption failed") }
    return Data("v10".utf8) + Data(output.prefix(moved))
  }
  static func nextVersion(_ version: String) throws -> String {
    let parts = version.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 3, parts[2] < Int.max else {
      throw DesktopFailure("Updater fixture requires a numeric three-component version")
    }
    return "\(parts[0]).\(parts[1]).\(parts[2] + 1)"
  }
  static func preserves(_ receipt: [String: Any], collection: String, id: String, content: String)
    -> Bool
  {
    (receipt[collection] as? [[String: Any]] ?? []).contains {
      $0["id"] as? String == id && $0["content"] as? String == content
    }
  }
  public static func run(
    prebuilt: Bool = false, release: Bool = false, context: ToolContext = ToolContext()
  ) async throws {
    #if !arch(arm64)
      throw DesktopFailure("Native updater tests require an Apple silicon Mac")
    #else
      var oldMetadata = try PolkaMetadata.load(root: context.root)
      let next = try nextVersion(oldMetadata.version)
      let lock = try await DesktopLock.acquire()
      defer { try? lock.release() }
      let directory = try Desktop.directory("polka-native-update-")
      let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
      let appID = "app.polka.native-update-test.\(stamp)"
      let product = "Polka Update Test \(stamp)"
      let profile = directory.appendingPathComponent("profile")
      let receipt = profile.appendingPathComponent("relaunch.json")
      let artifacts = context.root.appendingPathComponent("artifacts/desktop/native-updates")
      let password = SymmetricKey(size: .bits192).withUnsafeBytes { Data($0).base64EncodedString() }
      let signing = Curve25519.Signing.PrivateKey()
      let publicKey = signing.publicKey.rawRepresentation.base64EncodedString()
      let privateKey = signing.rawRepresentation.base64EncodedString()
      oldMetadata.build.appId = appID
      oldMetadata.build.productName = product
      var newMetadata = oldMetadata
      newMetadata.version = next
      newMetadata.releaseNotes = BilingualNotes(
        ru: "• Обновлена нативная полка.", en: "• Updated the native shelf.")
      let server: UpdateHTTPServer
      do { server = try UpdateHTTPServer() } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
      defer { server.stop() }
      var child: DesktopChild?
      var logs: [String] = []
      var passed = false
      let clipID = SHA256.hash(data: Data("native updater clip".utf8)).map {
        String(format: "%02x", $0)
      }.joined()
      let snippetID = SHA256.hash(data: Data("native updater snippet".utf8)).map {
        String(format: "%02x", $0)
      }.joined()
      let clipContent = "Synthetic native history survives an update"
      let snippetContent = "Synthetic native reusable reply"
      let oldBundle = directory.appendingPathComponent("installed/\(product).app")
      let newBundle = directory.appendingPathComponent("candidate/\(product).app")
      func bundleVersion() throws -> String {
        try Command.capture(
          "/usr/libexec/PlistBuddy",
          [
            "-c", "Print :CFBundleVersion",
            oldBundle.appendingPathComponent("Contents/Info.plist").path,
          ]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      func assertBundleVersion(_ expected: String, _ message: String) throws {
        let actual = try bundleVersion()
        try Desktop.require(actual == expected, message)
      }
      func command(_ name: String) throws {
        try Files.writeJSON(
          ["id": UUID().uuidString, "name": name],
          to: profile.appendingPathComponent("command.json"))
      }
      func launch() throws {
        try? FileManager.default.removeItem(at: profile.appendingPathComponent("command.json"))
        try? FileManager.default.removeItem(at: receipt)
        child = try DesktopChild(
          executable: oldBundle.appendingPathComponent("Contents/MacOS/PolkaNative"), arguments: [],
          environment: Desktop.environment(context.environment))
      }
      func receiptWhere(
        _ label: String, timeout: TimeInterval = 90, predicate: ([String: Any]) -> Bool
      ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
          if let json = try? Files.json(receipt) as? [String: Any] {
            last = json
            if predicate(json) { return json }
          }
          if let child, !child.process.isRunning && child.process.terminationStatus != 0 {
            throw DesktopFailure(
              "Fixture exited \(child.process.terminationStatus): \(label)\n\(child.diagnostics)")
          }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DesktopFailure("\(label): \(last)")
      }
      func persist() {
        if let child { logs.append(child.diagnostics) }
        try? Files.mkdir(artifacts)
        try? Data(logs.joined().utf8).write(to: artifacts.appendingPathComponent("app.log"))
        try? Files.writeJSON(
          [
            "ok": passed, "fromVersion": oldMetadata.version, "toVersion": newMetadata.version,
            "requests": server.requestLog,
          ], to: artifacts.appendingPathComponent("result.json"))
        if let bytes = try? Data(contentsOf: receipt) {
          try? bytes.write(to: artifacts.appendingPathComponent("receipt.json"))
        }
      }
      func cleanup() async throws {
        if let child { try await child.stop() }
        try await UpdateFixtureCleanup.stop(directory: directory, appID: appID)
        for path in [
          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Caches/\(appID)"),
          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Preferences/\(appID).plist"), directory,
        ] {
          if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
          }
        }
      }
      do {
        let historyPath = profile.appendingPathComponent("clipboard-history/history.enc")
        try Files.mkdir(historyPath.deletingLastPathComponent())
        let now = Date().timeIntervalSince1970 * 1000
        let history: [String: Any] = [
          "version": 1,
          "clips": [
            [
              "id": clipID, "kind": "text", "content": clipContent,
              "preview": "Synthetic native history", "createdAt": now, "pinned": true,
            ]
          ],
          "snippets": [
            [
              "id": snippetID, "kind": "text", "content": snippetContent,
              "preview": "Synthetic native reply", "createdAt": now, "pinned": false,
              "snippet": true, "name": "Update snippet",
            ]
          ],
          "preferences": [
            "paused": true, "pasteOnSelect": false, "hoverEnabled": false, "retentionDays": 7,
            "accelerator": "",
          ],
        ]
        try envelope(JSONSerialization.data(withJSONObject: history), password: Data(password.utf8))
          .write(to: historyPath)
        let certificate = directory.appendingPathComponent("certificate")
        let fingerprint = try SigningTool.createCertificate(directory: certificate)
        var env = Desktop.environment(context.environment)
        env["RELEASE_REPOSITORY"] = "smoke/native"
        env["SPARKLE_PUBLIC_KEY"] = publicKey
        env["POLKA_SIGNING_CERT_SHA1"] = fingerprint
        env["POLKA_SIGNING_P12"] = certificate.appendingPathComponent("identity.p12").path
        env["POLKA_SIGNING_PASSWORD"] = try String(
          contentsOf: certificate.appendingPathComponent("password.txt"), encoding: .utf8)
        try SigningTool.withKeychain(env) { publicEnv in
          for (metadata, bundle, reuse) in [
            (oldMetadata, oldBundle, prebuilt), (newMetadata, newBundle, true),
          ] {
            var buildEnv = publicEnv
            buildEnv["RELEASE_TAG"] = "v\(metadata.version)"
            _ = try BuildTool.build(
              options: BuildOptions(
                release: release, official: true, prebuilt: reuse, bundlePath: bundle,
                sourceMetadata: metadata,
                updateFixture: UpdateFixture(
                  profile: profile, receipt: receipt,
                  password: Data(password.utf8).base64EncodedString(),
                  feed: URL(string: server.origin + "/appcast.xml"))),
              context: ToolContext(root: context.root, environment: buildEnv))
          }
        }
        let filename = try ReleaseMetadata.artifactNames(metadata: newMetadata).first {
          $0.hasSuffix(".zip")
        }!
        let archive = directory.appendingPathComponent(filename)
        try Command.run(
          "/usr/bin/ditto",
          ["-c", "-k", "--sequesterRsrc", "--keepParent", newBundle.path, archive.path])
        let archiveBytes = try Data(contentsOf: archive)
        let signature = try Command.capture(
          context.root.appendingPathComponent(
            "native-app/.build/artifacts/sparkle/Sparkle/bin/sign_update"
          ).path,
          ["--ed-key-file", "-", "-p", archive.path], input: Data(privateKey.utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let validFeed = try ReleaseMetadata.appcast(
          metadata: newMetadata, repository: "smoke/native", signature: signature,
          size: archiveBytes.count
        )
        .replacingOccurrences(
          of:
            "https://github.com/smoke/native/releases/download/v\(newMetadata.version)/\(filename)",
          with: server.origin + "/" + filename)
        server.set(
          feed: validFeed.replacingOccurrences(
            of: signature, with: Data(repeating: 0, count: 64).base64EncodedString()),
          archive: archiveBytes)
        try launch()
        _ = try await receiptWhere("Tampered archive is rejected") {
          ($0["updates"] as? [String: Any])?["status"] as? String == "error"
        }
        try assertBundleVersion(oldMetadata.version, "Tampered archive replaced the app")
        server.set(feed: validFeed, archive: archiveBytes)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try command("updates.check")
        _ = try await receiptWhere("Authenticated update is staged") {
          ($0["updates"] as? [String: Any])?["status"] as? String == "ready"
        }
        try assertBundleVersion(oldMetadata.version, "Download installed without authorization")
        try command("system.quit")
        try await child!.wait(timeout: 10)
        try await child!.stop()
        logs.append(child!.diagnostics)
        child = nil
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try assertBundleVersion(oldMetadata.version, "Ordinary quit installed staged update")
        try launch()
        let restarted = try await receiptWhere("Native app restarts with encrypted data") {
          $0["version"] as? String == oldMetadata.version
            && $0["storageStatus"] as? String == "ready"
        }
        try Desktop.require(
          preserves(restarted, collection: "clips", id: clipID, content: clipContent),
          "Restart lost synthetic encrypted history")
        _ = try await receiptWhere("Update is staged again after restart") {
          ($0["updates"] as? [String: Any])?["status"] as? String == "ready"
        }
        try command("updates.install")
        let installed = try await receiptWhere("Sparkle installs and relaunches native app") {
          $0["version"] as? String == newMetadata.version
        }
        try Desktop.require(
          installed["storageStatus"] as? String == "ready", "Updated encrypted storage not ready")
        try Desktop.require(
          preserves(installed, collection: "clips", id: clipID, content: clipContent),
          "Update lost encrypted history")
        try Desktop.require(
          preserves(installed, collection: "snippets", id: snippetID, content: snippetContent),
          "Update lost encrypted snippets")
        try assertBundleVersion(newMetadata.version, "Installed bundle has wrong version")
        _ = try SigningTool.verify(bundle: oldBundle, appId: appID, fingerprint: fingerprint)
        passed = true
        persist()
        try await cleanup()
        print(
          "Native update smoke passed: tamper rejection, staging, ordinary quit cancellation, explicit install, relaunch, signatures and encrypted data."
        )
      } catch {
        persist()
        try await Task.detached { try await cleanup() }.value
        throw error
      }
    #endif
  }
}
