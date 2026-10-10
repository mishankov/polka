import Darwin
import Foundation
import PolkaCore
import XCTest

@testable import PolkaApp

final class HelperProcessTests: XCTestCase {
  var roots: [URL] = []
  override func tearDown() {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
  }
  func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PolkaHelperTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }
  func arguments(_ script: String, _ extra: [String] = []) -> [String] {
    ["python3", "-u", "-c", script] + extra
  }
  func waitForPID(_ path: URL) async throws -> pid_t {
    for _ in 0..<100 {
      if let text = try? String(contentsOf: path, encoding: .utf8), let pid = Int32(text) {
        return pid
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(domain: "SyntheticFixture", code: 1)
  }
  func testCommandCancellationReapsChildThatIgnoresTermination() async throws {
    let pidPath = try root().appendingPathComponent("pid")
    let script =
      "import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(60)"
    let task = Task {
      try await NativeCommand.run(
        URL(fileURLWithPath: "/usr/bin/env"), arguments: arguments(script, [pidPath.path]),
        timeout: 30)
    }
    let pid = try await waitForPID(pidPath)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled process returned success")
    } catch is CancellationError {} catch { XCTFail("Wrong cancellation error: \(error)") }
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }
  func testCommandTimeoutKillsAndReapsIgnoringChild() async throws {
    let pidPath = try root().appendingPathComponent("pid")
    let script =
      "import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(60)"
    let started = Date()
    do {
      _ = try await NativeCommand.run(
        URL(fileURLWithPath: "/usr/bin/env"), arguments: arguments(script, [pidPath.path]),
        timeout: 0.1)
      XCTFail("Timeout accepted")
    } catch {
      XCTAssertTrue(error.localizedDescription == localized("The helper did not respond in time"))
    }
    let pid = try await waitForPID(pidPath)
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }
  func testCommandDrainsLargeOutputWithoutLostFinalBytesOrPipeDeadlock() async throws {
    let input = Data((0..<150_000).map { UInt8($0 % 251) })
    let output = try await NativeCommand.run(
      URL(fileURLWithPath: "/usr/bin/env"),
      arguments: arguments(
        "import sys; data=sys.stdin.buffer.read(); sys.stderr.buffer.write(b'x'*150000); sys.stdout.buffer.write(data)"
      ), stdin: input, timeout: 5, limit: 200_000)
    XCTAssertEqual(output, input)
  }
  func testHelperClosingStdinEarlyCannotSendSIGPIPEToApplication() async throws {
    let output = try await NativeCommand.run(
      URL(fileURLWithPath: "/usr/bin/env"),
      arguments: arguments("import os,sys; os.close(0); sys.stdout.write('closed input safely')"),
      stdin: Data(repeating: 31, count: 2 * 1024 * 1024), timeout: 5)
    XCTAssertEqual(String(data: output, encoding: .utf8), "closed input safely")
  }
  func testCommandOutputCapTerminatesAndReaps() async throws {
    let pidPath = try root().appendingPathComponent("pid")
    let script =
      "import os,sys,time; open(sys.argv[1],'w').write(str(os.getpid())); sys.stdout.buffer.write(b'x'*100000); sys.stdout.flush(); time.sleep(60)"
    do {
      _ = try await NativeCommand.run(
        URL(fileURLWithPath: "/usr/bin/env"), arguments: arguments(script, [pidPath.path]),
        timeout: 10, limit: 1024)
      XCTFail("Output cap ignored")
    } catch {
      XCTAssertTrue(error.localizedDescription == localized("Helper response is too large"))
    }
    let pid = try await waitForPID(pidPath)
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }
  @MainActor func testHelperRestartReapsOldGenerationAndExplicitStopSuppressesExit() async throws {
    let pidPath = try root().appendingPathComponent("pid")
    let helper = HelperProcess()
    var exits: [Int32] = []
    var messages: [String] = []
    helper.onExit = { exits.append($0) }
    helper.onMessage = { if let type = $0["type"] as? String { messages.append(type) } }
    try helper.start(
      URL(fileURLWithPath: "/usr/bin/env"),
      arguments: arguments(
        "import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); print('{\"type\":\"old\"}'); time.sleep(60)",
        [pidPath.path]))
    let oldPID = try await waitForPID(pidPath)
    let script =
      "import json,sys; print('{\"type\":\"ready\"}');\nfor line in sys.stdin:\n c=json.loads(line); print(json.dumps({'type':'paste.reply','id':c['id'],'result':{'method':c.get('method')}}))"
    try helper.start(URL(fileURLWithPath: "/usr/bin/env"), arguments: arguments(script))
    XCTAssertEqual(kill(oldPID, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    let response = await helper.request("status")
    XCTAssertEqual(response["method"] as? String, "status")
    XCTAssertTrue(messages.contains("ready"))
    XCTAssertTrue(exits.isEmpty)
    helper.stop()
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(exits.isEmpty)
    XCTAssertFalse(helper.running)
  }
  @MainActor func testHelperCancellationCompletesPendingRequest() async throws {
    let helper = HelperProcess()
    try helper.start(
      URL(fileURLWithPath: "/usr/bin/env"),
      arguments: arguments("import time; print('{\"type\":\"ready\"}'); time.sleep(60)"))
    let request = Task { await helper.request("capture") }
    await Task.yield()
    request.cancel()
    let response = await request.value
    XCTAssertTrue(response.isEmpty)
    helper.stop()
  }
}
