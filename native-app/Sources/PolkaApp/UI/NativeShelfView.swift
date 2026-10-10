import AppKit
import PolkaCore
import SwiftUI

struct NativeShelfView: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    VStack(spacing: 0) {
      if model.topInset > 0 { Color.clear.frame(height: model.topInset) }
      switch model.destination {
      case "clipboard", "snippets": NativeClipboardView(model: model)
      case "emoji": NativeEmojiView(model: model)
      case "files": NativeFileShelfView(model: model)
      default: NativeLauncherView(model: model)
      }
    }
    // Keep the shelf and its controls in the established dark appearance.
    .environment(\.colorScheme, .dark)
    .background(NativeKeyboardBridge(model: model).frame(width: 0, height: 0))
    .background(Color.black)
    .onChange(of: model.query) { _, _ in
      model.selectedID = nil
      model.notice = ""
      model.searchRevision += 1
    }
    .modifier(NativeFileDropModifier(model: model))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("native-shelf")
  }
}

struct NativeLauncherView: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    let results = model.searchResults
    let selectedID = results.first(where: { $0.id == model.selectedID })?.id ?? results.first?.id
    return VStack(spacing: 0) {
      HStack(spacing: 10) {
        NativeSearchField(
          text: $model.query, placeholder: localized("Find or calculate…"),
          focusToken: "apps-\(model.visible)-\(model.sessionRevision)"
        ).frame(maxWidth: .infinity).frame(height: 44)
        NativeIconButton(
          label: localized("Settings"), symbol: "gearshape", shortcut: "⌘,", disabled: model.busy
        ) { model.perform(NativeUICommand("shelf.settings")) }
      }.padding(14)
      Divider()
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              NativeUpdateNotice(model: model).padding(.horizontal, 10)
              if !model.settings.introduced { welcome.padding(10) }
            }
            NativeErrorNotice(text: model.error.isEmpty ? model.catalogError : model.error).padding(
              .horizontal, 10)
            if !model.error.isEmpty || !model.catalogError.isEmpty {
              NativeCommandButton(title: localized("Refresh List"), disabled: model.busy) {
                model.perform(NativeUICommand("launcher.refresh"))
              }.padding(.horizontal, 12)
            }
            if let status = model.calculationStatus, !status.isEmpty {
              Text(status).foregroundStyle(.secondary).padding(12)
            }
            if !model.notice.isEmpty {
              Text(model.notice).font(.system(size: 12)).foregroundStyle(.secondary).padding(
                .horizontal, 12
              ).accessibilityIdentifier("native-action-notice")
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { position, result in
              if position == 0 || group(result) != group(results[position - 1]) {
                Text(group(result)).font(.system(size: 11, weight: .semibold)).foregroundStyle(
                  .secondary
                ).padding(.horizontal, 14).padding(.top, 10)
              }
              Button {
                model.activateSearch(result)
              } label: {
                HStack(spacing: 10) {
                  resultIcon(result)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(result.title).font(
                      .system(
                        size: result.kind == "calculation" ? 24 : 14,
                        weight: result.kind == "calculation" ? .medium : .regular)
                    ).lineLimit(2)
                    if !result.detail.isEmpty {
                      Text(result.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                  }
                  Spacer(minLength: 0)
                  if position < 9 {
                    Text("⌘\(position + 1)").font(.system(size: 11)).foregroundStyle(.tertiary)
                  }
                }.padding(.horizontal, 12).padding(.vertical, 10).frame(
                  maxWidth: .infinity, alignment: .leading
                )
                .background(
                  selectedID == result.id ? Color.accentColor.opacity(0.13) : .clear,
                  in: RoundedRectangle(cornerRadius: 7))
              }.buttonStyle(.plain).disabled(model.busy).padding(.horizontal, 6)
                .id(result.id).accessibilityIdentifier("result-\(result.id)")
                .accessibilityLabel(result.title).accessibilityHint(
                  position < 9
                    ? localized("Open: ⌘{0}", String(describing: position + 1))
                    : localized("Open: Enter")
                )
                .onHover { if $0, model.selectedID != result.id { model.selectedID = result.id } }
            }
            if results.isEmpty {
              if model.storageStatus == "starting" || model.catalogLoading {
                ProgressView().frame(maxWidth: .infinity).padding(24)
              } else {
                Text(
                  model.query.isEmpty
                    ? localized("The app list is empty. Try refreshing it.")
                    : localized("Nothing found. Try another word.")
                ).foregroundStyle(.secondary).font(.system(size: 13)).padding(24)
              }
            }
          }.padding(.bottom, 10).background(
            NativeScrollPositionBridge(
              offset: $model.listScrollOffset, token: "apps-list-\(model.visible)"))
        }
        .onChange(of: model.scrollID) { _, id in if let id { reader.scrollTo(id, anchor: .center) }
        }
      }
      Divider()
      HStack {
        Text(
          model.busy
            ? localized("Working…")
            : model.catalogLoading
              ? localized("Searching…")
              : localized("Results · {0}", String(describing: results.count)))
        Spacer()
        Text(localized("↑ ↓ select   ↵ open   esc close"))
      }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
    }
  }
  private var welcome: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(localized("It All Starts with the Shelf")).font(.system(size: 14, weight: .semibold))
      Text(
        localized(
          "Open apps and find copied items. Return here using the menu bar icon, hovering over the camera notch, or {0}.",
          String(describing: nativeShortcutLabel(model.settings.launcherShortcut)))
      ).font(.system(size: 12)).foregroundStyle(.secondary)
      HStack {
        NativeCommandButton(title: localized("Got It"), disabled: model.busy) {
          model.perform(
            NativeUICommand(
              "settings.set", strings: ["key": "shelfIntroduced"], bools: ["value": true]))
        }
        NativeCommandButton(title: localized("Set Up Shelf"), shortcut: "⌘,", disabled: model.busy)
        {
          model.perform(NativeUICommand("shelf.settings"))
        }
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
      Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
  }
  private func group(_ result: NativeUISearchRow) -> String {
    result.kind == "calculation"
      ? localized("Calculator")
      : result.kind == "clip" || result.kind == "more-clips" || result.kind == "more-snippets"
        ? (result.snippet || result.kind == "more-snippets"
          ? localized("Snippets") : localized("Clipboard"))
        : localized("Apps")
  }
  @ViewBuilder private func resultIcon(_ result: NativeUISearchRow) -> some View {
    if let image = nativeImage(result.icon) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 34, height: 34)
    } else {
      Image(
        systemName: result.kind == "calculation"
          ? "equal"
          : result.kind == "clip"
            ? "clipboard"
            : result.id == "builtin:emoji"
              ? "face.smiling"
              : result.id == "builtin:snippets"
                ? "text.bubble" : result.id == "builtin:files" ? "folder" : "app"
      ).font(.system(size: 23)).foregroundStyle(.secondary).frame(width: 34, height: 34)
    }
  }
}

struct NativeClipboardView: View {
  @ObservedObject var model: NativeUIModel
  @FocusState private var editorNameFocused: Bool
  private var isSnippets: Bool { model.destination == "snippets" }
  var body: some View {
    VStack(spacing: 0) {
      NativeBuiltinHeader(
        model: model,
        title: model.draft.map {
          $0.id.isEmpty ? localized("Create Snippet") : localized("Edit Snippet")
        }
          ?? (isSnippets ? localized("Snippets") : localized("Clipboard"))
      ) {
        if model.settings.paused, !isSnippets {
          Text(localized("Recording Paused")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if isSnippets, model.draft == nil, model.previewID == nil {
          NativeCommandButton(
            title: localized("Create"), symbol: "plus", shortcut: "⌘N",
            disabled: !model.writable || model.busy, prominent: true
          ) { model.createSnippet() }.accessibilityIdentifier("snippet-create")
        }
        if !isSnippets, model.draft == nil, !model.confirmClear {
          Menu {
            Button(localized("Clear History on All Linked Macs… · ⌘⇧⌫")) {
              model.showClearConfirmation()
            }.disabled(!model.writable || model.clips.isEmpty || model.busy)
          } label: {
            Image(systemName: "ellipsis").frame(width: 20, height: 20)
          }.menuStyle(.button).menuIndicator(.hidden).buttonStyle(.glass).buttonBorderShape(.circle)
            .controlSize(.regular).disabled(model.busy)
            .help(localized("History actions")).accessibilityLabel(localized("History actions"))
        }
      }
      if model.draft == nil, model.previewID == nil, !model.confirmClear {
        NativeBuiltinSearch(
          model: model,
          placeholder: isSnippets
            ? localized("Find text or a name…") : localized("Find text, including text in images…"))
      }
      Divider()
      NativePasteAccessHint(model: model)
      NativeStorageNotice(model: model).padding(.horizontal, 10)
      NativeErrorNotice(text: model.error.isEmpty ? model.helperError : model.error).padding(
        .horizontal, 10)
      if !model.notice.isEmpty {
        Text(model.notice).font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
      }
      if model.draft != nil {
        editor
      } else if model.confirmClear {
        confirmation
      } else if let preview = model.preview {
        NativeClipboardPreview(model: model, clip: preview)
      } else {
        clipList
      }
      Divider()
      if model.draft != nil {
        NativeToolbar {
          Spacer(minLength: 0)
          NativeCommandButton(title: localized("Cancel"), shortcut: "esc", disabled: model.busy) {
            model.back()
          }
          NativeCommandButton(
            title: localized("Save"), shortcut: "⌘↵",
            disabled: model.busy || !model.writable || model.draft?.content.isEmpty != false,
            prominent: true
          ) { model.saveSnippet() }.accessibilityIdentifier("snippet-save")
        }
        NativeKeyboardHint(text: localized("⌘↵ save   esc cancel"))
      } else if model.confirmClear {
        NativeToolbar {
          Spacer(minLength: 0)
          NativeCommandButton(title: localized("Cancel"), shortcut: "esc", disabled: model.busy) {
            model.back()
          }
          NativeCommandButton(
            title: localized("Delete on All Linked Macs"), shortcut: "⌘↵",
            disabled: model.busy || !model.writable, destructive: true
          ) { model.clearHistory() }
        }
        NativeKeyboardHint(text: localized("⌫ / esc back to list"))
      } else {
        NativeToolbar {
          if model.previewID == nil {
            NativeCommandButton(
              title: localized("Preview"), symbol: "eye", shortcut: "⌘↵",
              disabled: model.selectedClip == nil || model.busy
            ) { if let clip = model.selectedClip { model.openPreview(clip) } }
            .accessibilityIdentifier("builtin-preview")
          }
          Spacer(minLength: 0)
          NativeSelectionActions(
            canPaste: model.canPaste,
            disabled: (model.preview ?? model.selectedClip) == nil || model.busy
          ) { copyOnly in
            if let clip = model.preview ?? model.selectedClip {
              model.chooseClip(clip, copyOnly: copyOnly)
            }
          }
        }
        NativeKeyboardHint(
          text: model.previewID != nil
            ? localized("⌫ / esc back to list")
            : localized(
              "↑ ↓ select   ↵ {0}   esc close",
              String(describing: model.canPaste ? localized("Paste") : localized("Copy"))))
      }
    }.accessibilityElement(children: .contain).accessibilityIdentifier(
      isSnippets ? "native-snippets" : "native-clipboard")
  }
  private var editor: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(localized("Name (optional)")).font(.system(size: 12))
      TextField(
        "",
        text: Binding(
          get: { model.draft?.name ?? "" },
          set: { model.draft?.name = nativeLimitedText($0, utf16Limit: 120) })
      ).textFieldStyle(.roundedBorder).focused($editorNameFocused).disabled(model.busy)
        .accessibilityIdentifier("snippet-name")
      Text(localized("Text")).font(.system(size: 12))
      TextEditor(
        text: Binding(get: { model.draft?.content ?? "" }, set: { model.draft?.content = $0 })
      ).font(.system(size: 14)).padding(4).background(
        Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)
      ).disabled(model.busy).accessibilityIdentifier("snippet-content")
      Text(
        model.draft?.id.isEmpty == false
          ? localized("Different snippets can have the same text.")
          : localized("The snippet will be saved separately from clipboard history.")
      ).font(.system(size: 11)).foregroundStyle(.secondary)
    }.padding(12).onAppear { editorNameFocused = true }
  }
  private var confirmation: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(localized("Delete History on All Linked Macs?")).font(
        .system(size: 18, weight: .semibold))
      Text(
        localized(
          "Pinned items will also be deleted. Deletion will be synced to linked Macs, including when they reconnect. Snippets and the current clipboard will be preserved."
        )
      ).font(.system(size: 13)).foregroundStyle(.secondary)
      Spacer()
    }.padding(12).accessibilityIdentifier("clear-history-confirmation")
  }
  private var clipList: some View {
    ScrollViewReader { reader in
      ScrollView {
        LazyVStack(spacing: 2) {
          if model.storageStatus == "starting" {
            ProgressView().padding(24)
          } else if model.clipResults.isEmpty {
            VStack(spacing: 10) {
              Image(systemName: isSnippets ? "text.bubble" : "clipboard").font(.system(size: 34))
                .foregroundStyle(.secondary)
              Text(
                model.storageStatus == "failed"
                  ? localized("History Unavailable")
                  : !model.query.isEmpty
                    ? localized("Nothing Found")
                    : isSnippets
                      ? localized("Save Ready-to-Use Text") : localized("Copied Items Appear Here")
              ).font(.system(size: 15, weight: .semibold))
              Text(
                model.storageStatus == "failed"
                  ? localized("Restore access to storage and restart Polka.")
                  : !model.query.isEmpty
                    ? localized("Try another word.")
                    : isSnippets
                      ? localized("Create a snippet for an address, details, or a standard reply.")
                      : model.settings.paused
                        ? localized("Enable clipboard recording in app settings.")
                        : localized("Copy text or an image in any app.")
              ).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(32)
          }
          ForEach(Array(model.clipResults.enumerated()), id: \.element.id) { position, clip in
            HStack(spacing: 8) {
              Button {
                model.selectedID = clip.id
                model.chooseClip(clip)
              } label: {
                HStack(spacing: 10) {
                  if clip.kind == "image", let image = nativeImage(clip.preview) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 38, height: 38)
                      .clipped().cornerRadius(4)
                  } else if clip.kind == "text", let color = ClipboardColor.parse(clip.content) {
                    NativeColorSwatch(color: color).frame(width: 38, height: 38)
                  } else {
                    Image(systemName: clip.kind == "image" ? "photo" : "textformat").font(
                      .system(size: 23)
                    ).foregroundStyle(.secondary).frame(width: 38, height: 38)
                  }
                  VStack(alignment: .leading, spacing: 3) {
                    Text(
                      clip.kind == "image"
                        ? (!model.query.isEmpty
                          ? nativeClipboardSnippet(clip, query: model.query) : localized("Image"))
                        : clip.name.isEmpty
                          ? (clip.preview.isEmpty ? clip.content : clip.preview) : clip.name
                    ).font(.system(size: 13)).lineLimit(2)
                    if !clip.name.isEmpty {
                      Text(clip.preview).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                      if clip.pinned, !isSnippets { Image(systemName: "pin.fill") }
                      Text(
                        nativeClipDate(clip.createdAt)
                          + (clip.sourceDevice.isEmpty ? "" : " · " + clip.sourceDevice))
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("clip-\(clip.id)")
                .accessibilityHint(
                  position < 9
                    ? localized("Select: ⌘{0}", String(describing: position + 1))
                    : localized("Select: Enter"))
              if model.selectedClip?.id == clip.id {
                if clip.kind == "text" {
                  NativeIconButton(
                    label: clip.snippet ? localized("Edit Snippet") : localized("Create Snippet"),
                    symbol: "pencil",
                    shortcut: "⌘E",
                    disabled: !model.writable || model.busy
                      || !model.settings.builtinApps.allows(destination: "snippets")
                  ) { model.edit(clip) }
                }
                if clip.kind == "image" || nativeWebURL(clip.content) != nil {
                  NativeIconButton(
                    label: clip.kind == "image"
                      ? localized("Save Image…") : localized("Open Link in Browser"),
                    symbol: clip.kind == "image" ? "arrow.down.to.line" : "arrow.up.right",
                    shortcut: clip.kind == "image"
                      ? "⌘S" + (position < 9 ? " / ⌘⌥\(position + 1)" : "")
                      : (position < 9 ? "⌘⌥\(position + 1)" : ""), disabled: model.busy
                  ) { model.secondaryClipAction(clip) }
                }
                NativeIconButton(
                  label: localized("Preview Item"), symbol: "eye", shortcut: "⌘↵",
                  disabled: model.busy
                ) { model.openPreview(clip) }
                if !isSnippets {
                  NativeIconButton(
                    label: clip.pinned ? localized("Unpin") : localized("Pin"),
                    symbol: clip.pinned ? "pin.slash" : "pin", shortcut: "⌘P",
                    disabled: !model.writable || model.busy
                  ) {
                    model.perform(
                      NativeUICommand(
                        "clipboardHistory.pin", strings: ["id": clip.id],
                        bools: ["pinned": !clip.pinned]))
                  }
                }
                NativeIconButton(
                  label: localized("Delete Item"), symbol: "trash", shortcut: "⌘⌫",
                  disabled: !model.writable || model.busy
                ) { model.removeClip(clip) }
              }
              if position < 9 {
                Text("⌘\(position + 1)").font(.system(size: 10)).foregroundStyle(.tertiary)
              }
            }.padding(10).background(
              model.selectedClip?.id == clip.id ? Color.accentColor.opacity(0.12) : .clear,
              in: RoundedRectangle(cornerRadius: 7)
            ).padding(.horizontal, 5).id(clip.id).onHover { if $0 { model.selectedID = clip.id } }
          }
        }.padding(.vertical, 8).background(
          NativeScrollPositionBridge(
            offset: $model.listScrollOffset,
            token: model.destination + "-list-" + String(model.visible)))
      }.onChange(of: model.scrollID) { _, id in if let id { reader.scrollTo(id, anchor: .center) } }
    }
  }
}

struct NativePasteAccessHint: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    if model.helperStatus == "starting" {
      VStack(alignment: .leading, spacing: 4) {
        Text(localized("Starting clipboard monitoring…"))
        if model.settings.pasteOnSelect {
          Text(
            model.destination == "emoji"
              ? localized("The emoji is only copied for now — paste it with ⌘V.")
              : localized("The item is only copied for now — paste it with ⌘V."))
        }
      }.font(.system(size: 11)).foregroundStyle(.secondary).frame(
        maxWidth: .infinity, alignment: .leading
      ).padding(10)
    } else if model.settings.pasteOnSelect, model.pasteAccess != "granted" {
      HStack(alignment: .top) {
        Text(
          model.pasteAccess == "required"
            ? localized(
              "Automatic paste requires Accessibility access. Until it is allowed, use ⌘V.")
            : localized("Automatic paste is unavailable. Copy the item and paste it with ⌘V.")
        ).font(.system(size: 11)).foregroundStyle(.secondary)
        if model.pasteAccess == "required" {
          Button(localized("Allow…")) {
            model.perform(NativeUICommand("clipboardHistory.requestPasteAccess"))
          }.disabled(model.busy).controlSize(.small)
        }
      }.padding(10)
    }
  }
}
struct NativeStorageNotice: View {
  @ObservedObject var model: NativeUIModel
  var store = "history"
  var body: some View {
    let sync = store == "sync"
    let status = sync ? model.settings.syncStorageStatus : model.storageStatus
    if status == "failed" {
      let stage = sync ? model.settings.syncStorageStage : model.storageDiagnosticStage
      let code = sync ? model.settings.syncStorageCode : model.storageDiagnosticCode
      let path = sync ? model.settings.syncStoragePath : model.storagePath
      let diagnostic = sync ? model.settings.syncStorageError : model.storageError
      VStack(alignment: .leading, spacing: 8) {
        NativeErrorNotice(
          text: sync
            ? localized("Sync Storage Unavailable")
            : model.destination == "snippets"
              ? localized("Snippets Unavailable") : localized("Clipboard History Unavailable"))
        Text(
          sync
            ? localized(
              "Sync has stopped. Local history and other Polka features remain available.")
            : model.preferencesAvailable
              ? localized(
                "New items are not saved. Saved items can be viewed and copied. Sync has stopped.")
              : localized(
                "Could not load saved history and its settings. Recording, hover activation, the history shortcut, and automatic paste are unavailable. Emoji can be copied."
              )
        ).font(.system(size: 11)).foregroundStyle(.secondary)
        Text(
          localized(
            "The file has not been reset. Restore access to storage and restart Polka. Before replacing the file, save an encrypted copy."
          )
        ).font(.system(size: 11)).foregroundStyle(.secondary)
        if ["decrypt", "encrypt"].contains(stage) {
          Text(
            localized(
              "If macOS requests access to “polka Safe Storage”, enter your “login” keychain password and choose “Always Allow”."
            )
          ).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        DisclosureGroup(localized("Error Details")) {
          Text(diagnostic + (code.isEmpty ? "" : " · " + code)).font(.system(size: 11))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
        NativeCommandButton(title: localized("Show File in Finder"), disabled: model.busy) {
          model.perform(
            NativeUICommand("clipboardHistory.revealStorage", strings: ["store": store]))
        }
      }.padding(.vertical, 8)
    }
  }
}
