import AppKit
import PolkaCore
import SwiftUI

struct NativeShelfView: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    let colors = model.settings.themes.active.shelfColors
    VStack(spacing: 0) {
      switch model.destination {
      case "clipboard", "snippets": NativeClipboardView(model: model)
      case "quick-links": NativeQuickLinksView(model: model)
      case "emoji": NativeEmojiView(model: model)
      case "files": NativeFileShelfView(model: model)
      case "system-status": NativeSystemStatusView(model: model)
      default: NativeLauncherView(model: model)
      }
    }
    .foregroundStyle(
      AnyShapeStyle(colors?.textColor ?? .primary),
      AnyShapeStyle(colors?.secondaryTextColor ?? .secondary),
      colors.map { AnyShapeStyle($0.secondaryTextColor) } ?? AnyShapeStyle(.tertiary)
    )
    .tint(colors?.accentColor)
    .environment(\.colorScheme, colors?.colorScheme ?? .dark)
    .background(NativeKeyboardBridge(model: model).frame(width: 0, height: 0))
    .background(colors?.backgroundColor ?? .black)
    .overlay(alignment: .top) {
      // The display's cutout supplies the notch silhouette as the shelf opens.
      if !model.visible, model.topInset == 0 {
        Color.black.frame(width: NativeShelfPresentationView.collapsedWidth, height: 3)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
    }
    .modifier(NativeFileDropModifier(model: model))
    .environment(\.shelfColors, colors)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("native-shelf")
  }
}

struct NativeLauncherView: View {
  @ObservedObject var model: NativeUIModel
  @Environment(\.shelfColors) private var colors
  var body: some View {
    let results = model.searchResults
    let selectedID = results.first(where: { $0.id == model.selectedID })?.id ?? results.first?.id
    return VStack(spacing: 0) {
      HStack(spacing: 10) {
        NativeSearchField(
          text: $model.query, placeholder: localized("Find or calculate…"),
          focusToken: "apps-\(model.visible)-\(model.sessionRevision)"
        ).frame(maxWidth: .infinity).frame(height: 44).disabled(model.fileDownloadProgress != nil)
        NativeIconButton(
          label: localized("Settings"), symbol: "gearshape", shortcut: "⌘,", disabled: model.busy
        ) { model.perform(NativeUICommand("shelf.settings")) }
      }.padding(14).padding(.top, model.topInset).background(colors?.searchHeaderColor ?? .clear)
      Divider()
      NativeFileDownloadProgress(model: model)
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              NativeUpdateNotice(model: model).padding(.horizontal, 10)
              if !model.settings.introduced {
                welcome.padding(10)
              } else if model.offersShelfThemeDiscovery {
                NativeShelfThemeAnnouncement(model: model).padding(10)
              }
            }
            NativeErrorNotice(text: model.error.isEmpty ? model.catalogError : model.error).padding(
              .horizontal, 10)
            if !model.error.isEmpty || !model.catalogError.isEmpty {
              NativeCommandButton(title: localized("Refresh List"), disabled: model.busy) {
                model.perform(NativeUICommand("launcher.refresh"))
              }.padding(.horizontal, 12)
            }
            if let status = model.calculationStatus, !status.isEmpty {
              Text(status).nativeShelfSecondary().padding(12)
            }
            if !model.notice.isEmpty {
              Text(model.notice).font(.system(size: 12)).nativeShelfSecondary().padding(
                .horizontal, 12
              ).accessibilityIdentifier("native-action-notice")
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { position, result in
              let isCalculation = result.kind == "calculation"
              if position == 0 || group(result) != group(results[position - 1]) {
                Text(group(result)).font(.system(size: 11, weight: .semibold))
                  .nativeShelfDetail().padding(.horizontal, 14).padding(.top, 10)
              }
              Button {
                model.activateSearch(result)
              } label: {
                HStack(spacing: 10) {
                  resultIcon(result)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(result.title).font(
                      .system(
                        size: isCalculation ? 24 : 14, weight: isCalculation ? .medium : .regular)
                    ).lineLimit(isCalculation ? nil : 2)
                      .fixedSize(horizontal: false, vertical: isCalculation)
                    if !result.detail.isEmpty {
                      Text(result.detail).font(.system(size: 11)).nativeShelfSecondary()
                        .lineLimit(2)
                    }
                  }
                  Spacer(minLength: 0)
                  if position < 9 {
                    Text("⌘\(position + 1)").font(.system(size: 11)).nativeShelfDetail(.tertiary)
                  }
                }.padding(.horizontal, 12).padding(.vertical, 10).frame(
                  maxWidth: .infinity, alignment: .leading
                )
                .nativeShelfRow(selected: selectedID == result.id, defaultOpacity: 0.13)
              }.buttonStyle(.plain).disabled(model.busy).padding(.horizontal, 6)
                .id(result.id).accessibilityIdentifier("result-\(result.id)")
                .accessibilityLabel(result.title)
                .accessibilityValue(result.kind == "quick-link" ? result.detail : "")
                .accessibilityHint(
                  isCalculation
                    ? (position < 9
                      ? localized("Copy result: Enter or ⌘{0}", String(position + 1))
                      : localized("Copy result: Enter"))
                    : position < 9
                      ? localized("Open: ⌘{0}", String(position + 1))
                      : localized("Open: Enter")
                )
                .onContinuousHover { phase in
                  if case .active = phase { model.selectHoveredItem(result.id) }
                }
            }
            if results.isEmpty {
              if model.storageStatus == "starting" || model.catalogLoading {
                ProgressView().frame(maxWidth: .infinity).padding(24)
              } else {
                Text(
                  model.query.isEmpty
                    ? localized("The app list is empty. Try refreshing it.")
                    : localized("Nothing found. Try another word.")
                ).nativeShelfSecondary().font(.system(size: 13)).padding(24)
              }
            }
          }.padding(.bottom, 10).background(
            NativeScrollPositionBridge(
              offset: $model.listScrollOffset, token: "apps-list-\(model.visible)"))
        }
        .onChange(of: model.scrollID) { _, id in if let id { reader.scrollTo(id, anchor: .center) }
        }
      }
    }
  }
  private var welcome: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(localized("It All Starts with the Shelf")).font(.system(size: 14, weight: .semibold))
      Text(
        localized(
          "Open apps and find copied items. Return here using the menu bar icon, hovering over the camera notch, or {0}.",
          String(describing: nativeShortcutLabel(model.settings.launcherShortcut)))
      ).font(.system(size: 12)).nativeShelfSecondary()
      HStack {
        NativeCommandButton(title: localized("Got It"), disabled: model.busy) {
          model.perform(
            NativeUICommand(
              "settings.set", strings: ["key": "shelfIntroduced"], bools: ["value": true]))
        }.accessibilityIdentifier("acknowledge-shelf-welcome")
        NativeCommandButton(title: localized("Set Up Shelf"), shortcut: "⌘,", disabled: model.busy)
        {
          model.perform(NativeUICommand("shelf.settings"))
        }
        if model.offersShelfThemeDiscovery {
          NativeBrowseThemesButton(model: model)
        }
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
      colors?.surfaceColor ?? Color.accentColor.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 8))
  }
  private func group(_ result: NativeUISearchRow) -> String {
    switch result.kind {
    case "calculation": localized("Calculator")
    case "quick-link": localized("Quick Links")
    case "clip": result.snippet ? localized("Snippets") : localized("Clipboard")
    case "more-snippets": localized("Snippets")
    case "more-clips": localized("Clipboard")
    default: localized("Apps")
    }
  }
  @ViewBuilder private func resultIcon(_ result: NativeUISearchRow) -> some View {
    if let image = nativeImage(result.icon) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 34, height: 34)
    } else {
      Image(systemName: resultSymbol(result)).font(.system(size: 23)).nativeShelfDetail()
        .frame(width: 34, height: 34)
    }
  }
  private func resultSymbol(_ result: NativeUISearchRow) -> String {
    switch result.kind {
    case "calculation": return "equal"
    case "quick-link": return "link"
    case "clip": return "clipboard"
    default: break
    }
    switch result.id {
    case "builtin:emoji": return "face.smiling"
    case "builtin:snippets": return "text.bubble"
    case "builtin:quick-links": return "link"
    case "builtin:screenshots": return "viewfinder"
    case "builtin:files": return "folder"
    case "builtin:system-status": return "gauge.with.dots.needle.50percent"
    default: return "app"
    }
  }
}

extension NativeUIModel {
  var offersShelfThemeDiscovery: Bool {
    themeDiscoveryVisible && (!settings.introduced || !settings.showsUpdateNotice)
  }

  func browseShelfThemes() {
    guard offersShelfThemeDiscovery, themeActionsAvailable else { return }
    perform(NativeUICommand("shelf.settings", strings: ["section": "themes", "filter": "popular"]))
  }

  func dismissShelfThemeAnnouncement() {
    guard offersShelfThemeDiscovery, settings.introduced, themeActionsAvailable else { return }
    perform(NativeUICommand("theme.discovery.dismiss"))
  }
}

private struct NativeBrowseThemesButton: View {
  @ObservedObject var model: NativeUIModel

  var body: some View {
    NativeCommandButton(
      title: localized("Browse Themes"), shortcut: "⌘⇧T", disabled: !model.themeActionsAvailable
    ) { model.browseShelfThemes() }
    .accessibilityIdentifier("browse-shelf-themes")
  }
}

private struct NativeShelfThemeAnnouncement: View {
  @ObservedObject var model: NativeUIModel
  @Environment(\.shelfColors) private var colors

  private static let previews = NativeThemeCategory.popular.themes.filter {
    ["dracula", "rose-pine-dawn"].contains($0.id)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text(localized("Give your Shelf a new look"))
          .font(.system(size: 14, weight: .semibold))
        Text(localized("Pick a theme or customize your own."))
          .font(.system(size: 12)).nativeShelfSecondary()
        HStack(spacing: 5) {
          NativeBrowseThemesButton(model: model)
          NativeCommandButton(title: localized("Dismiss"), disabled: !model.themeActionsAvailable) {
            model.dismissShelfThemeAnnouncement()
          }.accessibilityIdentifier("dismiss-shelf-theme-announcement")
        }.padding(.top, 3)
      }
      Spacer(minLength: 0)
      HStack(alignment: .top, spacing: 6) {
        ForEach(Self.previews) { theme in
          VStack(alignment: .leading, spacing: 4) {
            NativeThemeShelfPreview(colors: theme.colors, compact: true)
            Text(theme.name).font(.system(size: 10, weight: .medium)).nativeShelfSecondary()
          }.frame(width: 105)
        }
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(
        colors?.surfaceColor ?? Color.accentColor.opacity(0.06),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("shelf-theme-announcement")
  }
}

struct NativeClipboardView: View {
  @ObservedObject var model: NativeUIModel
  @Environment(\.shelfColors) private var colors
  @FocusState private var editorNameFocused: Bool
  private var isSnippets: Bool { model.destination == "snippets" }
  var body: some View {
    VStack(spacing: 0) {
      NativeBuiltinHeader(
        model: model, title: isSnippets ? localized("Snippets") : localized("Clipboard"),
        status: !isSnippets && model.settings.paused ? localized("Recording Paused") : nil
      ) {
        if isSnippets, model.draft == nil, model.previewID == nil {
          NativeBuiltinHeaderAction(
            title: localized("Create"), symbol: "plus", shortcut: "⌘N",
            disabled: !model.writable || model.busy, prominent: true
          ) { model.createSnippet() }.accessibilityIdentifier("snippet-create")
        }
        if !isSnippets, model.draft == nil, !model.confirmClear {
          historyActions
        }
      }
      if model.draft == nil, model.previewID == nil, !model.confirmClear {
        NativeBuiltinSearch(
          model: model,
          placeholder: isSnippets
            ? localized("Find text or a name…") : localized("Find text, files, or text in images…"))
        if !isSnippets { filterBar }
      }
      Divider()
      NativePasteAccessHint(model: model)
      NativeStorageNotice(model: model).padding(.horizontal, 10)
      NativeErrorNotice(text: model.error.isEmpty ? model.helperError : model.error).padding(
        .horizontal, 10)
      NativeFileDownloadProgress(model: model)
      if !model.notice.isEmpty {
        Text(model.notice).font(.system(size: 12)).nativeShelfSecondary().padding(8)
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
      }
    }.accessibilityElement(children: .contain).accessibilityIdentifier(
      isSnippets ? "native-snippets" : "native-clipboard")
  }

  @ViewBuilder private var historyActions: some View {
    let menu = Menu {
      Button(localized("Clear History on All Linked Macs… · ⌘⇧⌫")) {
        model.showClearConfirmation()
      }.disabled(!model.writable || model.clips.isEmpty || model.busy)
    } label: {
      Image(systemName: "ellipsis").frame(width: 20, height: 20)
    }
    .menuIndicator(.hidden).controlSize(.regular).disabled(model.busy)
    .help(localized("History actions")).accessibilityLabel(localized("History actions"))

    if let colors {
      // The standard glass Menu dilutes its tint. Pair the themed glyph with
      // the actual accent fill while keeping AppKit's native menu behavior.
      menu.menuStyle(.borderlessButton).buttonStyle(.plain)
        .tint(colors.accentTextColor)
        .frame(width: 28, height: 28)
        .background(colors.accentColor, in: Circle())
    } else {
      menu.menuStyle(.button).buttonStyle(.glass).buttonBorderShape(.circle)
    }
  }

  private var filterBar: some View {
    HStack(spacing: 8) {
      ForEach(Array(ClipboardFilter.allCases.enumerated()), id: \.element) { index, filter in
        NativeCommandButton(
          title: filter.label, disabled: !model.canChangeClipboardFilter,
          prominent: model.clipboardFilter == filter
        ) { model.chooseClipboardFilter(filter) }
        .help(filter.label + " · ⌘⌃\(index + 1)")
        .accessibilityHint(localized("Keyboard shortcut: ") + "⌘⌃\(index + 1)")
        .accessibilityIdentifier("clipboard-filter-" + filter.rawValue)
        .accessibilityAddTraits(model.clipboardFilter == filter ? [.isSelected] : [])
        .accessibilityCustomContent(Text(localized("Keyboard shortcut")), Text("⌘⌃\(index + 1)"))
      }
      Spacer(minLength: 0)
    }.padding(.horizontal, 12).padding(.bottom, 10)
      .accessibilityElement(children: .contain).accessibilityLabel(localized("Content type"))
  }
  private var editor: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(localized(model.draft?.id.isEmpty == true ? "Create Snippet" : "Edit Snippet"))
        .font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
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
      ).font(.system(size: 14))
        .scrollContentBackground(colors == nil ? .automatic : .hidden)
        .padding(4)
        .background(
          colors?.surfaceColor ?? Color(nsColor: .textBackgroundColor),
          in: RoundedRectangle(cornerRadius: 6)
        ).disabled(model.busy).accessibilityIdentifier("snippet-content")
      Text(
        model.draft?.id.isEmpty == false
          ? localized("Different snippets can have the same text.")
          : localized("The snippet will be saved separately from clipboard history.")
      ).font(.system(size: 11)).nativeShelfSecondary()
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
      ).font(.system(size: 13)).nativeShelfSecondary()
      Spacer()
    }.padding(12).accessibilityIdentifier("clear-history-confirmation")
  }
  private var clipList: some View {
    let results = model.clipResults
    let selectedID = results.first(where: { $0.id == model.selectedID })?.id ?? results.first?.id
    return ScrollViewReader { reader in
      ScrollView {
        LazyVStack(spacing: 2) {
          if model.storageStatus == "starting" {
            ProgressView().padding(24)
          } else if results.isEmpty {
            VStack(spacing: 10) {
              Image(systemName: isSnippets ? "text.bubble" : "clipboard").font(.system(size: 34))
                .nativeShelfSecondary()
              Text(
                model.storageStatus == "failed"
                  ? localized("History Unavailable")
                  : (!isSnippets && model.clipboardFilter != .all) || !model.query.isEmpty
                    ? localized("Nothing Found")
                    : isSnippets
                      ? localized("Save Ready-to-Use Text") : localized("Copied Items Appear Here")
              ).font(.system(size: 15, weight: .semibold))
              Text(
                model.storageStatus == "failed"
                  ? localized("Restore access to storage and restart Polka.")
                  : !isSnippets && model.clipboardFilter != .all
                    ? localized("No items match the selected type and search.")
                    : !model.query.isEmpty
                      ? localized("Try another word.")
                      : isSnippets
                        ? localized(
                          "Create a snippet for an address, details, or a standard reply.")
                        : model.settings.paused
                          ? localized("Enable clipboard recording in app settings.")
                          : localized("Copy text, an image, or files in any app.")
              ).font(.system(size: 12)).nativeShelfSecondary().multilineTextAlignment(.center)
              if model.storageStatus != "failed", !isSnippets, model.clipboardFilter != .all {
                NativeCommandButton(
                  title: localized("Show All Types"), shortcut: "⌘⌃1",
                  disabled: !model.canChangeClipboardFilter
                ) { model.chooseClipboardFilter(.all) }
                .accessibilityIdentifier("clipboard-filter-reset")
              }
            }.padding(32)
          }
          ForEach(Array(results.enumerated()), id: \.element.id) { position, clip in
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
                    Image(
                      systemName: clip.kind == "image"
                        ? "photo" : clip.kind == "files" ? "doc.on.doc" : "textformat"
                    ).font(
                      .system(size: 23)
                    ).nativeShelfSecondary().frame(width: 38, height: 38)
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
                      Text(clip.preview).font(.system(size: 11)).nativeShelfSecondary()
                        .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                      if clip.pinned, !isSnippets { Image(systemName: "pin.fill") }
                      Text(
                        nativeClipDate(clip.createdAt)
                          + (clip.sourceDevice.isEmpty ? "" : " · " + clip.sourceDevice))
                    }.font(.system(size: 10)).nativeShelfSecondary()
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("clip-\(clip.id)")
                .accessibilityHint(
                  position < 9
                    ? localized("Select: ⌘{0}", String(describing: position + 1))
                    : localized("Select: Enter"))
              // Reserve the action width even when hidden, so selection by
              // pointer or keyboard never reflows the text or shifts later rows.
              HStack(spacing: 8) {
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
              .opacity(selectedID == clip.id ? 1 : 0)
              .disabled(selectedID != clip.id)
              .allowsHitTesting(selectedID == clip.id)
              .accessibilityHidden(selectedID != clip.id)
              if position < 9 {
                Text("⌘\(position + 1)").font(.system(size: 10)).nativeShelfSecondary(.tertiary)
              }
            }.padding(10).nativeShelfRow(selected: selectedID == clip.id, defaultOpacity: 0.12)
              .padding(.horizontal, 5).id(clip.id).onContinuousHover { phase in
                if case .active = phase { model.selectHoveredItem(clip.id) }
              }
          }
        }.padding(.vertical, 8).background(
          NativeScrollPositionBridge(
            offset: $model.listScrollOffset,
            token: model.destination + "-list-" + model.clipboardFilter.rawValue + "-"
              + String(model.visible)))
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
      }.font(.system(size: 11)).nativeShelfSecondary().frame(
        maxWidth: .infinity, alignment: .leading
      ).padding(10)
    } else if model.settings.pasteOnSelect, model.pasteAccess != "granted" {
      HStack(alignment: .top) {
        Text(
          model.pasteAccess == "required"
            ? localized(
              "Automatic paste requires Accessibility access. Until it is allowed, use ⌘V.")
            : localized("Automatic paste is unavailable. Copy the item and paste it with ⌘V.")
        ).font(.system(size: 11)).nativeShelfSecondary()
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
        ).font(.system(size: 11)).nativeShelfSecondary()
        Text(
          localized(
            "The file has not been reset. Restore access to storage and restart Polka. Before replacing the file, save an encrypted copy."
          )
        ).font(.system(size: 11)).nativeShelfSecondary()
        if ["decrypt", "encrypt"].contains(stage) {
          Text(
            localized(
              "If macOS requests access to “polka Safe Storage”, enter your “login” keychain password and choose “Always Allow”."
            )
          ).font(.system(size: 11)).nativeShelfSecondary()
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
