import Foundation
import XCTest

@testable import PolkaTools

final class DevelopmentTests: XCTestCase {
  var projectRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }
  func testBrokerDigestPreservesExistingCacheAndSeparatesArchitectureAndIdentity() {
    let source = Data("synthetic broker source\n".utf8)
    XCTAssertEqual(
      DevelopmentTool.brokerDigest(
        source: source, appId: "app.polka.broker-test", architecture: "arm64"),
      "17dbceba9620ff914646fd6bc19df0b251adc9b62f51538eaa60c11b2902400a")
    XCTAssertNotEqual(
      DevelopmentTool.brokerDigest(
        source: source, appId: "app.polka.broker-test", architecture: "arm64"),
      DevelopmentTool.brokerDigest(
        source: source, appId: "app.polka.broker-test", architecture: "x86_64"))
    XCTAssertNotEqual(
      DevelopmentTool.brokerDigest(source: source, appId: "app.polka.broker-test"),
      DevelopmentTool.brokerDigest(source: source, appId: "app.polka.other"))
  }
  func testInvalidSigningCacheNeverRegeneratesAnIdentity() throws {
    let root = try ToolFiles.temporary("polka-tools-invalid-cache-")
    defer { try? ToolFiles.remove(root) }
    let cache = root.appendingPathComponent("signing")
    try ToolFiles.directory(cache)
    try ToolFiles.write("incomplete", to: cache.appendingPathComponent("identity.p12"))
    XCTAssertThrowsError(
      try DevelopmentTool.withSigning(ProcessInfo.processInfo.environment, directory: cache) {
        _, _ in ()
      })
    XCTAssertEqual(
      try String(contentsOf: cache.appendingPathComponent("identity.p12"), encoding: .utf8),
      "incomplete")
    let link = root.appendingPathComponent("link")
    try ToolFiles.manager.createSymbolicLink(at: link, withDestinationURL: cache)
    XCTAssertThrowsError(
      try DevelopmentTool.withSigning(ProcessInfo.processInfo.environment, directory: link) {
        _, _ in ()
      })
  }
  func testStableBrokerAuthorizesChangedParentAgainstDisposableKeychainOnly() throws {
    let root = try ToolFiles.temporary("polka-tools-broker-test-")
    defer { try? ToolFiles.remove(root) }
    let originalSearchList = try Command.capture(
      "/usr/bin/security", ["list-keychains", "-d", "user"])
    let keychain = root.appendingPathComponent("fixture.keychain-db")
    _ = try Command.capture(
      "/usr/bin/security", ["create-keychain", "-p", "synthetic-test-password", keychain.path])
    defer { _ = try? Command.capture("/usr/bin/security", ["delete-keychain", keychain.path]) }
    _ = try Command.capture(
      "/usr/bin/security", ["unlock-keychain", "-p", "synthetic-test-password", keychain.path])
    var source = try String(
      contentsOf: projectRoot.appendingPathComponent("native-app/Development/KeychainBroker.c"),
      encoding: .utf8)
    let queryMarker =
      "/* POLKA_FIXTURE_QUERY_SCOPE: synthetic tests may inject an isolated search list here. */"
    let addMarker =
      "/* POLKA_FIXTURE_ADD_SCOPE: synthetic tests may inject a fixed destination keychain here. */"
    XCTAssertTrue(source.contains(queryMarker))
    XCTAssertTrue(source.contains(addMarker))
    source = source.replacingOccurrences(
      of: "CFSTR(\"polka Safe Storage\")", with: "CFSTR(\"Polka synthetic fixture\")"
    ).replacingOccurrences(of: "CFSTR(\"polka\")", with: "CFSTR(\"fixture\")")
    source = source.replacingOccurrences(
      of: "#include \"PolkaBrokerConfiguration.h\"",
      with: """
        #include "PolkaBrokerConfiguration.h"
        #include <stdlib.h>
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        static SecKeychainRef fixture_keychain(void) {
          SecKeychainRef keychain = NULL;
          SecKeychainSetUserInteractionAllowed(false);
          if (SecKeychainOpen(\(ToolFiles.jsonString(keychain.path)), &keychain) != errSecSuccess) abort();
          return keychain;
        }
        """)
    source = source.replacingOccurrences(
      of: queryMarker,
      with: """
        SecKeychainRef keychain = fixture_keychain();
        const void *items[] = {keychain};
        CFArrayRef list = CFArrayCreate(NULL, items, 1, &kCFTypeArrayCallBacks);
        CFDictionarySetValue(query, kSecMatchSearchList, list);
        CFRelease(list); CFRelease(keychain);
        """
    ).replacingOccurrences(
      of: addMarker,
      with: """
        CFDictionaryRemoveValue(attributes, kSecMatchSearchList);
        SecKeychainRef keychain = fixture_keychain();
        CFDictionarySetValue(attributes, kSecUseKeychain, keychain);
        CFRelease(keychain);
        """)
    XCTAssertFalse(source.contains("CFSTR(\"polka Safe Storage\")"))
    let brokerSource = root.appendingPathComponent("FixtureBroker.c")
    try ToolFiles.write(source, to: brokerSource)
    let appId = "app.polka.tools-development-test"
    let certificateCache = root.appendingPathComponent("signing")
    let brokerCache = root.appendingPathComponent("brokers")
    var firstFingerprint = ""
    var firstBytes = Data()
    var firstCredentialHash = ""
    var cached: URL?
    for version in 1...2 {
      try DevelopmentTool.withSigning(
        ProcessInfo.processInfo.environment, directory: certificateCache
      ) { environment, signing in
        XCTAssertNil(environment["POLKA_SIGNING_PASSWORD"])
        XCTAssertNil(environment["POLKA_SIGNING_P12"])
        if firstFingerprint.isEmpty {
          firstFingerprint = signing.fingerprint
        } else {
          XCTAssertEqual(signing.fingerprint, firstFingerprint)
        }
        let broker = try DevelopmentTool.prepareBroker(
          signing, directory: brokerCache, appId: appId, sourcePath: brokerSource,
          context: ToolContext(root: projectRoot, environment: environment))
        cached = broker.path
        let bytes = try Data(contentsOf: broker.path)
        if version == 1 {
          firstBytes = bytes
        } else {
          XCTAssertEqual(ToolFiles.sha256(bytes), ToolFiles.sha256(firstBytes))
        }
        let callerSource = root.appendingPathComponent("Caller.c")
        let caller = root.appendingPathComponent("Caller\(version)")
        try ToolFiles.write(
          """
          #include <unistd.h>
          #include <sys/wait.h>
          #include <stdio.h>
          int build_version(void) { return \(version); }
          int main(int argc, char **argv) {
            if (argc < 2) return 90;
            int fds[2]; if (pipe(fds)) return 91;
            pid_t child = fork(); if (child < 0) return 92;
            if (child == 0) {
              close(fds[0]); dup2(fds[1], STDOUT_FILENO); close(fds[1]);
              if (argc == 3) execl(argv[1], argv[1], argv[2], NULL);
              else execl(argv[1], argv[1], NULL);
              _exit(93);
            }
            close(fds[1]); char bytes[256]; ssize_t count;
            while ((count = read(fds[0], bytes, sizeof(bytes))) > 0)
              if (fwrite(bytes, 1, count, stdout) != (size_t)count) return 94;
            close(fds[0]); int status; waitpid(child, &status, 0);
            return WIFEXITED(status) ? WEXITSTATUS(status) : 95;
          }
          """, to: callerSource)
        _ = try Command.capture(
          "/usr/bin/xcrun", ["clang", callerSource.path, "-o", caller.path],
          environment: environment)
        _ = try SigningTool.codesign(
          [
            "--force", "--sign", signing.fingerprint, "--keychain", signing.keychain.path,
            "--timestamp=none", "--identifier", appId, "--requirements",
            "=designated => " + SigningTool.requirement(appId, signing.fingerprint), caller.path,
          ], environment: environment)
        if version == 1 {
          let missing = try Command.execute(
            caller.path, [broker.path.path], environment: environment)
          XCTAssertEqual(missing.status, 1)
          XCTAssertTrue(missing.stdout.isEmpty)
          let created = try Command.execute(
            caller.path, [broker.path.path, "--allow-create"], environment: environment)
          XCTAssertEqual(created.status, 0)
          XCTAssertEqual(created.stdout.count, 24)
          XCTAssertEqual(Data(base64Encoded: created.stdout)?.count, 16)
          firstCredentialHash = ToolFiles.sha256(created.stdout)
        } else {
          let read = try Command.execute(caller.path, [broker.path.path], environment: environment)
          XCTAssertEqual(read.status, 0)
          XCTAssertEqual(ToolFiles.sha256(read.stdout), firstCredentialHash)
          _ = try SigningTool.codesign(
            ["--force", "--sign", "-", "--identifier", appId, caller.path], environment: environment
          )
          let rejected = try Command.execute(
            caller.path, [broker.path.path], environment: environment)
          XCTAssertEqual(rejected.status, 1)
          XCTAssertTrue(rejected.stdout.isEmpty)
          XCTAssertTrue(rejected.error.contains("caller is not authorized"))
        }
      }
    }
    XCTAssertEqual(
      originalSearchList,
      try Command.capture("/usr/bin/security", ["list-keychains", "-d", "user"]))
    XCTAssertNotNil(cached)
  }
}
