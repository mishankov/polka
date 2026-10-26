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
    if try DesktopVM.usesVM(context.environment) {
      var arguments = ["desktop", "updates"]
      if release { arguments.append("--release") }
      if prebuilt { arguments.append("--prebuilt") }
      try await DesktopVM.run(arguments: arguments, context: context)
      return
    }
    #if !arch(arm64)
      throw DesktopFailure("Native updater tests require an Apple silicon Mac")
    #else
      if context.environment["POLKA_DESKTOP_BACKEND"] == "guest" {
        guard context.environment["POLKA_VM_PREPARED_APP"] != nil,
          context.environment["POLKA_VM_SIGN_UPDATE"] != nil
        else { throw DesktopFailure("Updater checks require host-built runtime artifacts.") }
      }
      let preparedBundle = context.environment["POLKA_VM_PREPARED_APP"].map {
        URL(fileURLWithPath: $0)
      }
      let signUpdate =
        context.environment["POLKA_VM_SIGN_UPDATE"]
        ?? context.root.appendingPathComponent(
          "native-app/.build/artifacts/sparkle/Sparkle/bin/sign_update"
        ).path
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
      var stableMetadata = newMetadata
      stableMetadata.version = try nextVersion(newMetadata.version)
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
      func command(_ name: String, value: String? = nil) throws {
        var command = ["id": UUID().uuidString, "name": name]
        command["value"] = value
        try Files.writeJSON(
          command,
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
            "ok": passed, "fromVersion": oldMetadata.version, "toVersion": stableMetadata.version,
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
                  feed: URL(string: server.origin + "/appcast.xml")),
                preparedBundle: preparedBundle),
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
          signUpdate,
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
        // Preserve the stable install above, then test an actual numeric nightly
        // through the second feed, including persistence and a return to stable.
        var nightlyMetadata = newMetadata
        nightlyMetadata.version = try NightlyPreparation.version(
          base: newMetadata.version, date: Date(), runID: "1", attempt: "1")
        let nightlyBundle = directory.appendingPathComponent("nightly/\(product).app")
        try SigningTool.withKeychain(env) { publicEnv in
          var buildEnv = publicEnv
          buildEnv["RELEASE_CHANNEL"] = "nightly"
          buildEnv["RELEASE_TAG"] = "v\(nightlyMetadata.version)"
          _ = try BuildTool.build(
            options: BuildOptions(
              release: release, official: true, prebuilt: true, bundlePath: nightlyBundle,
              sourceMetadata: nightlyMetadata,
              updateFixture: UpdateFixture(
                profile: profile, receipt: receipt,
                password: Data(password.utf8).base64EncodedString(),
                feed: URL(string: server.origin + "/appcast.xml")),
              preparedBundle: preparedBundle),
            context: ToolContext(root: context.root, environment: buildEnv))
        }
        let nightlyFilename = try ReleaseMetadata.artifactNames(metadata: nightlyMetadata)[1]
        let nightlyArchive = directory.appendingPathComponent(nightlyFilename)
        try Command.run(
          "/usr/bin/ditto",
          ["-c", "-k", "--sequesterRsrc", "--keepParent", nightlyBundle.path, nightlyArchive.path])
        let nightlyBytes = try Data(contentsOf: nightlyArchive)
        let nightlySignature = try Command.capture(
          signUpdate,
          ["--ed-key-file", "-", "-p", nightlyArchive.path], input: Data(privateKey.utf8)
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let nightlyFeed = try ReleaseMetadata.appcast(
          metadata: nightlyMetadata, repository: "smoke/native", signature: nightlySignature,
          size: nightlyBytes.count
        ).replacingOccurrences(
          of: try ReleaseMetadata.archiveURL(metadata: nightlyMetadata, repository: "smoke/native"),
          with: server.origin + "/" + nightlyFilename)
        server.setNightly(feed: nightlyFeed, archive: nightlyBytes)
        _ = try await receiptWhere("Stable check finishes before channel selection") {
          ($0["updates"] as? [String: Any])?["status"] as? String == "current"
        }
        try command("updates.channel", value: "nightly")
        _ = try await receiptWhere("Nightly channel selects and stages a numeric version") {
          let update = $0["updates"] as? [String: Any]
          return update?["channel"] as? String == "nightly"
            && update?["status"] as? String == "ready"
        }
        try assertBundleVersion(
          newMetadata.version, "Channel selection installed without authorization")
        try command("updates.channel", value: "stable")
        _ = try await receiptWhere("Switching channels cancels the staged nightly") {
          let update = $0["updates"] as? [String: Any]
          return update?["channel"] as? String == "stable"
            && update?["status"] as? String == "current"
        }
        try assertBundleVersion(newMetadata.version, "Canceling the staged nightly installed it")
        try command("updates.channel", value: "nightly")
        _ = try await receiptWhere("Canceled nightly can be staged again") {
          let update = $0["updates"] as? [String: Any]
          return update?["channel"] as? String == "nightly"
            && update?["status"] as? String == "ready"
        }
        try command("updates.install")
        let nightlyInstalled = try await receiptWhere("Nightly installs and relaunches") {
          $0["version"] as? String == nightlyMetadata.version
        }
        try Desktop.require(
          preserves(nightlyInstalled, collection: "clips", id: clipID, content: clipContent),
          "Nightly update lost encrypted history")
        try Desktop.require(
          (nightlyInstalled["updates"] as? [String: Any])?["channel"] as? String == "nightly",
          "Nightly choice did not survive installation")
        try assertBundleVersion(
          ReleaseVersion.buildVersion(nightlyMetadata.version),
          "Nightly bundle has wrong numeric build version")
        _ = try SigningTool.verify(bundle: oldBundle, appId: appID, fingerprint: fingerprint)
        _ = try await receiptWhere("Nightly check finishes before returning to stable") {
          ($0["updates"] as? [String: Any])?["status"] as? String == "current"
        }
        try command("updates.channel", value: "stable")
        _ = try await receiptWhere("Returning to stable does not downgrade the nightly") {
          let update = $0["updates"] as? [String: Any]
          return update?["channel"] as? String == "stable"
            && update?["status"] as? String == "current"
        }
        try assertBundleVersion(
          ReleaseVersion.buildVersion(nightlyMetadata.version), "Stable feed downgraded a nightly")
        // A stable release must also reach clients that keep Nightly selected,
        // including already-installed versions that only know /nightly.xml.
        try command("updates.channel", value: "nightly")
        _ = try await receiptWhere("Nightly channel is current before stable publication") {
          let update = $0["updates"] as? [String: Any]
          return update?["channel"] as? String == "nightly"
            && update?["status"] as? String == "current"
        }
        let stableBundle = directory.appendingPathComponent("stable/\(product).app")
        try SigningTool.withKeychain(env) { publicEnv in
          var buildEnv = publicEnv
          buildEnv["RELEASE_TAG"] = "v\(stableMetadata.version)"
          _ = try BuildTool.build(
            options: BuildOptions(
              release: release, official: true, prebuilt: true, bundlePath: stableBundle,
              sourceMetadata: stableMetadata,
              updateFixture: UpdateFixture(
                profile: profile, receipt: receipt,
                password: Data(password.utf8).base64EncodedString(),
                feed: URL(string: server.origin + "/appcast.xml")),
              preparedBundle: preparedBundle),
            context: ToolContext(root: context.root, environment: buildEnv))
        }
        let stableFilename = try ReleaseMetadata.artifactNames(metadata: stableMetadata)[1]
        let stableArchive = directory.appendingPathComponent(stableFilename)
        try Command.run(
          "/usr/bin/ditto",
          ["-c", "-k", "--sequesterRsrc", "--keepParent", stableBundle.path, stableArchive.path])
        let stableBytes = try Data(contentsOf: stableArchive)
        let stableSignature = try Command.capture(
          signUpdate,
          ["--ed-key-file", "-", "-p", stableArchive.path], input: Data(privateKey.utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let stableFeed = try ReleaseMetadata.appcast(
          metadata: stableMetadata, repository: "smoke/native", signature: stableSignature,
          size: stableBytes.count
        ).replacingOccurrences(
          of: try ReleaseMetadata.archiveURL(metadata: stableMetadata, repository: "smoke/native"),
          with: server.origin + "/" + stableFilename)
        server.setNightly(feed: stableFeed, archive: stableBytes)
        try command("updates.check")
        _ = try await receiptWhere("Nightly channel stages the newer stable release") {
          let update = $0["updates"] as? [String: Any]
          return update?["channel"] as? String == "nightly"
            && update?["status"] as? String == "ready"
            && update?["version"] as? String == stableMetadata.version
        }
        try assertBundleVersion(
          ReleaseVersion.buildVersion(nightlyMetadata.version),
          "Stable release installed without authorization")
        try command("updates.install")
        let stableInstalled = try await receiptWhere("Stable installs through the nightly channel")
        {
          $0["version"] as? String == stableMetadata.version
        }
        try Desktop.require(
          (stableInstalled["updates"] as? [String: Any])?["channel"] as? String == "nightly",
          "Installing stable reset the nightly preference")
        for (collection, id, content) in [
          ("clips", clipID, clipContent), ("snippets", snippetID, snippetContent),
        ] {
          try Desktop.require(
            preserves(stableInstalled, collection: collection, id: id, content: content),
            "Stable update through nightly lost encrypted \(collection)")
        }
        try assertBundleVersion(stableMetadata.version, "Stable bundle has wrong build version")
        _ = try SigningTool.verify(bundle: oldBundle, appId: appID, fingerprint: fingerprint)
        passed = true
        persist()
        try await cleanup()
        print(
          "Native update smoke passed: tamper rejection, staging, ordinary quit cancellation, explicit install, relaunch, stable/nightly channels, stable installation through nightly, numeric ordering, signatures and encrypted data."
        )
      } catch {
        persist()
        try await Task.detached { try await cleanup() }.value
        throw error
      }
    #endif
  }
}
