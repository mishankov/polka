import AppKit
import Combine
import XCTest

@testable import PolkaApp

final class NativeSettingsUpdateTests: XCTestCase {
  @MainActor func testChannelPickerUsesGuardedActionAndPreservesDrafts() async {
    let model = NativeUIModel()
    model.settings.canChangeUpdateChannel = true
    model.draft = NativeSnippetDraft(name: "unsaved", content: "keep me")
    model.pairingCode = "unsaved pairing code"
    var commands: [NativeUICommand] = []
    model.action = { command in
      commands.append(command)
      model.settings.updateChannel =
        NativeUpdateChannel(rawValue: command.strings["value"] ?? "") ?? .stable
    }
    let picker = NativeUpdateChannelPopUp(frame: .zero, pullsDown: false)
    picker.addItems(withTitles: ["Stable", "Nightly"])
    picker.changeValue = { model.setUpdateChannel($0) }
    picker.selectItem(at: 1)
    picker.change()
    for _ in 0..<100 where model.commandPending { await Task.yield() }
    XCTAssertEqual(commands.first?.name, "updates.channel")
    XCTAssertEqual(model.settings.updateChannel, .nightly)
    XCTAssertEqual(model.draft?.content, "keep me")
    XCTAssertEqual(model.pairingCode, "unsaved pairing code")
    picker.isEnabled = false
    picker.change()
    model.settings.canChangeUpdateChannel = false
    model.setUpdateChannel(.stable)
    XCTAssertEqual(commands.count, 1)
  }
  @MainActor func testUpdateCheckShortcutRespectsDisabledStatesAndComposition() async {
    let model = NativeUIModel()
    model.settingsPane = "about"
    var commands: [String] = []
    model.action = { commands.append($0.name) }
    let key = NativeKeyInput(code: 15, characters: "к", modifiers: .command, isSettings: true)
    for status in ["unavailable", "checking", "downloading", "ready", "installing"] {
      model.settings.updateStatus = status
      XCTAssertTrue(model.handleKeyboard(key))
      XCTAssertFalse(model.commandPending)
    }
    model.settings.updateStatus = "idle"
    var composing = key
    composing.composing = true
    XCTAssertFalse(model.handleKeyboard(composing))
    var repeated = key
    repeated.repeatKey = true
    XCTAssertTrue(model.handleKeyboard(repeated))
    XCTAssertTrue(model.handleKeyboard(key))
    for _ in 0..<100 where model.commandPending { await Task.yield() }
    XCTAssertEqual(commands, ["updates.check"])
  }
  @MainActor func testImmediateSettingsWritesDoNotPublishBusyOrEmptyErrors() async {
    let model = NativeUIModel()
    var busyChanges: [Bool] = []
    var errorChanges: [String] = []
    let busy = model.$busy.dropFirst().sink { busyChanges.append($0) }
    let errors = model.$error.dropFirst().sink { errorChanges.append($0) }
    defer {
      busy.cancel()
      errors.cancel()
    }
    var commands: [String] = []
    model.action = { commands.append($0.name) }
    for name in [
      "builtinApps.setEnabled", "clipboardHistory.preferences", "mediaIndicator.setTracking",
      "system.login", "clipboardHistory.syncEnabled", "settings.set",
    ] {
      model.perform(NativeUICommand(name))
      XCTAssertTrue(model.commandPending)
      for _ in 0..<100 where model.commandPending { await Task.yield() }
      XCTAssertFalse(model.commandPending)
    }
    // Completed writes must not publish delayed feedback after the fact.
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(commands.count, 6)
    XCTAssertTrue(busyChanges.isEmpty)
    XCTAssertTrue(errorChanges.isEmpty)
  }

  @MainActor func testSlowWriteRemainsSerializedAndShowsBusyUntilCompletion() async {
    let model = NativeUIModel()
    let started = expectation(description: "Settings write started")
    let becameBusy = expectation(description: "Slow write publishes busy feedback")
    let busy = model.$busy.dropFirst().filter { $0 }.first().sink { _ in becameBusy.fulfill() }
    defer { busy.cancel() }
    var release: CheckedContinuation<Void, Never>?
    var count = 0
    model.action = { _ in
      count += 1
      await withCheckedContinuation {
        release = $0
        started.fulfill()
      }
    }
    model.setBuiltinApp("builtin:emoji", enabled: false)
    XCTAssertFalse(model.busy)
    // The grace period affects presentation only, never command serialization.
    model.setBuiltinApp("builtin:emoji", enabled: false)
    // Observe readiness instead of assuming both actor tasks have begun their
    // grace period before a fixed sleep expires on a loaded runner.
    await fulfillment(of: [started, becameBusy], timeout: 2)
    XCTAssertTrue(model.busy)
    XCTAssertFalse(model.canChangeBuiltinApps)
    model.setBuiltinApp("builtin:files", enabled: false)
    XCTAssertEqual(count, 1)
    let becameIdle = expectation(description: "Completed write clears busy feedback")
    let idle = model.$busy.dropFirst().filter { !$0 }.first().sink { _ in becameIdle.fulfill() }
    defer { idle.cancel() }
    release?.resume()
    await fulfillment(of: [becameIdle], timeout: 2)
    XCTAssertFalse(model.busy)
    XCTAssertFalse(model.commandPending)
    XCTAssertTrue(model.canChangeBuiltinApps)
  }

  @MainActor func testFailedSettingWriteShowsErrorAndPreservesEdits() async {
    let model = NativeUIModel()
    model.settingsPane = "builtin-apps"
    model.pairingCode = "unsaved code"
    model.draft = NativeSnippetDraft(name: "unsaved", content: "keep me")
    model.action = { _ in throw SettingsWriteFailure() }
    model.setBuiltinApp("builtin:snippets", enabled: false)
    for _ in 0..<100 where model.commandPending { await Task.yield() }
    XCTAssertFalse(model.commandPending)
    XCTAssertFalse(model.busy)
    XCTAssertFalse(model.error.isEmpty)
    XCTAssertTrue(model.settings.builtinApps.isEnabled("builtin:snippets"))
    XCTAssertEqual(model.settingsPane, "builtin-apps")
    XCTAssertEqual(model.pairingCode, "unsaved code")
    XCTAssertEqual(model.draft?.content, "keep me")
  }

  @MainActor func testOrdinaryCommandsStillShowBusyImmediately() async {
    let model = NativeUIModel()
    model.action = { _ in }
    model.perform(NativeUICommand("clipboardHistory.createSnippet"))
    XCTAssertTrue(model.busy)
    for _ in 0..<100 where model.commandPending { await Task.yield() }
    XCTAssertFalse(model.busy)
  }

  func testThemeReleasePreviewResolvesBothSwiftPMResourceLayoutsWithoutFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for layout in ["", "Contents/Resources"] {
      let directory = root.appendingPathComponent(layout.isEmpty ? "flat" : "structured")
      let bundle = directory.appendingPathComponent("PolkaNative_PolkaApp.bundle")
      let resources = layout.isEmpty ? bundle : bundle.appendingPathComponent(layout)
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      if !layout.isEmpty {
        let plist = try PropertyListSerialization.data(
          fromPropertyList: [
            "CFBundleIdentifier": "app.polka.fixture", "CFBundlePackageType": "BNDL",
          ],
          format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
      }
      let file = resources.appendingPathComponent("theme-release-preview.png")
      try Data("preview png".utf8).write(to: file)
      let resolved = try XCTUnwrap(
        NativeReleaseNotesView.themePreviewURL(in: directory) {
          XCTFail("Packaged preview must not fall back to Bundle.module for layout \(layout)")
          return Bundle.main
        })
      XCTAssertEqual(try Data(contentsOf: resolved), Data("preview png".utf8))
    }
  }
}

private struct SettingsWriteFailure: Error {}
