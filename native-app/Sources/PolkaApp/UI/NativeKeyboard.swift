import AppKit
import SwiftUI

struct NativeKeyInput {
  var code: UInt16
  var characters: String
  var modifiers: NSEvent.ModifierFlags
  var repeatKey = false
  var composing = false
  var editing = false
  var searchEditing = false
  var isSettings = false
}

extension NativeUIModel {
  /// All command buttons and keyboard commands call the same guarded model
  /// actions. Physical key codes keep bindings usable with non-Latin layouts.
  @discardableResult func handleKeyboard(_ key: NativeKeyInput) -> Bool {
    if key.composing { return false }
    let flags = key.modifiers.intersection([.command, .option, .control, .shift])
    let command = flags.contains(.command)
    let shift = flags.contains(.shift)
    let plain = flags.isEmpty
    let enter = key.code == 36 || key.code == 76
    let delete = key.code == 51 || key.code == 117
    let escape = key.code == 53
    let cmd = flags == .command
    // Native menus, attached sheets, and shortcut recording own keyboard input.
    let known =
      escape || (enter && (!key.editing || key.searchEditing || command || previewID != nil))
      || (command && (delete || [45, 1, 14, 35, 0, 43, 15, 32].contains(key.code)))
      || (command && nativeNumber(key) != nil)
    if busy { return known }
    if key.repeatKey, known { return true }
    if cmd, key.code == 43 {
      perform(NativeUICommand("shelf.settings"))
      return true
    }
    if key.isSettings {
      if cmd, key.code == 15, settingsPane == "about" {
        perform(NativeUICommand("updates.check"))
        return true
      }
      if flags == [.command, .shift], key.code == 32, settings.updateStatus == "ready",
        settingsPane == "about"
          || (settingsPane == "general" && settings.updateNotification == "visible")
      {
        installUpdate()
        return true
      }
      if cmd, key.code == 15, settingsPane == "general", settings.updateStatus == "error",
        settings.updateNotification == "visible"
      {
        perform(NativeUICommand("updates.check"))
        return true
      }
      if settingsPane == "clipboard", settings.syncEnabled {
        if enter, cmd, !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          pairMac()
          return true
        }
        if flags == [.command, .shift], key.code == 45 {
          perform(NativeUICommand("clipboardHistory.syncInvite"))
          return true
        }
        if flags == [.command, .option], delete, let id = selectedPeerID {
          perform(NativeUICommand("clipboardHistory.syncForget", strings: ["id": id]))
          return true
        }
      }
      return false
    }
    if draft != nil {
      if enter, cmd {
        saveSnippet()
        return true
      }
      if escape {
        back()
        return true
      }
      return false
    }
    if destination == "apps", query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      settings.updateNotification == "visible"
    {
      if flags == [.command, .shift], key.code == 32, settings.updateStatus == "ready" {
        installUpdate()
        return true
      }
      if cmd, key.code == 15, settings.updateStatus == "error" {
        perform(NativeUICommand("updates.check"))
        return true
      }
    }
    if confirmClear {
      if escape || (delete && plain) {
        back()
        return true
      }
      if enter, cmd {
        clearHistory()
        return true
      }
      return false
    }
    if escape {
      if previewID != nil { back() } else { perform(NativeUICommand("launcher.hide")) }
      return true
    }
    if destination == "files" {
      if cmd, key.code == 0 {
        selectedFiles = Set(files.map(\.id))
        return true
      }
      if delete, command, !flags.contains(.option), !flags.contains(.control) {
        removeSelectedFiles(clear: shift)
        return true
      }
      if key.code == 117, plain {
        removeSelectedFiles()
        return true
      }
      if delete, plain {
        back()
        return true
      }
      return false
    }
    if delete, plain, !key.editing || (key.searchEditing && query.isEmpty) {
      back()
      return true
    }
    if ["clipboard", "snippets"].contains(destination) {
      if cmd, key.code == 1, let clip = preview ?? selectedClip, clip.kind == "image" {
        secondaryClipAction(clip)
        return true
      }
      if cmd, key.code == 15, preview?.kind == "image", previewImage == nil {
        reloadPreviewImage()
        return true
      }
      if cmd, key.code == 45 {
        if destination == "snippets" {
          createSnippet()
        } else if let clip = preview ?? selectedClip {
          edit(clip)
        }
        return true
      }
      if cmd, key.code == 14 {
        if let clip = preview ?? selectedClip { edit(clip) }
        return true
      }
      if delete, command, !flags.contains(.option), !flags.contains(.control) {
        if key.searchEditing, !query.isEmpty, !shift { return false }
        if shift, destination == "clipboard" {
          showClearConfirmation()
        } else if let clip = preview ?? selectedClip {
          removeClip(clip)
        }
        return true
      }
      if cmd, key.code == 35, destination == "clipboard", let clip = preview ?? selectedClip,
        writable
      {
        perform(
          NativeUICommand(
            "clipboardHistory.pin", strings: ["id": clip.id], bools: ["pinned": !clip.pinned]))
        return true
      }
      if let number = nativeNumber(key) {
        if let preview {
          if flags == .command {
            let actions = previewActions(for: preview)
            if number < actions.count { actions[number].run() }
            return true
          }
        } else if number < clipResults.count {
          let clip = clipResults[number]
          if flags == [.command, .option] {
            secondaryClipAction(clip)
            return true
          }
          if flags == .command {
            chooseClip(clip)
            return true
          }
        }
      }
      if enter, !flags.contains(.option), !flags.contains(.control),
        let clip = preview ?? selectedClip
      {
        if cmd, preview == nil {
          openPreview(clip)
        } else if flags == .shift || plain {
          chooseClip(clip, copyOnly: shift)
        } else {
          return false
        }
        return true
      }
    } else if destination == "emoji" {
      if let index = nativeNumber(key), flags == .command {
        if index < emojiResults.count { chooseEmoji(emojiResults[index]) }
        return true
      }
      if enter, plain || flags == .shift {
        if let selectedEmoji { chooseEmoji(selectedEmoji, copyOnly: shift) }
        return true
      }
    } else {
      if let index = nativeNumber(key), flags == .command {
        if index < searchResults.count { activateSearch(searchResults[index]) }
        return true
      }
      if enter, plain || flags == .shift {
        if let selectedSearch { activateSearch(selectedSearch, copyOnly: shift) }
        return true
      }
    }
    // Search fields retain left/right caret movement. Arrow navigation of the
    // result list is intentional; text editors otherwise own their keys.
    if plain, [123, 124, 125, 126, 115, 119].contains(key.code), !key.editing || key.searchEditing {
      if previewID != nil { return false }
      if destination == "emoji" {
        if key.searchEditing, [123, 124].contains(key.code) { return false }
        let results = emojiResults
        guard !results.isEmpty else { return true }
        let current = results.firstIndex { $0.id == selectedID } ?? 0
        let step = key.code == 123 ? -1 : key.code == 124 ? 1 : key.code == 126 ? -10 : 10
        let next =
          key.code == 115
          ? 0 : key.code == 119 ? results.count - 1 : min(results.count - 1, max(0, current + step))
        selectedID = results[next].id
        scrollID = selectedID
        return true
      }
      if [125, 126].contains(key.code) {
        let ids =
          ["clipboard", "snippets"].contains(destination)
          ? clipResults.map(\.id) : searchResults.map(\.id)
        guard !ids.isEmpty else { return true }
        let current = ids.firstIndex(of: selectedID ?? "") ?? 0
        let next =
          destination == "apps"
          ? (current + (key.code == 125 ? 1 : -1) + ids.count) % ids.count
          : min(ids.count - 1, max(0, current + (key.code == 125 ? 1 : -1)))
        selectedID = ids[next]
        scrollID = selectedID
        return true
      }
    }
    return false
  }
  func pairMac() {
    let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty, !busy, settings.syncStorageStatus == "ready" else { return }
    perform(NativeUICommand("clipboardHistory.syncPair", strings: ["code": code])) { [weak self] in
      self?.pairingCode = ""
    }
  }
  func showClearConfirmation() {
    guard writable, !busy, !clips.isEmpty else { return }
    previewID = nil
    confirmClear = true
  }
  func clearHistory() {
    guard writable, confirmClear, !busy else { return }
    perform(NativeUICommand("clipboardHistory.clear")) { [weak self] in self?.confirmClear = false }
  }
  func secondaryClipAction(_ clip: NativeUIClip) {
    guard visible, !busy, draft == nil, !confirmClear else { return }
    if clip.kind == "image" {
      perform(NativeUICommand("clipboardHistory.saveImage", strings: ["id": clip.id]))
    } else if nativeWebURL(clip.content) != nil {
      perform(NativeUICommand("clipboardHistory.openUrl", strings: ["id": clip.id]))
    }
  }
}

func nativeNumber(_ key: NativeKeyInput) -> Int? {
  let physical: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
  if let number = physical[key.code] { return number }
  guard let value = Int(key.characters), (1...9).contains(value) else { return nil }
  return value - 1
}

/// The invisible adapter observes only its own key window. It never installs a
/// global monitor and therefore cannot steal keys from another application.
struct NativeKeyboardBridge: NSViewRepresentable {
  var model: NativeUIModel
  var settings = false
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.view = view
    context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak coordinator = context.coordinator] event in
      guard let coordinator, let view = coordinator.view, let window = view.window,
        window.isKeyWindow, event.window === window, window.attachedSheet == nil,
        NSApp.modalWindow == nil
      else { return event }
      if NSMenuTrackingState.shared.active { return event }
      let text = window.firstResponder as? NSTextView
      // A shortcut recorder is an NSControl, never the field editor.
      if window.firstResponder is NativeShortcutCaptureView { return event }
      if window.firstResponder is NativeEmojiCategoryButton,
        [123, 124, 115, 119].contains(event.keyCode),
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty
      {
        return event
      }
      let editing = text != nil
      let identifier = text?.delegate as? NSTextField
      let searchEditing = identifier?.identifier?.rawValue == "polka-search"
      let key = NativeKeyInput(
        code: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
        modifiers: event.modifierFlags, repeatKey: event.isARepeat,
        composing: text?.hasMarkedText() ?? false, editing: editing, searchEditing: searchEditing,
        isSettings: coordinator.settings)
      return coordinator.model.handleKeyboard(key) ? nil : event
    }
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.model = model
    context.coordinator.settings = settings
  }
  func makeCoordinator() -> Coordinator { Coordinator(model: model, settings: settings) }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
  }
  @MainActor final class Coordinator {
    var model: NativeUIModel
    var settings: Bool
    weak var view: NSView?
    var monitor: Any?
    init(model: NativeUIModel, settings: Bool) {
      self.model = model
      self.settings = settings
    }
  }
}
@MainActor final class NSMenuTrackingState {
  static let shared = NSMenuTrackingState()
  var active = false
  private var observers: [NSObjectProtocol] = []
  private init() {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
      ) { _ in MainActor.assumeIsolated { self.active = true } })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
      ) { _ in MainActor.assumeIsolated { self.active = false } })
  }
}
