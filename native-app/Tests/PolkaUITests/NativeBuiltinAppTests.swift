import AppKit
import Combine
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeBuiltinAppTests: XCTestCase {
  @MainActor private func withPlatform(_ body: (NativePlatform, URL) async throws -> Void)
    async throws
  {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    try platform.history.initialize()
    platform.show = { [weak platform] destination, query in
      platform?.model.present(destination: destination ?? "apps", searchQuery: query)
    }
    platform.refresh()
    do { try await body(platform, root) } catch {
      await platform.shutdown()
      throw error
    }
    await platform.shutdown()
  }
  @MainActor private func set(_ platform: NativePlatform, _ destination: String, _ enabled: Bool)
    async throws
  {
    try await platform.handle(
      NativeUICommand(
        "builtinApps.setEnabled", strings: ["id": "builtin:" + destination],
        bools: ["enabled": enabled]))
  }
  @MainActor func testSearchAliasesContentAndShowAllFollowIndependentStates() async throws {
    try await withPlatform { platform, _ in
      for i in 0..<4 {
        try platform.history.add(
          .text, content: "needle history \(i)", preview: "needle history \(i)")
        _ = try platform.history.createSnippet(content: "needle snippet \(i)")
      }
      platform.refresh()
      platform.model.query = "needle"
      XCTAssertEqual(platform.model.searchResults.filter { $0.kind == "clip" }.count, 6)
      XCTAssertTrue(platform.model.searchResults.contains { $0.kind == "more-clips" })
      XCTAssertTrue(platform.model.searchResults.contains { $0.kind == "more-snippets" })
      try await set(platform, "clipboard", false)
      XCTAssertEqual(platform.model.searchResults.filter { $0.kind == "clip" }.count, 3)
      XCTAssertTrue(platform.model.searchResults.filter { $0.kind == "clip" }.allSatisfy(\.snippet))
      XCTAssertFalse(platform.model.searchResults.contains { $0.kind == "more-clips" })
      XCTAssertTrue(platform.model.searchResults.contains { $0.kind == "more-snippets" })
      for query in ["clipboard", "history", "буфер", "сниппеты"] {
        platform.model.query = query
        XCTAssertFalse(platform.model.searchResults.contains { $0.id == "builtin:clipboard" })
      }
      try await set(platform, "snippets", false)
      platform.model.query = "needle"
      XCTAssertTrue(platform.model.searchResults.isEmpty)
      try await set(platform, "clipboard", true)
      XCTAssertEqual(platform.model.searchResults.filter { $0.kind == "clip" }.count, 3)
      XCTAssertTrue(
        platform.model.searchResults.filter { $0.kind == "clip" }.allSatisfy { !$0.snippet })
      platform.model.query = "clipboard"
      XCTAssertTrue(platform.model.searchResults.contains { $0.id == "builtin:clipboard" })
    }
  }
  @MainActor func testDisabledEntryPointsAndSharedCopyServices() async throws {
    try await withPlatform { platform, _ in
      let snippet = try platform.history.createSnippet(content: "kept snippet")
      try platform.history.add(.text, content: "kept history", preview: "kept history")
      let clip = try XCTUnwrap(platform.history.snapshot().clips.first?.id)
      let commands =
        [
          NativeUICommand("clipboardHistory.show"), NativeUICommand("shelf.showSnippets"),
          NativeUICommand("shelf.showEmoji"), NativeUICommand("shelf.showFiles"),
          NativeUICommand("launcher.show", strings: ["destination": "toggle-clipboard"]),
          NativeUICommand("shelf.showSnippets", strings: ["sourceClipId": clip]),
          NativeUICommand("clipboardHistory.createSnippet", strings: ["content": "blocked"]),
          NativeUICommand("shelf.copyEmoji", strings: ["id": "grinning-face"]),
          NativeUICommand("shelf.files.add", ids: ["/synthetic/file"]),
          NativeUICommand("clipboardHistory.copy", strings: ["id": clip]),
          NativeUICommand("clipboardHistory.select", strings: ["id": snippet]),
        ]
        + LauncherSearch.builtinApps.flatMap { app in
          [
            NativeUICommand("launcher.openMac", strings: ["id": app.id]),
            NativeUICommand("launcher.show", strings: ["destination": String(app.id.dropFirst(8))]),
          ]
        }
      for app in LauncherSearch.builtinApps {
        try await set(platform, String(app.id.dropFirst(8)), false)
      }
      platform.model.present(destination: "apps")
      XCTAssertTrue(platform.model.apps.isEmpty)
      for command in commands {
        do {
          try await platform.handle(command)
          XCTFail("Allowed disabled action: \(command.name)")
        } catch { XCTAssertTrue(error.localizedDescription.contains("отключено")) }
      }
      XCTAssertEqual(platform.model.destination, "apps")
      platform.model.present(destination: "clipboard")
      XCTAssertEqual(platform.model.destination, "apps")
      var openedSettings = false
      platform.openSettings = { _ in openedSettings = true }
      try await platform.handle(NativeUICommand("shelf.settings"))
      XCTAssertTrue(openedSettings)
      try await platform.handle(
        NativeUICommand("shelf.copyCalculation", strings: ["expression": "1+2"]))
      XCTAssertEqual(platform.capture.syntheticText, "3")
      try await set(platform, "emoji", true)
      let emoji = try XCTUnwrap(
        EmojiCatalog.shared.results(query: "", category: "all", tone: "default").first)
      try await platform.handle(NativeUICommand("shelf.copyEmoji", strings: ["id": emoji.id]))
      XCTAssertEqual(platform.capture.syntheticText, emoji.value)
      try await set(platform, "snippets", true)
      try await platform.handle(NativeUICommand("clipboardHistory.copy", strings: ["id": snippet]))
      XCTAssertEqual(platform.capture.syntheticText, "kept snippet")
      XCTAssertFalse(platform.capture.enabled)
    }
  }
  @MainActor func testDisablePreservesDraftBrowseAndFilesBeyondResumeTimeout() async throws {
    try await withPlatform { platform, root in
      let model = platform.model
      let file = root.appendingPathComponent("synthetic.txt")
      try Data("fixture".utf8).write(to: file)
      try platform.files.add([file.path])
      platform.refresh()
      for destination in ["snippets", "clipboard", "emoji", "files"] {
        model.present(destination: destination)
        model.query = "saved query"
        model.selectedID = "selection"
        model.listScrollOffset = 123
        model.previewScrollOffset = 45
        model.emojiCategory = "Symbols"
        model.emojiTone = "all"
        model.selectedFiles = Set(model.files.map(\.id))
        if destination == "snippets" {
          model.draft = NativeSnippetDraft(name: "unsaved", content: "preserved")
        }
        try await set(platform, destination, false)
        XCTAssertEqual(model.destination, "apps")
        try await set(platform, destination, true)
        model.present(destination: destination, now: Date().addingTimeInterval(3600))
        XCTAssertEqual(model.query, "saved query")
        XCTAssertEqual(model.selectedID, "selection")
        XCTAssertEqual(model.listScrollOffset, 123)
        XCTAssertEqual(model.previewScrollOffset, 45)
        XCTAssertEqual(model.emojiCategory, "Symbols")
        XCTAssertEqual(model.emojiTone, "all")
        XCTAssertEqual(model.selectedFiles, Set(model.files.map(\.id)))
        if destination == "snippets" { XCTAssertEqual(model.draft?.content, "preserved") }
      }
      XCTAssertEqual(platform.files.items.count, 1)
      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
  }
  @MainActor func testCapturePreferenceShortcutAndDataSurviveDisableAndRestart() async throws {
    try await withPlatform { platform, root in
      try await platform.handle(
        NativeUICommand(
          "clipboardHistory.shortcut", strings: ["accelerator": "CommandOrControl+Alt+V"]))
      for paused in [false, true] {
        try await platform.handle(
          NativeUICommand("clipboardHistory.preferences", bools: ["paused": paused]))
        let before = platform.history.snapshot().clips.count
        try await set(platform, "clipboard", false)
        try platform.capture.capture(
          snapshot: NativeClipboardSnapshot(
            changeCount: paused ? 2 : 1,
            items: [
              NativeClipboardItem(types: ["public.utf8-plain-text"], text: "must not capture")
            ]))
        XCTAssertEqual(platform.history.snapshot().clips.count, before)
        XCTAssertEqual(platform.history.getPreferences().paused, paused)
        XCTAssertEqual(platform.history.getPreferences().accelerator, "CommandOrControl+Alt+V")
        XCTAssertFalse(platform.clipboardRegistered)
        try await set(platform, "clipboard", true)
        XCTAssertTrue(platform.clipboardRegistered)
        XCTAssertEqual(platform.history.getPreferences().paused, paused)
      }
      try await platform.handle(
        NativeUICommand("clipboardHistory.preferences", bools: ["paused": false]))
      try platform.capture.capture(
        snapshot: NativeClipboardSnapshot(
          changeCount: 3,
          items: [
            NativeClipboardItem(types: ["public.utf8-plain-text"], text: "captured after enabling")
          ]))
      let kept = try XCTUnwrap(platform.history.snapshot().clips.first?.id)
      try await set(platform, "clipboard", false)
      try await set(platform, "files", false)
      platform.history.flush()
      let restarted = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
      try restarted.history.initialize()
      restarted.refresh()
      XCTAssertFalse(restarted.capture.enabled)
      XCTAssertFalse(restarted.builtinApps.allows(destination: "clipboard"))
      XCTAssertFalse(restarted.builtinApps.allows(destination: "files"))
      XCTAssertTrue(restarted.builtinApps.allows(destination: "snippets"))
      XCTAssertEqual(restarted.history.find(kept)?.content, "captured after enabling")
      XCTAssertEqual(restarted.history.getPreferences().accelerator, "CommandOrControl+Alt+V")
      await restarted.shutdown()
    }
  }
  @MainActor func testInactiveShortcutDoesNotReserveBindingAndConflictsAreReportedOnReenable()
    async throws
  {
    try await withPlatform { platform, _ in
      try await set(platform, "clipboard", false)
      let original = platform.history.getPreferences().accelerator
      try await platform.handle(
        NativeUICommand("launcher.setShortcut", strings: ["accelerator": original]))
      try await set(platform, "clipboard", true)
      XCTAssertTrue(platform.builtinApps.allows(destination: "clipboard"))
      XCTAssertFalse(platform.clipboardRegistered)
      XCTAssertFalse(platform.model.settings.clipboardShortcutError.isEmpty)
      XCTAssertEqual(platform.history.getPreferences().accelerator, original)
      try await platform.handle(
        NativeUICommand(
          "clipboardHistory.shortcut", strings: ["accelerator": "CommandOrControl+Alt+V"]))
      XCTAssertTrue(platform.clipboardRegistered)
      XCTAssertTrue(platform.model.settings.clipboardShortcutError.isEmpty)
    }
  }
  @MainActor func testTrayActionsValidateEachAppAndRespectBusyState() {
    _ = NSApplication.shared
    let application = NativeApplication()
    for (selector, destination) in [
      ("historyAction", "clipboard"), ("snippetsAction", "snippets"), ("filesAction", "files"),
    ] {
      let item = NSMenuItem(title: destination, action: Selector(selector), keyEquivalent: "")
      XCTAssertTrue(application.validateMenuItem(item))
      application.model.settings.builtinApps.overrides["builtin:" + destination] = false
      XCTAssertFalse(application.validateMenuItem(item))
      application.model.settings.builtinApps.overrides["builtin:" + destination] = true
      application.model.busy = true
      XCTAssertFalse(application.validateMenuItem(item))
      application.model.busy = false
      XCTAssertTrue(application.validateMenuItem(item))
    }
  }
  @MainActor func testSyncAndRetentionSettingsRemainIndependent() async throws {
    try await withPlatform { platform, _ in
      try await platform.sync.initialize()
      try await platform.handle(
        NativeUICommand("clipboardHistory.syncEnabled", bools: ["enabled": true]))
      try await platform.handle(
        NativeUICommand("clipboardHistory.preferences", ints: ["retentionDays": 30]))
      let syncStatus = platform.sync.state().status
      for app in LauncherSearch.builtinApps {
        try await set(platform, String(app.id.dropFirst(8)), false)
      }
      XCTAssertTrue(platform.sync.state().enabled)
      XCTAssertEqual(platform.sync.state().status, syncStatus)
      XCTAssertEqual(platform.history.getPreferences().retentionDays, 30)
      try await platform.handle(
        NativeUICommand("clipboardHistory.preferences", bools: ["paused": true]))
      XCTAssertTrue(platform.history.getPreferences().paused)
      XCTAssertEqual(platform.sync.state().status, "paused")
      for app in LauncherSearch.builtinApps {
        try await set(platform, String(app.id.dropFirst(8)), true)
      }
      XCTAssertTrue(platform.sync.state().enabled)
      XCTAssertEqual(platform.sync.state().status, "paused")
      XCTAssertEqual(platform.history.getPreferences().retentionDays, 30)
    }
  }
  @MainActor func testFailedPersistenceLeavesAppAndDraftIntact() async throws {
    try await withPlatform { platform, _ in
      platform.model.present(destination: "snippets")
      platform.model.draft = NativeSnippetDraft(content: "saved locally")
      platform.settings.close()
      do {
        try await set(platform, "snippets", false)
        XCTFail("Persisting to closed store succeeded")
      } catch {}
      XCTAssertTrue(platform.builtinApps.allows(destination: "snippets"))
      XCTAssertEqual(platform.model.destination, "snippets")
      XCTAssertEqual(platform.model.draft?.content, "saved locally")
    }
  }
  @MainActor func testSettingsActionsPersistAndReportWriteFailuresWithoutBusyFlashes() async throws
  {
    try await withPlatform { platform, root in
      let model = platform.model
      var busyChanges: [Bool] = []
      let observation = model.$busy.dropFirst().sink { busyChanges.append($0) }
      defer { observation.cancel() }
      model.setBuiltinApp("builtin:emoji", enabled: false)
      for _ in 0..<100 where model.commandPending { await Task.yield() }
      XCTAssertFalse(model.commandPending)
      XCTAssertFalse(model.settings.builtinApps.isEnabled("builtin:emoji"))
      let persisted = try SettingsStore(root: root)
      defer { persisted.close() }
      let overrides = try persisted.get(key: BuiltinAppAvailability.settingsKey) as? [String: Bool]
      XCTAssertEqual(overrides?["builtin:emoji"], false)

      model.draft = NativeSnippetDraft(content: "keep this draft")
      platform.settings.close()
      model.setBuiltinApp("builtin:snippets", enabled: false)
      for _ in 0..<100 where model.commandPending { await Task.yield() }
      XCTAssertFalse(model.commandPending)
      XCTAssertFalse(model.error.isEmpty)
      XCTAssertTrue(model.settings.builtinApps.isEnabled("builtin:snippets"))
      XCTAssertEqual(model.draft?.content, "keep this draft")
      XCTAssertTrue(busyChanges.isEmpty)
    }
  }
  @MainActor func testBusyDropAndDialogPreventChangesAndPreserveDraft() async throws {
    try await withPlatform { platform, _ in
      let model = platform.model
      model.present(destination: "snippets")
      model.draft = NativeSnippetDraft(content: "do not lose")
      for kind in ["busy", "drop", "outgoing", "dialog"] {
        model.busy = kind == "busy"
        model.incomingFileDropPending = kind == "drop"
        model.outgoingFileDrag = kind == "outgoing"
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        let sheet = NSWindow()
        sheet.isReleasedWhenClosed = false
        if kind == "dialog" { window.beginSheet(sheet, completionHandler: nil) }
        XCTAssertFalse(model.canChangeBuiltinApps)
        do {
          try await set(platform, "snippets", false)
          XCTFail("Disabled during \(kind)")
        } catch { XCTAssertTrue(platform.builtinApps.allows(destination: "snippets")) }
        XCTAssertEqual(model.draft?.content, "do not lose")
        if kind == "dialog" { window.endSheet(sheet) }
        window.close()
        sheet.close()
      }
      model.busy = false
      model.incomingFileDropPending = false
      XCTAssertTrue(model.canChangeBuiltinApps)
    }
  }
}
