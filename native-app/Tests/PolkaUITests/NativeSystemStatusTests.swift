import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeSystemStatusTests: XCTestCase {
  @MainActor func testClosedSessionDiscardsInFlightResult() async throws {
    let model = NativeUIModel()
    var pending: CheckedContinuation<SystemStatusSnapshot, Never>?
    let monitor = SystemStatusMonitor(model: model, fixture: false) { _ in
      await withCheckedContinuation { pending = $0 }
    }
    defer { monitor.stop() }
    model.present(destination: "system-status")
    for _ in 0..<100 where pending == nil { await Task.yield() }
    let completion = try XCTUnwrap(pending)
    model.conceal()
    completion.resume(returning: NativeSystemStatusFixtures.snapshot("normal"))
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(monitor.sampleCount, 0)
    XCTAssertEqual(model.systemStatus.battery.state, .loading)
    XCTAssertNil(model.systemStatus.battery.value)
    XCTAssertTrue(model.systemStatus.activity.memory.isEmpty)
    XCTAssertTrue(model.systemStatus.activity.network.isEmpty)
  }
  @MainActor func testLifecycleStopsSamplesPreservesNavigationAndResumesImmediately() async throws {
    _ = NSApplication.shared
    let model = NativeUIModel()
    let monitor = SystemStatusMonitor(model: model, fixture: false, interval: 10_000_000) { _ in
      NativeSystemStatusFixtures.snapshot("normal")
    }
    defer { monitor.stop() }
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(monitor.sampleCount, 0)
    model.present(destination: "system-status")
    model.selectedID = "preserved"
    model.listScrollOffset = 42
    for _ in 0..<100 where monitor.sampleCount == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
    XCTAssertGreaterThan(monitor.sampleCount, 0)
    XCTAssertFalse(model.systemStatus.activity.memory.isEmpty)
    XCTAssertFalse(model.systemStatus.activity.network.isEmpty)
    XCTAssertEqual(model.selectedID, "preserved")
    XCTAssertEqual(model.listScrollOffset, 42)
    monitor.suspend("sleep", suspended: true)
    monitor.suspend("lock", suspended: true)
    let paused = monitor.sampleCount
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(monitor.sampleCount, paused)
    XCTAssertEqual(model.systemStatus.battery.state, .stale)
    XCTAssertTrue(model.systemStatus.activity.memory.isEmpty)
    XCTAssertTrue(model.systemStatus.activity.network.isEmpty)
    monitor.suspend("sleep", suspended: false)
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(monitor.sampleCount, paused)
    monitor.suspend("lock", suspended: false)
    for _ in 0..<100 where monitor.sampleCount == paused {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertGreaterThan(monitor.sampleCount, paused)
    XCTAssertFalse(model.systemStatus.activity.memory.isEmpty)
    model.present(destination: "apps")
    let closed = monitor.sampleCount
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(monitor.sampleCount, closed)
    XCTAssertTrue(model.systemStatus.activity.memory.isEmpty)
    model.present(destination: "system-status")
    model.conceal()
    let concealed = monitor.sampleCount
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(monitor.sampleCount, concealed)
  }
  @MainActor func testKeyboardFlowAndNoInvisibleLauncherActions() async throws {
    _ = NSApplication.shared
    let model = NativeUIModel()
    model.searchProvider = { query in
      LauncherSearch.apps(LauncherSearch.builtinApps, query: query).map {
        NativeUISearchRow(id: $0.id, kind: "app", title: $0.name)
      }
    }
    var commands: [String] = []
    model.action = { command in
      commands.append(command.name)
      if command.name == "launcher.openMac" { model.present(destination: "system-status") }
      if command.name == "launcher.show" { model.present(destination: "apps") }
      if command.name == "launcher.hide" { model.conceal() }
    }
    model.present(destination: "apps", searchQuery: "battery")
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 125, characters: "", modifiers: [])))
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 36, characters: "\r", modifiers: [])))
    for _ in 0..<100 where model.commandPending { await Task.yield() }
    XCTAssertEqual(model.destination, "system-status")
    for code: UInt16 in [36, 18, 125] {
      XCTAssertFalse(
        model.handleKeyboard(
          NativeKeyInput(code: code, characters: "", modifiers: code == 18 ? .command : [])))
    }
    XCTAssertFalse(
      model.handleKeyboard(NativeKeyInput(code: 51, characters: "", modifiers: [], composing: true))
    )
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 53, characters: "", modifiers: [], repeatKey: true))
    )
    XCTAssertTrue(model.visible)
    XCTAssertTrue(model.handleKeyboard(NativeKeyInput(code: 51, characters: "", modifiers: [])))
    for _ in 0..<100 where model.commandPending { await Task.yield() }
    XCTAssertEqual(model.destination, "apps")
    model.present(destination: "system-status")
    XCTAssertTrue(
      model.handleKeyboard(NativeKeyInput(code: 13, characters: "ц", modifiers: .command)))
    for _ in 0..<100 where model.commandPending { await Task.yield() }
    XCTAssertFalse(model.visible)
    XCTAssertEqual(commands, ["launcher.openMac", "launcher.show", "launcher.hide"])
  }
}
