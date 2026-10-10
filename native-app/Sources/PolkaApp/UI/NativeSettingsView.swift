import AppKit
import PolkaCore
import SwiftUI

var nativeSettingsPanes: [(id: String, label: String, icon: String)] {
  [
    ("general", localized("General"), "slider.horizontal.3"),
    ("shelf", localized("Shelf and Shortcuts"), "command"),
    ("clipboard", localized("Clipboard"), "clipboard"),
    ("builtin-apps", localized("Built-in Apps"), "square.grid.2x2"),
    ("about", localized("About"), "info.circle"),
  ]
}

struct NativeSettingsView: View {
  @ObservedObject var model: NativeUIModel
  private var pane: (id: String, label: String, icon: String) {
    nativeSettingsPanes.first { $0.id == model.settingsPane } ?? nativeSettingsPanes[0]
  }
  private var subtitle: String {
    switch model.settingsPane {
    case "builtin-apps": localized("Choose the apps you need on the shelf.")
    case "shelf": localized("Opening the shelf, quick commands, and device activity indicators.")
    case "clipboard": localized("Recording, pasting, and history on other Macs.")
    case "about": localized("App version and updates.")
    default: localized("Language, app startup, and background operation.")
    }
  }
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text(localized("Polka")).font(.system(size: 18, weight: .semibold))
          Text(localized("Settings")).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 22)
        NativeSettingsSidebar(model: model).frame(height: CGFloat(nativeSettingsPanes.count * 40))
          .padding(.horizontal, 10)
        Spacer(minLength: 20)
        Divider().padding(.horizontal, 16)
        Button {
          model.navigate("apps")
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(localized("Open Shelf")).font(.system(size: 12, weight: .medium))
              if !model.settings.launcherShortcut.isEmpty {
                Text(nativeShortcutLabel(model.settings.launcherShortcut)).font(.system(size: 11))
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.secondary)
          }.contentShape(Rectangle()).padding(18)
        }.buttonStyle(.plain).disabled(model.busy).help(
          nativeShortcutLabel(model.settings.launcherShortcut))
      }.frame(width: 210)
        .background {
          NativeSettingsSidebarMaterial().ignoresSafeArea(.container, edges: .top)
        }
      // Keep the content-column separator continuous under the title bar.
      Divider().ignoresSafeArea(.container, edges: .top)
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 7) {
          Text(pane.label).font(.system(size: 23, weight: .semibold))
          Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 22)
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            NativeErrorNotice(text: model.error)
            switch model.settingsPane {
            case "shelf": shelf
            case "clipboard": clipboard
            case "about": about
            case "builtin-apps": builtinApps
            default: general
            }
          }.frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.bottom, 28)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }.background(Color(nsColor: .windowBackgroundColor))
      .background(NativeKeyboardBridge(model: model, settings: true).frame(width: 0, height: 0))
      .onChange(of: model.settingsPane) { _, pane in model.settingsPaneChanged?(pane) }
      .accessibilityIdentifier("native-settings")
  }
  private var builtinApps: some View {
    VStack(alignment: .leading, spacing: 20) {
      NativeSettingsGroup(localized("Apps on the Shelf")) {
        ForEach(LauncherSearch.builtinApps) { app in
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text(app.name).font(.system(size: 13))
              note(app.description)
            }.frame(maxWidth: .infinity, alignment: .leading)
            NativeBuiltinAppToggle(
              model: model, appID: app.id, title: app.name,
              enabled: model.settings.builtinApps.isEnabled(app.id)
            ).controlSize(.small)
          }
          if app.id != LauncherSearch.builtinApps.last?.id { Divider() }
        }
      }
      note(
        localized(
          "Changes apply immediately. Data, settings, and drafts are preserved; the shelf and settings are always available."
        )
      )
      note(
        localized(
          "When history is disabled, new copies are not saved and image recognition stops. When enabled again, the previous recording setting applies. Sync and retention continue according to their settings in “Clipboard”."
        )
      )
      note(
        localized(
          "Disabling snippets or emoji hides their commands; shared copy and paste services remain available to other apps. Disabling files removes the drop target at the top edge; file links are kept until you quit Polka."
        )
      )
    }
  }
  private var general: some View {
    VStack(alignment: .leading, spacing: 20) {
      NativeUpdateNotice(model: model)
      NativeSettingsGroup(localized("App Language")) {
        HStack {
          Text(localized("Language")).font(.system(size: 13))
          Spacer()
          NativeLanguagePicker(model: model).frame(width: 180)
        }
        note(
          localized(
            "“System” follows the macOS language. English is used for unsupported languages."))
        note(localized("Changes apply immediately."))
      }
      NativeSettingsGroup(localized("Startup and Background Operation")) {
        settingToggle(
          localized("Launch at Login"),
          detail: localized("In the background, without opening the shelf."),
          value: model.settings.login, enabled: !model.busy
        ) {
          model.perform(NativeUICommand("system.login", bools: ["enabled": $0]))
        }
      }
      note(
        localized(
          "After closing its windows, Polka continues recording history and responding to shortcuts. To quit, choose “Quit Polka” in the menu bar or press ⌘Q."
        )
      )
    }
  }
  private var shelf: some View {
    VStack(alignment: .leading, spacing: 20) {
      NativeSettingsGroup(localized("Opening the Shelf")) {
        settingToggle(
          localized("Open on Hover"),
          detail:
            localized(
              "Move the pointer to the camera notch or the center of the top screen edge. Search receives focus immediately."
            ),
          value: model.settings.hoverEnabled, enabled: model.writable && !model.busy
        ) { model.preference("hoverEnabled", $0) }
        if !model.writable {
          note(
            localized("Restore access to storage and restart Polka to change this setting."))
        }
      }
      NativeSettingsGroup(localized("Launcher Shortcut")) {
        shortcutRow(
          localized("Open Shelf"), value: model.settings.launcherShortcut, disabled: model.busy
        ) {
          model.perform(NativeUICommand("launcher.setShortcut", strings: ["accelerator": $0]))
        }
        NativeErrorNotice(text: model.settings.launcherShortcutError)
        HStack {
          NativeCommandButton(
            title: localized("Open Shelf"),
            shortcut: nativeShortcutLabel(model.settings.launcherShortcut),
            disabled: model.busy
          ) { model.navigate("apps") }
          Spacer(minLength: 8)
          NativeCommandButton(
            title: localized("Disable Shortcut"),
            disabled: model.busy || model.settings.launcherShortcut.isEmpty
          ) { model.perform(NativeUICommand("launcher.setShortcut", strings: ["accelerator": ""])) }
        }
      }
      NativeSettingsGroup(localized("Activity Indicators")) {
        settingToggle(
          localized("Camera"), value: model.settings.cameraEnabled, enabled: !model.busy
        ) {
          model.perform(
            NativeUICommand(
              "mediaIndicator.setTracking", strings: ["device": "camera"], bools: ["enabled": $0]))
        }
        Divider()
        settingToggle(
          localized("Microphone"), value: model.settings.microphoneEnabled, enabled: !model.busy
        ) {
          model.perform(
            NativeUICommand(
              "mediaIndicator.setTracking", strings: ["device": "microphone"],
              bools: ["enabled": $0]))
        }
        if !model.settings.mediaActivity.isEmpty { note(model.settings.mediaActivity) }
      }
      note(
        localized(
          "Indicators appear by the camera notch or at the center of the top edge. They may be visible during screen sharing; turn both off to hide them."
        )
      )
    }
  }
  private var clipboard: some View {
    VStack(alignment: .leading, spacing: 20) {
      NativeStorageNotice(model: model)
      NativeErrorNotice(text: model.helperError)
      if model.helperStatus == "starting" { note(localized("Starting clipboard monitor…")) }
      if !model.settings.builtinApps.allows(destination: "clipboard") {
        note(
          localized(
            "History is disabled in “Built-in Apps”. New copies are not saved and its shortcut is inactive. Settings below are preserved for re-enabling; sync and retention continue to apply."
          )
        )
      }
      NativeSettingsGroup(localized("History Recording")) {
        settingToggle(
          localized("Save Text and Images"),
          detail:
            localized(
              "Up to 200 items and 128 MB, encrypted locally. Confidential and temporary data is skipped if marked by its app."
            ),
          value: !model.settings.paused, enabled: model.writable && !model.busy
        ) { model.preference("paused", !$0) }
        Divider()
        HStack(spacing: 12) {
          Text(localized("Keep Unpinned Items")).font(.system(size: 13))
          Spacer(minLength: 8)
          Picker(
            localized("Keep Unpinned Items"),
            selection: Binding(
              get: { model.settings.retentionDays },
              set: {
                model.perform(
                  NativeUICommand("clipboardHistory.preferences", ints: ["retentionDays": $0]))
              })
          ) {
            Text(localized("1 day")).tag(1)
            Text(localized("7 days")).tag(7)
            Text(localized("30 days")).tag(30)
          }.labelsHidden().frame(width: 112).disabled(!model.writable || model.busy)
        }
        note(localized("Pinned items are kept beyond the selected retention period."))
      }
      NativeSettingsGroup(localized("Selecting an Item")) {
        settingToggle(
          localized("Paste into the Previous Field"),
          detail: model.settings.pasteOnSelect
            ? localized("Enter pastes the selected item. ⇧Enter only copies it.")
            : localized("The selected item is only copied. Paste it manually with ⌘V."),
          value: model.settings.pasteOnSelect, enabled: model.writable && !model.busy
        ) { model.preference("pasteOnSelect", $0) }
        if model.settings.pasteOnSelect {
          Divider()
          if model.pasteAccess == "granted" {
            note(localized("Accessibility access is allowed."))
          } else {
            note(
              model.pasteAccess == "required"
                ? localized(
                  "To paste, allow Accessibility access in macOS settings. For now, copy and paste manually with ⌘V."
                )
                : localized(
                  "Could not check macOS permission. For now, copy and paste manually with ⌘V.")
            )
            if model.pasteAccess == "required" {
              NativeCommandButton(
                title: localized("Allow Automatic Paste…"), disabled: !model.writable || model.busy
              ) { model.perform(NativeUICommand("clipboardHistory.requestPasteAccess")) }
            }
          }
        }
      }
      NativeSettingsGroup(localized("History Shortcut")) {
        NativeErrorNotice(text: model.settings.clipboardShortcutError)
        shortcutRow(
          localized("Open History"), value: model.settings.clipboardShortcut,
          disabled: !model.writable || model.busy
        ) {
          model.perform(NativeUICommand("clipboardHistory.shortcut", strings: ["accelerator": $0]))
        }
        HStack {
          NativeCommandButton(
            title: localized("Open History"),
            shortcut: nativeShortcutLabel(model.settings.clipboardShortcut),
            disabled: model.busy || !model.settings.builtinApps.allows(destination: "clipboard")
          ) { model.perform(NativeUICommand("clipboardHistory.show")) }
          Spacer(minLength: 8)
          NativeCommandButton(
            title: localized("Disable Shortcut"),
            disabled: !model.writable || model.busy || model.settings.clipboardShortcut.isEmpty
          ) {
            model.perform(
              NativeUICommand("clipboardHistory.shortcut", strings: ["accelerator": ""]))
          }
        }
      }
      sync
    }
  }
  private var sync: some View {
    NativeSettingsGroup(localized("History on Other Macs")) {
      settingToggle(
        localized("Sync over the Local Network"),
        detail:
          localized(
            "Text, images, pinned status, and deletions transfer directly between linked Macs. The current clipboard is unchanged."
          ),
        value: model.settings.syncEnabled, enabled: syncAvailable && !model.busy
      ) { model.perform(NativeUICommand("clipboardHistory.syncEnabled", bools: ["enabled": $0])) }
      if model.settings.syncStatus == "starting" { note(localized("Loading sync settings…")) }
      if model.settings.syncStatus == "blocked" {
        NativeErrorNotice(text: localized("Sync has stopped: history storage is unavailable."))
      }
      NativeStorageNotice(model: model, store: "sync")
      NativeErrorNotice(text: model.settings.syncError)
      if model.settings.syncEnabled, syncAvailable {
        Divider()
        note(
          localized(
            "This Mac: {0}. On first connection and after a break, all saved history is merged. Retention is set separately on each Mac.",
            String(describing: model.settings.deviceName))
        )
        if model.settings.paused {
          note(
            localized("History recording is paused. Sync will resume when you enable recording."))
        }
        ForEach(model.settings.peers) { peer in
          HStack {
            Button {
              model.selectedPeerID = peer.id
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(peer.name).font(.system(size: 13))
                Text(
                  model.settings.paused
                    ? localized("Paused")
                    : peer.status == "syncing"
                      ? localized("Syncing…")
                      : peer.status == "connected"
                        ? localized("History Synced") : localized("Not Connected")
                ).font(.system(size: 11)).foregroundStyle(.secondary)
                if peer.lastSync > 0 {
                  Text(nativeClipDate(peer.lastSync)).font(.system(size: 10)).foregroundStyle(
                    .secondary)
                }
                if !peer.error.isEmpty {
                  Text(peer.error).font(.system(size: 11)).foregroundStyle(.red)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(5).background(
                model.selectedPeerID == peer.id ? Color.accentColor.opacity(0.1) : .clear,
                in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain)
            NativeCommandButton(title: localized("Unlink"), shortcut: "⌘⌥⌫", disabled: model.busy) {
              model.selectedPeerID = peer.id
              model.perform(
                NativeUICommand("clipboardHistory.syncForget", strings: ["id": peer.id]))
            }
          }
        }
        if !model.settings.peers.isEmpty {
          NativeCommandButton(
            title: localized("Sync Now"), disabled: model.busy || model.settings.paused
          ) { model.perform(NativeUICommand("clipboardHistory.syncNow")) }
        }
        if !model.settings.invitation.isEmpty {
          Text(localized("Code for Another Mac")).font(.system(size: 12, weight: .medium))
          Text(model.settings.invitation).font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
          note(
            localized(
              "Enable sync on the other Mac and paste this code. It is valid for 5 minutes and links one device. Share it only with your own Mac."
            )
          )
          HStack {
            NativeCommandButton(title: localized("Copy Code"), disabled: model.busy) {
              model.perform(NativeUICommand("clipboardHistory.copyPairingCode"))
            }
            NativeCommandButton(title: localized("Cancel Code"), disabled: model.busy) {
              model.perform(NativeUICommand("clipboardHistory.syncCancelInvite"))
            }
          }
        } else {
          NativeCommandButton(
            title: localized("Get Code for Another Mac"), shortcut: "⌘⇧N", disabled: model.busy
          ) { model.perform(NativeUICommand("clipboardHistory.syncInvite")) }
        }
        Text(localized("Code from Another Mac")).font(.system(size: 12, weight: .medium))
        TextEditor(text: $model.pairingCode).font(.system(size: 11, design: .monospaced)).frame(
          height: 75
        ).padding(4).background(
          Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)
        ).disabled(model.busy).accessibilityIdentifier("sync-pairing-code")
        NativeCommandButton(
          title: localized("Link Mac and Merge History"), shortcut: "⌘↵",
          disabled: model.busy
            || model.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          prominent: true
        ) { model.pairMac() }
        note(
          model.settings.nearby.isEmpty
            ? localized(
              "No other Macs found yet. Enable sync on the second Mac and check that both are on the same network."
            )
            : localized("Other Macs on the network: ")
              + model.settings.nearby.joined(separator: ", "))
      }
    }
  }
  private var syncAvailable: Bool {
    model.settings.syncStorageStatus == "ready"
      && !["blocked", "starting"].contains(model.settings.syncStatus)
  }
  private var about: some View {
    VStack(alignment: .leading, spacing: 20) {
      NativeSettingsGroup(localized("Polka")) {
        note(localized("Apps and clipboard history — on one shelf."))
        NativeUpdatesView(model: model)
      }
      note(localized("History is stored locally with encryption."))
    }
  }
  private func note(_ text: String) -> some View {
    Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
      horizontal: false, vertical: true)
  }
  private func settingToggle(
    _ title: String, detail: String = "", value: Bool, enabled: Bool,
    action: @escaping (Bool) -> Void
  ) -> some View {
    Toggle(isOn: Binding(get: { value }, set: action)) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 13))
        if !detail.isEmpty { note(detail) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.toggleStyle(.switch).controlSize(.small).disabled(!enabled)
  }
  private func shortcutRow(
    _ title: String, value: String, disabled: Bool, action: @escaping (String) -> Void
  ) -> some View {
    HStack(spacing: 12) {
      Text(title).font(.system(size: 13))
      Spacer(minLength: 8)
      NativeShortcutRecorder(value: value, disabled: disabled, onRecord: action).frame(
        width: 210, height: 30)
    }
  }
}

struct NativeSettingsGroup<Content: View>: View {
  var title: String
  @ViewBuilder var content: Content
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(
        .leading, 2)
      VStack(alignment: .leading, spacing: 12) { content }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Color(nsColor: .controlBackgroundColor).opacity(0.45),
          in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10).strokeBorder(
            Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
    }
  }
}

struct NativeUpdatesView: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(localized("Updates")).font(.system(size: 17, weight: .semibold))
      Text(
        model.settings.currentVersion.isEmpty
          ? localized("Loading version…")
          : localized("Polka {0}", String(describing: model.settings.currentVersion))
      ).font(.system(size: 12)).foregroundStyle(.secondary)
      if !model.settings.updateMessage.isEmpty {
        Text(model.settings.updateMessage).font(.system(size: 12)).foregroundStyle(
          model.settings.updateStatus == "error" ? .red : .secondary
        ).textSelection(.enabled)
      }
      if model.settings.updateStatus != "unavailable" {
        Text(
          localized(
            "Updates are checked and downloaded automatically. Installation requires confirmation.")
        )
        .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if model.settings.updateStatus == "current" {
        Text(localized("The latest version is installed.")).font(.system(size: 13))
      }
      if !model.settings.updateVersion.isEmpty {
        Text(
          model.settings.updateStatus == "ready"
            ? localized("Version {0} Is Ready to Install", model.settings.updateVersion)
            : localized("Version {0} Is Available", model.settings.updateVersion)
        ).font(.system(size: 13))
      }
      if model.settings.updateNotification == "skipped" {
        Text(localized("You skipped this version. You can install it here.")).font(
          .system(size: 12)
        )
        .foregroundStyle(.secondary)
      }
      if model.settings.updateNotification == "deferred" {
        Text(
          localized(
            "We will remind you {0}. You can update now.",
            String(describing: nativeClipDate(model.settings.updateRemindAfter)))
        ).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if model.settings.updateStatus == "downloading" {
        ProgressView(value: model.settings.updateProgress, total: 100)
        Text(localized("Downloaded {0}%", String(describing: Int(model.settings.updateProgress))))
          .font(
            .system(size: 11)
          )
          .foregroundStyle(.secondary)
      }
      if model.settings.updateStatus == "ready" {
        Text(localized("The app will restart to install the update.")).font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      if ["idle", "current", "error", "checking"].contains(model.settings.updateStatus) {
        NativeCommandButton(
          title: model.settings.updateStatus == "checking"
            ? localized("Checking…") : localized("Check for Updates"),
          shortcut: "⌘R", disabled: model.busy || model.settings.updateStatus == "checking"
        ) { model.perform(NativeUICommand("updates.check")) }
      }
      if ["ready", "installing"].contains(model.settings.updateStatus) {
        NativeCommandButton(
          title: localized("Install and Restart"), shortcut: "⌘⇧U",
          disabled: model.busy || model.settings.updateStatus == "installing", prominent: true
        ) { model.installUpdate() }
      }
      if !model.settings.updateVersion.isEmpty {
        Divider()
        NativeReleaseNotesView(settings: model.settings).id(model.settings.updateVersion)
      }
    }.accessibilityIdentifier("native-updates")
  }
}

struct NativeUpdateNotice: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    let displayedVersion = model.settings.updateVersion
    if !displayedVersion.isEmpty, model.settings.updateNotification == "visible",
      ["checking", "downloading", "ready", "installing", "error"].contains(
        model.settings.updateStatus)
    {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(
            localized("Polka {0} Is Available", String(describing: model.settings.updateVersion))
          ).font(
            .system(size: 13, weight: .semibold))
          Spacer()
          Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        HStack(spacing: 5) {
          NativeCommandButton(
            title: model.settings.updateStatus == "error"
              ? localized("Check Again") : localized("Update and Restart"),
            shortcut: model.settings.updateStatus == "error" ? "⌘R" : "⌘⇧U",
            disabled: model.busy
              || ["checking", "downloading", "installing"].contains(model.settings.updateStatus),
            prominent: true
          ) {
            if model.settings.updateStatus == "error" {
              model.perform(NativeUICommand("updates.check"))
            } else {
              model.installUpdate()
            }
          }
          NativeCommandButton(
            title: localized("Tomorrow"),
            disabled: model.busy || model.settings.updateStatus == "installing"
          ) {
            model.perform(NativeUICommand("updates.remind", strings: ["version": displayedVersion]))
          }
          NativeCommandButton(
            title: localized("Skip"),
            disabled: model.busy || model.settings.updateStatus == "installing"
          ) {
            model.perform(NativeUICommand("updates.skip", strings: ["version": displayedVersion]))
          }
          NativeCommandButton(title: localized("What's New"), disabled: model.busy) {
            model.perform(NativeUICommand("shelf.settings", strings: ["section": "about"]))
          }
        }
      }.padding(10).background(
        Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
  }
  private var status: String {
    switch model.settings.updateStatus {
    case "installing": return localized("Installing…")
    case "checking": return localized("Checking…")
    case "downloading":
      return localized("Downloading… {0}%", String(describing: Int(model.settings.updateProgress)))
    case "ready": return localized("Ready to Install")
    default: return localized("Update Error")
    }
  }
}

/// An integrated window sidebar uses the semantic system material rather than
/// an inset glass card. AppKit supplies wallpaper blending and accessibility.
private struct NativeSettingsSidebarMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    view.setAccessibilityElement(false)
    return view
  }
  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A native source list owns Up/Down/Home/End and VoiceOver selection. Keeping
/// the sidebar in AppKit avoids requiring pointer input to change settings tabs.
struct NativeSettingsSidebar: NSViewRepresentable {
  @ObservedObject var model: NativeUIModel
  func makeCoordinator() -> Coordinator { Coordinator(model) }
  func makeNSView(context: Context) -> NSTableView {
    // All panes fit in the fixed sidebar. A scroll view with hidden scrollers
    // still responds to wheel/trackpad input and can move panes out of view.
    let table = NSTableView()
    table.headerView = nil
    table.backgroundColor = .clear
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
    column.width = 190
    table.addTableColumn(column)
    table.delegate = context.coordinator
    table.dataSource = context.coordinator
    table.rowHeight = 38
    // Source-list styling installs an opaque material behind the entire
    // table. Plain rows keep the sidebar continuous with its surroundings.
    table.style = .plain
    table.allowsEmptySelection = false
    table.focusRingType = .none
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.setAccessibilityLabel(localized("Settings sections"))
    context.coordinator.table = table
    return table
  }
  func updateNSView(_ table: NSTableView, context: Context) {
    context.coordinator.model = model
    if context.coordinator.language != model.settings.language {
      context.coordinator.language = model.settings.language
      table.setAccessibilityLabel(localized("Settings sections"))
      for row in nativeSettingsPanes.indices {
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
        {
          cell.textField?.stringValue = nativeSettingsPanes[row].label
          cell.setAccessibilityLabel(nativeSettingsPanes[row].label)
        }
      }
    }
    let index = nativeSettingsPanes.firstIndex { $0.id == model.settingsPane } ?? 0
    if context.coordinator.table?.selectedRow != index {
      context.coordinator.table?.selectRowIndexes(
        IndexSet(integer: index), byExtendingSelection: false)
    }
    // Selection notifications style the changed rows. Unrelated model updates
    // must not rewrite every label's font/color and invalidate the whole sidebar.
  }
  @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var model: NativeUIModel
    weak var table: NSTableView?
    var language = AppLocalization.language
    init(_ model: NativeUIModel) { self.model = model }
    func numberOfRows(in tableView: NSTableView) -> Int { nativeSettingsPanes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      let pane = nativeSettingsPanes[row]
      let cell = NSTableCellView()
      let text = NSTextField(labelWithString: pane.label)
      text.font = .systemFont(ofSize: 13)
      text.lineBreakMode = .byWordWrapping
      text.maximumNumberOfLines = 2
      let icon = NSImageView()
      icon.image = NSImage(systemSymbolName: pane.icon, accessibilityDescription: nil)
      icon.contentTintColor = .secondaryLabelColor
      cell.textField = text
      cell.imageView = icon
      cell.addSubview(icon)
      cell.addSubview(text)
      icon.translatesAutoresizingMaskIntoConstraints = false
      text.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 18),
        icon.heightAnchor.constraint(equalToConstant: 18),
        text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
        text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
        text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      cell.setAccessibilityIdentifier("settings-tab-" + pane.id)
      cell.setAccessibilityLabel(pane.label)
      style(cell, selected: pane.id == model.settingsPane)
      return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      NativeSettingsSidebarRow()
    }
    private func style(_ cell: NSTableCellView, selected: Bool) {
      cell.textField?.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
      cell.textField?.textColor = selected ? .selectedControlTextColor : .labelColor
      cell.imageView?.contentTintColor = selected ? .selectedControlTextColor : .secondaryLabelColor
    }
    func synchronizeCells() {
      guard let table else { return }
      for row in nativeSettingsPanes.indices {
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
        {
          style(cell, selected: row == table.selectedRow)
        }
      }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
      guard let table, nativeSettingsPanes.indices.contains(table.selectedRow) else { return }
      let pane = nativeSettingsPanes[table.selectedRow].id
      if model.settingsPane != pane { model.settingsPane = pane }
      synchronizeCells()
    }
  }
}

final class NativeSettingsSidebarRow: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 7, yRadius: 7)
    let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    (isEmphasized
      ? NSColor.selectedContentBackgroundColor
      : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
    path.fill()
    if contrast {
      NSColor.controlAccentColor.setStroke()
      path.lineWidth = 1
      path.stroke()
    }
  }
}

struct NativeReleaseNotesView: View {
  var settings: NativeUISettings
  @State private var language: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(localized("What's New")).font(.system(size: 15, weight: .semibold))
        Spacer()
        Picker(
          localized("Release notes language"),
          selection: Binding(
            get: { language ?? settings.language.rawValue }, set: { language = $0 }
          )
        ) {
          Text("Русский").tag("ru")
          Text("English").tag("en")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 180).accessibilityLabel(
          localized("Release notes language"))
      }
      // Release notes are plain text, including any HTML-like characters.
      Text(nativeReleaseNoteText(settings, language: language ?? settings.language.rawValue)).font(
        .system(size: 13)
      )
      .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
func nativeReleaseNoteText(_ settings: NativeUISettings, language: String) -> String {
  let direct = language == "ru" ? settings.updateNotesRussian : settings.updateNotesEnglish
  if !direct.isEmpty { return direct }
  let split = settings.updateNotes.components(separatedBy: "\n\nEnglish\n\n")
  if split.count == 2 { return split[language == "ru" ? 0 : 1] }
  if language == "ru", !settings.updateNotes.isEmpty { return settings.updateNotes }
  return language == "ru"
    ? AppLocalization.text(
      "Release notes have not been published for this version.", language: .russian)
    : "Release notes have not been published for this version."
}

/// A native switch participates in the window's Tab chain and VoiceOver.
/// Space is a focused-control key, so it never competes with global shortcuts.
struct NativeBuiltinAppToggle: NSViewRepresentable {
  @ObservedObject var model: NativeUIModel
  var appID: String
  var title: String
  var enabled: Bool
  func makeNSView(context: Context) -> NativeBuiltinAppSwitch {
    let control = NativeBuiltinAppSwitch()
    control.target = control
    control.action = #selector(NativeBuiltinAppSwitch.change)
    control.controlSize = .small
    control.sizeToFit()
    return control
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeBuiltinAppSwitch, context: Context)
    -> CGSize?
  {
    nsView.intrinsicContentSize
  }
  func updateNSView(_ button: NativeBuiltinAppSwitch, context: Context) {
    if button.controlSize != .small { button.controlSize = .small }
    if button.accessibilityLabel() != title { button.setAccessibilityLabel(title) }
    let state: NSControl.StateValue = enabled ? .on : .off
    if button.state != state { button.state = state }
    button.setAvailable(model.canChangeBuiltinApps, focusRevision: model.settingsFocusRevision)
    let identifier = "builtin-app-toggle-" + appID
    if button.accessibilityIdentifier() != identifier {
      button.setAccessibilityIdentifier(identifier)
    }
    button.focusRevision = { model.settingsFocusRevision }
    button.changeValue = { value in model.setBuiltinApp(appID, enabled: value) }
  }
}
final class NativeBuiltinAppSwitch: NSSwitch {
  var changeValue: ((Bool) -> Void)?
  var focusRevision: (() -> Int)?
  private weak var restoreWindow: NSWindow?
  private var disabledFocusRevision = 0
  override var acceptsFirstResponder: Bool { isEnabled }
  override var canBecomeKeyView: Bool {
    // NSSwitch normally requires Full Keyboard Access. These settings must
    // remain reachable through the standard Tab flow with that option off.
    acceptsFirstResponder && !isHiddenOrHasHiddenAncestor && window?.canBecomeKey == true
  }
  func setAvailable(_ available: Bool, focusRevision: Int) {
    let owner = window
    if available != isEnabled {
      isEnabled = available
      if available { owner?.recalculateKeyViewLoop() }
    }
    if available, let owner = restoreWindow {
      // SwiftUI may move focus before updating a busy AppKit control.
      // Restore the focus captured by its action, unless the user moved it.
      if owner.isKeyWindow, window === owner, focusRevision == disabledFocusRevision {
        owner.makeFirstResponder(self)
      }
      restoreWindow = nil
    }
  }
  @objc func change() {
    guard isEnabled, NSApp?.modalWindow == nil,
      NSApp?.windows.contains(where: { $0.attachedSheet != nil }) != true
    else { return }
    if window?.firstResponder === self {
      restoreWindow = window
      disabledFocusRevision = focusRevision?() ?? 0
    }
    changeValue?(state == .on)
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 49,
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    {
      if !event.isARepeat { performClick(nil) }
      return
    }
    super.keyDown(with: event)
  }
}

/// A focused native pop-up uses Space and arrow keys. It participates in Tab
/// navigation even when Full Keyboard Access is off and keeps focus on translation.
struct NativeLanguagePicker: NSViewRepresentable {
  @ObservedObject var model: NativeUIModel
  func makeNSView(context: Context) -> NativeLanguagePopUp {
    let control = NativeLanguagePopUp(frame: .zero, pullsDown: false)
    control.target = control
    control.action = #selector(NativeLanguagePopUp.change)
    control.setAccessibilityIdentifier("settings-language")
    return control
  }
  func updateNSView(_ control: NativeLanguagePopUp, context: Context) {
    let labels = [localized("System"), "English", "Русский"]
    if control.itemTitles != labels {
      if control.numberOfItems != labels.count {
        control.removeAllItems()
        control.addItems(withTitles: labels)
      } else {
        for (index, title) in labels.enumerated() { control.item(at: index)?.title = title }
      }
    }
    control.selectItem(
      at: AppLanguagePreference.allCases.firstIndex(of: model.settings.languagePreference) ?? 0)
    control.setAccessibilityLabel(localized("Language"))
    control.isEnabled = !model.busy && !model.commandPending
    control.changeValue = { model.setLanguage($0) }
  }
}
final class NativeLanguagePopUp: NSPopUpButton {
  var changeValue: ((AppLanguagePreference) -> Void)?
  override var acceptsFirstResponder: Bool { isEnabled }
  override var canBecomeKeyView: Bool {
    acceptsFirstResponder && !isHiddenOrHasHiddenAncestor && window?.canBecomeKey == true
  }
  @objc func change() {
    guard isEnabled, AppLanguagePreference.allCases.indices.contains(indexOfSelectedItem),
      NSApp?.modalWindow == nil, window?.attachedSheet == nil
    else { return }
    changeValue?(AppLanguagePreference.allCases[indexOfSelectedItem])
  }
  override func keyDown(with event: NSEvent) {
    if event.isARepeat { return }
    super.keyDown(with: event)
  }
}
