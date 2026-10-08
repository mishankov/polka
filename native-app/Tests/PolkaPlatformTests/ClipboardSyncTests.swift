import Foundation
import NIOCore
import NIOPosix
import PolkaCore
import XCTest

@testable import PolkaApp

final class ClipboardSyncTests: XCTestCase {
  let codec = SyntheticEncryptionCodec(key: Data(repeating: 97, count: 32))
  var roots: [URL] = []
  override func tearDown() {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
  }
  func make(_ name: String) throws -> (ClipboardHistory, NativeClipboardSync, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PolkaSyncTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    let history = ClipboardHistory(path: root.appendingPathComponent("history.enc"), codec: codec)
    try history.initialize()
    return (
      history,
      NativeClipboardSync(
        path: root.appendingPathComponent("sync.enc"), codec: codec, history: history, name: name,
        discovery: false), root
    )
  }
  func exchange(_ a: NativeClipboardSync, _ b: NativeClipboardSync) async throws {
    for _ in 0..<5 {
      await a.syncNow()
      await b.syncNow()
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }
  func testTLSLoopbackPairTransferSnippetEditPauseForgetAndRestart() async throws {
    let (a, sa, ar) = try make("Mac A")
    let (b, sb, _) = try make("Mac B")
    try await sa.initialize()
    try await sb.initialize()
    try await sa.setEnabled(true)
    try await sb.setEnabled(true)
    sa.discover(id: b.deviceId, name: "Mac B", host: "127.0.0.1", port: sb.port)
    sb.discover(id: a.deviceId, name: "Mac A", host: "127.0.0.1", port: sa.port)
    try a.add(.text, content: "Synthetic A", preview: "Synthetic A")
    try b.add(.text, content: "Synthetic B", preview: "Synthetic B")
    let snippet = try a.createSnippet(content: "Address", name: "Home")
    try sa.invite()
    let code = try XCTUnwrap(sa.state().invitation?.code)
    try await sb.pair(code)
    try await exchange(sa, sb)
    XCTAssertEqual(Set(a.snapshot().clips.map(\.content)), Set(["Synthetic A", "Synthetic B"]))
    XCTAssertEqual(b.find(snippet)?.name, "Home")
    try b.edit(snippet, content: "Edited on B", name: "Work")
    try await exchange(sa, sb)
    XCTAssertEqual(a.find(snippet)?.content, "Edited on B")
    XCTAssertEqual(sa.state().peers.first?.status, "connected")
    XCTAssertEqual(sb.state().peers.first?.status, "connected")
    var prefs = b.getPreferences()
    prefs.paused = true
    try b.setPreferences(prefs)
    try a.add(.text, content: "While B paused", preview: "While B paused")
    try await exchange(sa, sb)
    XCTAssertNil(b.find(clipId(.text, "While B paused")))
    XCTAssertEqual(sb.state().status, "paused")
    prefs.paused = false
    try b.setPreferences(prefs)
    try await exchange(sa, sb)
    XCTAssertNotNil(b.find(clipId(.text, "While B paused")))
    await sa.stop()
    let restored = NativeClipboardSync(
      path: ar.appendingPathComponent("sync.enc"), codec: codec, history: a, name: "Mac A",
      discovery: false)
    try await restored.initialize()
    XCTAssertEqual(restored.state().peers.first?.id, b.deviceId)
    XCTAssertEqual(restored.state().enabled, true)
    restored.discover(id: b.deviceId, name: "Mac B", host: "127.0.0.1", port: sb.port)
    sb.discover(id: a.deviceId, name: "Mac A", host: "127.0.0.1", port: restored.port)
    try await restored.forget(b.deviceId)
    try b.createSnippet(content: "After forgetting")
    try await exchange(restored, sb)
    XCTAssertFalse(a.snapshot().snippets.contains { $0.content == "After forgetting" })
    XCTAssertTrue(restored.state().peers.isEmpty)
    await restored.stop()
    await sb.stop()
    XCTAssertNil(
      String(data: try Data(contentsOf: ar.appendingPathComponent("sync.enc")), encoding: .utf8))
  }
  func testChangedCertificatePinRejectsBeforePairing() async throws {
    let (a, sa, _) = try make("Mac A")
    let (b, sb, _) = try make("Mac B")
    try await sa.initialize()
    try await sb.initialize()
    try await sa.setEnabled(true)
    try await sb.setEnabled(true)
    sb.discover(id: a.deviceId, name: "Mac A", host: "127.0.0.1", port: sa.port)
    try sa.invite()
    let code = try XCTUnwrap(sa.state().invitation?.code)
    var base64 = code.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    var payload =
      try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: base64)))
      as! [String: Any]
    payload["fingerprint"] = Array(repeating: "00", count: 32).joined(separator: ":")
    let forged = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    do {
      try await sb.pair(forged)
      XCTFail("Forged certificate pin accepted")
    } catch {}
    XCTAssertTrue(sa.state().peers.isEmpty)
    XCTAssertTrue(sb.state().peers.isEmpty)
    XCTAssertNotNil(sa.state().invitation)
    XCTAssertNotEqual(a.deviceId, b.deviceId)
    await sa.stop()
    await sb.stop()
  }
  func testCorruptSyncStoreBlocksOnlySyncAndKeepsOriginalBytes() async throws {
    let (history, sync, root) = try make("Mac A")
    let bytes = Data("synthetic corrupt sync".utf8)
    let path = root.appendingPathComponent("sync.enc")
    try bytes.write(to: path)
    do {
      try await sync.initialize()
      XCTFail("Corruption accepted")
    } catch {}
    XCTAssertEqual(sync.state().status, "failed")
    XCTAssertEqual(sync.storage.state().diagnostic?.stage, "decrypt")
    XCTAssertEqual(try Data(contentsOf: path), bytes)
    try history.add(
      .text, content: "Local history still works", preview: "Local history still works")
    XCTAssertEqual(history.snapshot().clips.count, 1)
    do {
      try await sync.setEnabled(true)
      XCTFail("Failed store reopened")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: path), bytes)
    await sync.stop()
  }
  func testIndependentSwiftPeerProtocolWithInMemoryPEM() async throws {
    let (history, sync, _) = try make("Native Mac")
    let (_, identity, identityRoot) = try make("Independent identity")
    try await sync.initialize()
    try await identity.initialize()
    try await sync.setEnabled(true)
    var credentials =
      try JSONSerialization.jsonObject(
        with: codec.decode(Data(contentsOf: identityRoot.appendingPathComponent("sync.enc"))))
      as! [String: Any]
    credentials["id"] = UUID().uuidString.lowercased()
    credentials["name"] = "Independent fixture"
    let process = Process()
    process.executableURL = try independentFixture()
    // The standalone wire peer is outside product coverage and is terminated by
    // the test. Keep its incomplete process profile out of XCTest collection.
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["LLVM_PROFILE_FILE": "/dev/null"], uniquingKeysWith: { _, fixture in fixture })
    process.arguments = ["server"]
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
      if process.isRunning { process.terminate() }
    }
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    try input.fileHandleForWriting.write(
      contentsOf: JSONSerialization.data(withJSONObject: credentials) + Data([10]))
    let ready =
      try JSONSerialization.jsonObject(with: readLine(output.fileHandleForReading))
      as! [String: Any]
    sync.discover(
      id: ready["id"] as! String, name: "Independent fixture", host: "127.0.0.1",
      port: ready["port"] as! Int)
    let snippet = try history.createSnippet(
      content: "Native to independent peer fixture", name: "Native snippet")
    try await sync.pair(ready["code"] as! String)
    for _ in 0..<5 {
      await sync.syncNow()
      if history.find(clipId(.text, "Independent peer to native fixture")) != nil { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNotNil(history.find(clipId(.text, "Independent peer to native fixture")))
    let received =
      try JSONSerialization.jsonObject(with: readLine(output.fileHandleForReading))
      as! [String: Any]
    XCTAssertEqual(received["id"] as? String, snippet)
    XCTAssertEqual(received["content"] as? String, "Native to independent peer fixture")
    XCTAssertEqual(received["snippet"] as? Bool, true)
    XCTAssertEqual(received["tls"] as? String, "TLSv1.3")
    XCTAssertEqual(received["sourceDevice"] as? String, "Native Mac")
    await sync.stop()
    await identity.stop()
    process.terminate()
  }
  func testIndependentSwiftClientPairsAndPushesIntoNativeServer() async throws {
    let (history, sync, _) = try make("Native server")
    let (_, identity, identityRoot) = try make("Independent identity")
    try await sync.initialize()
    try await identity.initialize()
    try await sync.setEnabled(true)
    try sync.invite()
    let snippet = try history.createSnippet(content: "Native server fixture")
    var config =
      try JSONSerialization.jsonObject(
        with: codec.decode(Data(contentsOf: identityRoot.appendingPathComponent("sync.enc"))))
      as! [String: Any]
    config["id"] = UUID().uuidString.lowercased()
    config["code"] = try XCTUnwrap(sync.state().invitation?.code)
    config["port"] = sync.port
    let process = Process()
    process.executableURL = try independentFixture()
    // The standalone wire peer is outside product coverage and is terminated by
    // the test. Keep its incomplete process profile out of XCTest collection.
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["LLVM_PROFILE_FILE": "/dev/null"], uniquingKeysWith: { _, fixture in fixture })
    process.arguments = ["client"]
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
      if process.isRunning { process.terminate() }
    }
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    try input.fileHandleForWriting.write(
      contentsOf: JSONSerialization.data(withJSONObject: config) + Data([10]))
    let result =
      try JSONSerialization.jsonObject(with: readLine(output.fileHandleForReading))
      as! [String: Any]
    XCTAssertNil(result["error"])
    XCTAssertEqual(result["paired"] as? String, history.deviceId)
    XCTAssertTrue((result["initial"] as? [String] ?? []).contains(snippet))
    XCTAssertEqual(result["content"] as? String, "Independent client to native fixture")
    XCTAssertEqual(result["sourceDevice"] as? String, "Independent client fixture")
    XCTAssertEqual(result["hasOCR"] as? Bool, false)
    XCTAssertNotNil(history.find(clipId(.text, "Independent client to native fixture")))
    await sync.stop()
    await identity.stop()
  }
  func testConcurrentLifecycleNeverReopensStoppedListener() async throws {
    let (_, sync, _) = try make("Synthetic Lifecycle")
    try await sync.initialize()
    for _ in 0..<10 {
      let first = Task { try await sync.setEnabled(true) }
      let second = Task { try await sync.setEnabled(true) }
      await Task.yield()
      try await sync.setEnabled(false)
      try await first.value
      try await second.value
      // An enable can legally acquire the mutation lock after disable. Stop is terminal
      // for every listener opened by either completed enable operation.
      await sync.stop()
      XCTAssertEqual(sync.port, 0)
      XCTAssertNil(sync.state().invitation)
    }
    try await sync.setEnabled(true)
    XCTAssertGreaterThan(sync.port, 0)
    await sync.stop()
    XCTAssertEqual(sync.port, 0)
  }

  func testClientInitializerStopAndSetupErrorsCompleteResponseExactlyOnce() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { group.shutdownGracefully { _ in } }
    let loop = group.next()
    enum InitializationError: Error { case synthetic }
    for failure in [0, 1, 2] {
      let response = NativeSyncRequestResponse(loop: loop)
      let initialized = response.initialize(loop: loop, accepted: failure != 0) {
        if failure == 1 { throw InitializationError.synthetic }
        return loop.makeFailedFuture(InitializationError.synthetic)
      }
      do {
        try await initialized.get()
        XCTFail("Initializer failure was accepted")
      } catch {}
      do {
        _ = try await response.promise.futureResult.get()
        XCTFail("Response was left ready")
      } catch {}
      // Simulates subsequent channelInactive / TLS errors. Double-completion
      // used to either assert or leave the earlier response promise unfulfilled.
      response.fail(InitializationError.synthetic)
      response.succeed(Data("late reply".utf8))
    }
    let success = NativeSyncRequestResponse(loop: loop)
    success.succeed(Data("complete reply".utf8))
    success.fail(InitializationError.synthetic)
    let reply = try await success.promise.futureResult.get()
    XCTAssertEqual(reply, Data("complete reply".utf8))
  }
  private func independentFixture() throws -> URL {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    #if DEBUG
      let configuration = "debug"
    #else
      let configuration = "release"
    #endif
    let binary = package.appendingPathComponent(".build/\(configuration)/PolkaSyncFixture")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw PolkaCoreError.invalid(
        "Build the independent Swift TLS fixture with the native test target")
    }
    return binary
  }
  private func readLine(_ handle: FileHandle) throws -> Data {
    var line = Data()
    while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
      if byte[0] == 10 { return line }
      line.append(byte)
      guard line.count < 1_000_000 else { throw PolkaCoreError.invalid("Fixture output too large") }
    }
    throw PolkaCoreError.invalid("Fixture terminated")
  }
}
