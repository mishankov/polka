import AppKit
import PolkaCore
import SwiftUI

struct NativePreviewAction: Identifiable {
  var id: String
  var label: String
  var disabled: Bool
  var run: () -> Void
}
extension NativeUIModel {
  func reloadPreviewImage() {
    guard !busy, visible, let clip = preview, clip.kind == "image" else { return }
    perform(NativeUICommand("clipboardHistory.preview", strings: ["id": clip.id]))
  }
  func previewActions(for clip: NativeUIClip) -> [NativePreviewAction] {
    if clip.kind == "text" {
      var actions = [
        NativePreviewAction(
          id: "upperCase", label: localized("UPPERCASE"),
          disabled: busy || clip.content.uppercased() == clip.content,
          run: { [weak self] in
            guard self?.busy == false, nativeCommandInteractionAllowed,
              clip.content.uppercased() != clip.content
            else { return }
            self?.transformation = "upperCase"
          }),
        NativePreviewAction(
          id: "lowerCase", label: localized("lowercase"),
          disabled: busy || clip.content.lowercased() == clip.content,
          run: { [weak self] in
            guard self?.busy == false, nativeCommandInteractionAllowed,
              clip.content.lowercased() != clip.content
            else { return }
            self?.transformation = "lowerCase"
          }),
      ]
      if transformation != nil {
        actions.append(
          NativePreviewAction(
            id: "original", label: localized("Show Original"), disabled: busy,
            run: { [weak self] in
              guard self?.busy == false, nativeCommandInteractionAllowed else { return }
              self?.transformation = nil
            }))
      }
      return actions
    }
    var actions = [
      NativePreviewAction(
        id: "saveImage", label: localized("Save Image…"), disabled: busy,
        run: { [weak self] in self?.secondaryClipAction(clip) })
    ]
    if clip.ocrStatus == "ready" {
      actions.append(
        NativePreviewAction(
          id: "copyImageText", label: localized("Copy Text"), disabled: busy,
          run: { [weak self] in
            self?.perform(
              NativeUICommand("clipboardHistory.copyImageText", strings: ["id": clip.id]))
          }))
    } else if clip.ocrStatus == "failed" {
      actions.append(
        NativePreviewAction(
          id: "retryImageText", label: localized("Retry Text Recognition"),
          disabled: busy || !writable,
          run: { [weak self] in
            guard self?.writable == true else { return }
            self?.perform(
              NativeUICommand("clipboardHistory.retryImageText", strings: ["id": clip.id]))
          }))
    }
    return actions
  }
}

struct NativeClipboardPreview: View {
  @ObservedObject var model: NativeUIModel
  var clip: NativeUIClip
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text(clip.name.isEmpty ? nativeClipDate(clip.createdAt) : clip.name).font(.system(size: 11))
          .foregroundStyle(.secondary).lineLimit(1)
        HStack(spacing: 8) {
          if clip.kind == "text" { previewActionButtons }
          Spacer(minLength: 8)
          if clip.kind == "text" {
            NativeIconButton(
              label: clip.snippet ? localized("Edit Snippet") : localized("Create Snippet"),
              symbol: "pencil",
              shortcut: "⌘E",
              disabled: model.busy || !model.writable
                || !model.settings.builtinApps.allows(destination: "snippets")
            ) { model.edit(clip) }
          }
        }
      }.padding(12)
      if clip.kind != "text" {
        HStack(spacing: 8) {
          previewActionButtons
          Spacer(minLength: 0)
        }.padding(.horizontal, 12).padding(.bottom, 10)
      }
      if let transformation = model.transformation {
        Text(
          localized(
            "Result: {0}. The original is preserved.",
            String(
              describing: transformation == "upperCase"
                ? localized("UPPERCASE") : localized("lowercase")))
        ).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(
          .bottom, 8)
      }
      if clip.kind == "text" {
        if let color = ClipboardColor.parse(model.previewText) {
          NativeColorSwatch(color: color).frame(height: 96).padding(.horizontal, 16)
            .padding(.bottom, 12).accessibilityIdentifier("clipboard-preview-color")
        }
        NativePlainTextPreview(
          text: model.previewText,
          scrollOffset: $model.previewScrollOffset,
          scrollToken: clip.id + "-preview-" + String(model.visible)
        )
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 12)
        .accessibilityIdentifier("native-clipboard-preview")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if let image = model.previewImage ?? nativeImage(clip.content) {
              Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                .accessibilityLabel(localized("Copied image preview"))
            } else if model.busy {
              ProgressView().frame(maxWidth: .infinity)
            } else {
              NativeCommandButton(
                title: localized("Retry Loading Image"), shortcut: "⌘R", disabled: model.busy
              ) { model.reloadPreviewImage() }
            }
            Text(localized("Text in the Image")).font(.system(size: 14, weight: .semibold))
            if clip.ocrStatus.isEmpty {
              Text(localized("Recognizing text on this Mac… You can already copy the image."))
                .foregroundStyle(.secondary)
            } else if clip.ocrStatus == "failed" {
              Text(localized("Could not recognize text. Retry text recognition.")).foregroundStyle(
                .secondary)
            } else if clip.ocrStatus == "empty" {
              Text(localized("No text found in the image.")).foregroundStyle(.secondary)
            } else {
              Text(clip.ocrText).font(.system(size: 14, design: .monospaced)).textSelection(
                .enabled
              ).accessibilityLabel(localized("Recognized text"))
            }
            if !clip.ocrStatus.isEmpty, clip.ocrStatus != "failed",
              !clip.ocrLanguages.contains("ru-RU")
            {
              Text(localized("This version of macOS does not support Russian text recognition."))
                .font(
                  .system(size: 11)
                ).foregroundStyle(.secondary)
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
            NativeScrollPositionBridge(
              offset: $model.previewScrollOffset,
              token: clip.id + "-preview-" + String(model.visible)
            ))
        }.accessibilityIdentifier("native-clipboard-preview")
      }
    }.task(id: clip.id + String(model.visible)) {
      guard clip.kind == "image", model.previewImage == nil, nativeImage(clip.content) == nil else {
        return
      }
      // A resumed preview may commit while the navigation action is still
      // completing; wait before using the same guarded reload command.
      while model.busy, !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
      guard !Task.isCancelled, model.previewID == clip.id, model.visible, model.previewImage == nil
      else { return }
      model.reloadPreviewImage()
    }
  }
  @ViewBuilder private var previewActionButtons: some View {
    ForEach(Array(model.previewActions(for: clip).enumerated()), id: \.element.id) {
      index, action in
      if action.id == "original" {
        NativeIconButton(
          label: action.label, symbol: "arrow.uturn.backward", shortcut: "⌘\(index + 1)",
          disabled: action.disabled
        ) { action.run() }
      } else {
        NativeCommandButton(
          title: action.label, shortcut: action.id == "saveImage" ? "⌘S" : "⌘\(index + 1)",
          disabled: action.disabled, prominent: model.transformation == action.id
        ) { action.run() }
        .help(
          action.disabled && !model.busy && clip.kind == "text"
            ? localized("The original text is already in this form")
            : "\(action.label) · " + (action.id == "saveImage" ? "⌘S / " : "")
              + "⌘\(index + 1)"
        )
      }
    }
  }

}

var nativeEmojiCategories: [(id: String, label: String, symbol: String)] {
  [
    ("all", localized("All emoji"), ""), ("Smileys & Emotion", localized("Smileys & Emotion"), "😀"),
    ("People & Body", localized("People & Body"), "👋"),
    ("Animals & Nature", localized("Animals & Nature"), "🌿"),
    ("Food & Drink", localized("Food & Drink"), "🍋"),
    ("Travel & Places", localized("Travel & Places"), "🚀"),
    ("Activities", localized("Activities"), "⚽"), ("Objects", localized("Objects"), "💡"),
    ("Symbols", localized("Symbols"), "❤️"),
    ("Flags", localized("Flags"), "🏳️"),
  ]
}
var nativeEmojiTones: [(String, String)] {
  [
    ("default", localized("✋ Default")), ("🏻", localized("🏻 Light")),
    ("🏼", localized("🏼 Medium-light")),
    ("🏽", localized("🏽 Medium")),
    ("🏾", localized("🏾 Medium-dark")), ("🏿", localized("🏿 Dark")),
    ("all", localized("All skin tones")),
  ]
}

struct NativeEmojiView: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    VStack(spacing: 0) {
      NativeBuiltinHeader(model: model, title: localized("Emoji")) {
        Text(localized("English / Русский")).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      NativeBuiltinSearch(
        model: model, placeholder: localized("Name or word: smile, heart…"), maxLength: 256)
      NativeEmojiCategoryPicker(model: model).frame(maxWidth: .infinity).frame(height: 40)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12).padding(.bottom, 10)
      Divider()
      NativePasteAccessHint(model: model)
      NativeErrorNotice(text: model.error).padding(.horizontal, 10)
      HStack(spacing: 8) {
        Text(
          model.query.isEmpty
            ? nativeEmojiCategories.first(where: { $0.id == model.emojiCategory })?.label
              ?? localized("All emoji") : localized("Search results"))
        Text("\(model.emojiResults.count)")
        Spacer(minLength: 8)
        Picker(localized("Skin tone"), selection: $model.emojiTone) {
          ForEach(nativeEmojiTones, id: \.0) { tone in Text(tone.1).tag(tone.0) }
        }.labelsHidden().frame(maxWidth: 160).disabled(model.busy).accessibilityLabel(
          localized("Skin tone"))
      }.font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
      ScrollViewReader { reader in
        ScrollView {
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 10), spacing: 3
          ) {
            ForEach(Array(model.emojiResults.enumerated()), id: \.element.id) { index, emoji in
              Button {
                model.selectedID = emoji.id
                model.chooseEmoji(emoji)
              } label: {
                VStack(spacing: 0) {
                  Text(emoji.value).font(.system(size: 29)).frame(height: 38)
                  Text(index < 9 ? "⌘\(index + 1)" : " ").font(.system(size: 8)).foregroundStyle(
                    .tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 3).background(
                  model.selectedEmoji?.id == emoji.id ? Color.accentColor.opacity(0.16) : .clear,
                  in: RoundedRectangle(cornerRadius: 6))
              }.buttonStyle(.plain).disabled(model.busy).help(emoji.name).accessibilityLabel(
                emoji.name == emoji.englishName
                  ? emoji.name : emoji.name + " · " + emoji.englishName
              ).accessibilityHint(
                index < 9
                  ? localized("Select: ⌘{0}", String(describing: index + 1))
                  : localized("Select: Enter")
              ).id(
                emoji.id
              ).onHover { if $0 { model.selectedID = emoji.id } }
            }
          }.padding(10).background(
            NativeScrollPositionBridge(
              offset: $model.listScrollOffset,
              token: "emoji-" + String(model.visible) + "-" + model.emojiCategory))
          if model.emojiResults.isEmpty {
            VStack(spacing: 10) {
              Text(localized("Nothing Found")).font(.system(size: 15, weight: .semibold))
              Text(localized("Try another word in English or Russian.")).foregroundStyle(.secondary)
              if model.emojiCategory != "all" || model.emojiTone != "default" {
                NativeCommandButton(
                  title: localized("Search All Categories and Skin Tones"), disabled: model.busy
                ) {
                  model.emojiCategory = "all"
                  model.emojiTone = "all"
                }
              }
            }.font(.system(size: 12)).padding(30)
          }
        }.onChange(of: model.scrollID) { _, id in if let id { reader.scrollTo(id, anchor: .center) }
        }
      }
      Divider()
      NativeToolbar {
        Text(model.selectedEmoji?.value ?? "⌕").font(.system(size: 30)).frame(width: 40, height: 32)
        VStack(alignment: .leading, spacing: 3) {
          Text(model.selectedEmoji?.name ?? localized("Select an Emoji")).font(
            .system(size: 13, weight: .semibold)
          ).lineLimit(1)
          Text(model.selectedEmoji?.englishName ?? localized("Search by names and keywords")).font(
            .system(size: 11)
          ).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        NativeSelectionActions(
          canPaste: model.canPaste, disabled: model.selectedEmoji == nil || model.busy
        ) { copyOnly in
          if let emoji = model.selectedEmoji { model.chooseEmoji(emoji, copyOnly: copyOnly) }
        }
      }
      NativeKeyboardHint(
        text: localized(
          "↑ ↓ ← → select   ↵ {0}   esc close",
          String(describing: model.canPaste ? localized("Paste") : localized("Copy"))))
    }.onChange(of: model.query) { _, _ in model.emojiCategory = "all" }.onChange(
      of: model.emojiTone
    ) { _, _ in model.selectedID = nil }.accessibilityElement(children: .contain)
      .accessibilityIdentifier("native-emoji")
  }
}

struct NativeEmojiCategoryPicker: NSViewRepresentable {
  @ObservedObject var model: NativeUIModel
  func makeNSView(context: Context) -> NativeEmojiCategoryBar {
    let bar = NativeEmojiCategoryBar()
    bar.model = model
    bar.synchronizeSelection()
    return bar
  }
  func updateNSView(_ bar: NativeEmojiCategoryBar, context: Context) {
    bar.model = model
    bar.synchronizeSelection()
  }
}

extension NativeUIModel {
  @discardableResult func chooseEmojiCategory(_ id: String) -> Bool {
    guard visible, destination == "emoji", !busy,
      nativeEmojiCategories.contains(where: { $0.id == id }), emojiCategory != id
    else { return false }
    emojiCategory = id
    selectedID = nil
    listScrollOffset = 0
    scrollID = nil
    return true
  }
}

final class NativeEmojiCategoryBar: NSView {
  weak var model: NativeUIModel?
  private(set) var buttons: [NativeEmojiCategoryButton] = []
  private let selectionGlass = NativeEmojiSelectionGlass()
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityLabel(localized("Emoji categories"))
    selectionGlass.cornerRadius = 17
    selectionGlass.setAccessibilityElement(false)
    addSubview(selectionGlass)
    for (index, category) in nativeEmojiCategories.enumerated() {
      let button = NativeEmojiCategoryButton(frame: .zero)
      button.tag = index
      button.setButtonType(.pushOnPushOff)
      button.isBordered = false
      button.font = .systemFont(ofSize: 24)
      button.contentTintColor = .labelColor
      button.target = self
      button.action = #selector(categoryClicked(_:))
      if category.id == "all" {
        button.image = NSImage(
          systemSymbolName: "square.grid.2x2", accessibilityDescription: category.label)?
          .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        button.imagePosition = .imageOnly
      } else {
        button.title = category.symbol
      }
      button.toolTip =
        category.label + localized(" · ← → select category · Home / End first / last")
      button.setAccessibilityRole(.radioButton)
      button.setAccessibilityLabel(category.label)
      button.setAccessibilityHelp(button.toolTip)
      button.setAccessibilityIdentifier("emoji-category-" + category.id)
      addSubview(button)
      buttons.append(button)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 40) }
  override func layout() {
    super.layout()
    let slot = bounds.width / CGFloat(buttons.count)
    for (index, button) in buttons.enumerated() {
      button.frame = NSRect(
        x: CGFloat(index) * slot + 3, y: (bounds.height - 40) / 2, width: max(0, slot - 6),
        height: 40)
    }
    updateSelectionGlass()
  }
  private func updateSelectionGlass() {
    guard let selected = buttons.first(where: { $0.state == .on }),
      selected.frame.width > 0, selected.frame.height > 6
    else {
      selectionGlass.isHidden = true
      return
    }
    selectionGlass.isHidden = false
    selectionGlass.frame = selected.frame.insetBy(dx: 0, dy: 3)
  }
  private var canInteract: Bool {
    guard let model, model.visible, model.destination == "emoji", !model.busy else { return false }
    return window?.attachedSheet == nil && NSApp?.modalWindow == nil
      && !NSMenuTrackingState.shared.active
  }
  func synchronizeSelection() {
    setAccessibilityLabel(localized("Emoji categories"))
    let selected = nativeEmojiCategories.firstIndex { $0.id == model?.emojiCategory } ?? 0
    for (index, button) in buttons.enumerated() {
      let category = nativeEmojiCategories[index]
      button.toolTip =
        category.label + localized(" · ← → select category · Home / End first / last")
      button.setAccessibilityLabel(category.label)
      button.setAccessibilityHelp(button.toolTip)
      button.state = index == selected ? .on : .off
      button.isEnabled = canInteract
      button.setAccessibilitySelected(index == selected)
      button.needsDisplay = true
    }
    updateSelectionGlass()
  }
  @objc private func categoryClicked(_ sender: NativeEmojiCategoryButton) {
    if canInteract, nativeEmojiCategories.indices.contains(sender.tag) {
      model?.chooseEmojiCategory(nativeEmojiCategories[sender.tag].id)
    }
    synchronizeSelection()
  }
  @discardableResult func moveSelection(keyCode: UInt16, isRepeat: Bool = false) -> Bool {
    guard [123, 124, 115, 119].contains(keyCode) else { return false }
    guard !isRepeat else { return true }
    guard canInteract else { return false }
    let selected = nativeEmojiCategories.firstIndex { $0.id == model?.emojiCategory } ?? 0
    let next: Int
    switch keyCode {
    case 123: next = (selected + buttons.count - 1) % buttons.count
    case 124: next = (selected + 1) % buttons.count
    case 115: next = 0
    default: next = buttons.count - 1
    }
    model?.chooseEmojiCategory(nativeEmojiCategories[next].id)
    synchronizeSelection()
    window?.makeFirstResponder(buttons[next])
    return true
  }
}

/// The glass lens is decoration; category buttons retain pointer and keyboard input.
private final class NativeEmojiSelectionGlass: NSGlassEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class NativeEmojiCategoryButton: NSButton {
  private var hovering = false
  private var hoverTrackingArea: NSTrackingArea?
  override var acceptsFirstResponder: Bool { isEnabled && state == .on }
  override var canBecomeKeyView: Bool {
    // NSButton otherwise excludes buttons when Full Keyboard Access is off.
    // This category picker has one explicit Tab stop, like a native tab group.
    acceptsFirstResponder && !isHiddenOrHasHiddenAncestor && window?.canBecomeKey == true
  }
  override func updateTrackingAreas() {
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverTrackingArea = area
    super.updateTrackingAreas()
  }
  override func mouseEntered(with event: NSEvent) {
    hovering = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hovering = false
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    if state == .off && hovering && isEnabled {
      NSColor.labelColor.withAlphaComponent(0.06).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 17, yRadius: 17).fill()
    }
    super.draw(dirtyRect)
  }
  override func mouseDown(with event: NSEvent) {
    let previous = window?.firstResponder
    super.mouseDown(with: event)
    if previous is NSTextView || previous is NSSearchField, window?.firstResponder !== previous {
      window?.makeFirstResponder(previous)
    }
  }
  override func keyDown(with event: NSEvent) {
    if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      super.keyDown(with: event)
      return
    }
    if [123, 124, 115, 119].contains(event.keyCode) {
      _ = (superview as? NativeEmojiCategoryBar)?.moveSelection(
        keyCode: event.keyCode, isRepeat: event.isARepeat)
      return
    }
    if event.keyCode == 49 && event.isARepeat { return }
    super.keyDown(with: event)
  }
}
