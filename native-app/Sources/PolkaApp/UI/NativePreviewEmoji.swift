import AppKit
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
          id: "upperCase", label: "ПРОПИСНЫЕ",
          disabled: busy || clip.content.uppercased() == clip.content,
          run: { [weak self] in
            guard self?.busy == false, clip.content.uppercased() != clip.content else { return }
            self?.transformation = "upperCase"
          }),
        NativePreviewAction(
          id: "lowerCase", label: "строчные",
          disabled: busy || clip.content.lowercased() == clip.content,
          run: { [weak self] in
            guard self?.busy == false, clip.content.lowercased() != clip.content else { return }
            self?.transformation = "lowerCase"
          }),
      ]
      if transformation != nil {
        actions.append(
          NativePreviewAction(
            id: "original", label: "Показать оригинал", disabled: busy,
            run: { [weak self] in
              guard self?.busy == false else { return }
              self?.transformation = nil
            }))
      }
      return actions
    }
    var actions = [
      NativePreviewAction(
        id: "saveImage", label: "Сохранить изображение…", disabled: busy,
        run: { [weak self] in self?.secondaryClipAction(clip) })
    ]
    if clip.ocrStatus == "ready" {
      actions.append(
        NativePreviewAction(
          id: "copyImageText", label: "Копировать текст", disabled: busy,
          run: { [weak self] in
            self?.perform(
              NativeUICommand("clipboardHistory.copyImageText", strings: ["id": clip.id]))
          }))
    } else if clip.ocrStatus == "failed" {
      actions.append(
        NativePreviewAction(
          id: "retryImageText", label: "Повторить распознавание", disabled: busy || !writable,
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
      HStack {
        Text(clip.name.isEmpty ? nativeClipDate(clip.createdAt) : clip.name).font(.system(size: 11))
          .foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        if clip.kind == "text" {
          NativeCommandButton(
            title: clip.snippet ? "Изменить сниппет" : "Создать сниппет", symbol: "pencil",
            shortcut: "⌘E", disabled: model.busy || !model.writable
          ) { model.edit(clip) }
        }
        if model.canPaste {
          NativeCommandButton(title: "Копировать", shortcut: "⇧↵", disabled: model.busy) {
            model.chooseClip(clip, copyOnly: true)
          }
        }
        NativeCommandButton(
          title: model.canPaste ? "Вставить" : "Копировать", shortcut: "↵", disabled: model.busy,
          prominent: true
        ) { model.chooseClip(clip) }
      }.padding(10)
      HStack {
        ForEach(Array(model.previewActions(for: clip).enumerated()), id: \.element.id) {
          index, action in
          NativeCommandButton(
            title: action.label, shortcut: action.id == "saveImage" ? "⌘S" : "⌘\(index + 1)",
            disabled: action.disabled, prominent: model.transformation == action.id
          ) { action.run() }
          .help(
            action.disabled && !model.busy && clip.kind == "text"
              ? "Исходный текст уже в этом виде"
              : "\(action.label) · " + (action.id == "saveImage" ? "⌘S / " : "") + "⌘\(index + 1)")
        }
        Spacer(minLength: 0)
      }.padding(.horizontal, 10).padding(.bottom, 10)
      if let transformation = model.transformation {
        Text(
          "Результат: \(transformation == "upperCase" ? "ПРОПИСНЫЕ" : "строчные"). Оригинал сохранён."
        ).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(
          .bottom, 8)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if clip.kind == "text" {
            Text(model.previewText).font(.system(size: 14, design: .monospaced)).textSelection(
              .enabled
            ).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier(
              "clipboard-preview-text")
          } else {
            if let image = model.previewImage ?? nativeImage(clip.content) {
              Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                .accessibilityLabel("Просмотр скопированного изображения")
            } else if model.busy {
              ProgressView().frame(maxWidth: .infinity)
            } else {
              NativeCommandButton(
                title: "Повторить загрузку изображения", shortcut: "⌘R", disabled: model.busy
              ) { model.reloadPreviewImage() }
            }
            Text("Текст на изображении").font(.system(size: 14, weight: .semibold))
            if clip.ocrStatus.isEmpty {
              Text("Распознаём текст на этом Mac… Изображение уже можно копировать.")
                .foregroundStyle(.secondary)
            } else if clip.ocrStatus == "failed" {
              Text("Не удалось распознать текст. Повторите распознавание.").foregroundStyle(
                .secondary)
            } else if clip.ocrStatus == "empty" {
              Text("Текст на изображении не найден.").foregroundStyle(.secondary)
            } else {
              Text(clip.ocrText).font(.system(size: 14, design: .monospaced)).textSelection(
                .enabled
              ).accessibilityLabel("Распознанный текст")
            }
            if !clip.ocrStatus.isEmpty, clip.ocrStatus != "failed",
              !clip.ocrLanguages.contains("ru-RU")
            {
              Text("Эта версия macOS не поддерживает распознавание русского текста.").font(
                .system(size: 11)
              ).foregroundStyle(.secondary)
            }
          }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
          NativeScrollPositionBridge(
            offset: $model.previewScrollOffset, token: clip.id + "-preview-" + String(model.visible)
          ))
      }.accessibilityIdentifier("native-clipboard-preview")
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
}

let nativeEmojiCategories: [(id: String, label: String, symbol: String)] = [
  ("all", "Все эмодзи", ""), ("Smileys & Emotion", "Смайлы и эмоции", "😀"),
  ("People & Body", "Люди и жесты", "👋"), ("Animals & Nature", "Животные и природа", "🌿"),
  ("Food & Drink", "Еда и напитки", "🍋"), ("Travel & Places", "Места и транспорт", "🚀"),
  ("Activities", "Занятия", "⚽"), ("Objects", "Предметы", "💡"), ("Symbols", "Символы", "❤️"),
  ("Flags", "Флаги", "🏳️"),
]
let nativeEmojiTones: [(String, String)] = [
  ("default", "✋ Стандартный"), ("🏻", "🏻 Очень светлый"), ("🏼", "🏼 Светлый"), ("🏽", "🏽 Средний"),
  ("🏾", "🏾 Тёмный"), ("🏿", "🏿 Очень тёмный"), ("all", "Все оттенки"),
]

struct NativeEmojiView: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        NativeIconButton(
          label: "Назад к приложениям", symbol: "arrow.left", shortcut: "⌫", disabled: model.busy
        ) { model.back() }
        Text("Эмодзи").font(.system(size: 17, weight: .semibold))
        Spacer()
        Text("Русский / English").font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(12)
      NativeSearchField(
        text: $model.query, placeholder: "Название или слово: улыбка, heart…", maxLength: 256,
        focusToken: "emoji-\(model.visible)-\(model.sessionRevision)"
      ).frame(maxWidth: .infinity).frame(height: 44).padding(.horizontal, 12).padding(.bottom, 10)
      NativeEmojiCategoryPicker(model: model).frame(maxWidth: .infinity).frame(height: 40).padding(
        .horizontal, 12
      ).padding(.bottom, 10)
      Divider()
      NativePasteAccessHint(model: model)
      NativeErrorNotice(text: model.error).padding(.horizontal, 10)
      HStack(spacing: 8) {
        Text(
          model.query.isEmpty
            ? nativeEmojiCategories.first(where: { $0.id == model.emojiCategory })?.label
              ?? "Все эмодзи" : "Результаты поиска")
        Text("\(model.emojiResults.count)")
        Spacer(minLength: 8)
        Picker("Оттенок кожи", selection: $model.emojiTone) {
          ForEach(nativeEmojiTones, id: \.0) { tone in Text(tone.1).tag(tone.0) }
        }.labelsHidden().frame(maxWidth: 160).disabled(model.busy).accessibilityLabel(
          "Оттенок кожи")
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
                emoji.name + " · " + emoji.englishName
              ).accessibilityHint(index < 9 ? "Выбрать: ⌘\(index + 1)" : "Выбрать: Enter").id(
                emoji.id
              ).onHover { if $0 { model.selectedID = emoji.id } }
            }
          }.padding(10).background(
            NativeScrollPositionBridge(
              offset: $model.listScrollOffset,
              token: "emoji-" + String(model.visible) + "-" + model.emojiCategory))
          if model.emojiResults.isEmpty {
            VStack(spacing: 10) {
              Text("Ничего не найдено").font(.system(size: 15, weight: .semibold))
              Text("Попробуйте другое слово на русском или английском.").foregroundStyle(.secondary)
              if model.emojiCategory != "all" || model.emojiTone != "default" {
                Button("Искать во всех категориях и оттенках") {
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
      HStack(spacing: 12) {
        Text(model.selectedEmoji?.value ?? "⌕").font(.system(size: 30)).frame(width: 40)
        VStack(alignment: .leading, spacing: 3) {
          Text(model.selectedEmoji?.name ?? "Выберите эмодзи").font(
            .system(size: 13, weight: .semibold)
          ).lineLimit(1)
          Text(model.selectedEmoji?.englishName ?? "Поиск по названиям и ключевым словам").font(
            .system(size: 11)
          ).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        NativeCommandButton(
          title: "Копировать", shortcut: "⇧↵", disabled: model.selectedEmoji == nil || model.busy
        ) { if let emoji = model.selectedEmoji { model.chooseEmoji(emoji, copyOnly: true) } }
      }.padding(12)
      Text("↑ ↓ ← → выбрать   ↵ \(model.canPaste ? "вставить" : "копировать")   esc закрыть").font(
        .system(size: 11)
      ).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(
        .horizontal, 12
      ).padding(.bottom, 12)
    }.onChange(of: model.query) { _, _ in model.emojiCategory = "all" }.onChange(
      of: model.emojiTone
    ) { _, _ in model.selectedID = nil }.accessibilityIdentifier("native-emoji")
  }
}

struct NativeEmojiCategoryPicker: NSViewRepresentable {
  var model: NativeUIModel
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
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityLabel("Категории эмодзи")
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
      button.toolTip = category.label + " · ← → выбрать категорию · Home / End первая / последняя"
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
  }
  private var canInteract: Bool {
    guard let model, model.visible, model.destination == "emoji", !model.busy else { return false }
    return window?.attachedSheet == nil && NSApp?.modalWindow == nil
      && !NSMenuTrackingState.shared.active
  }
  func synchronizeSelection() {
    let selected = nativeEmojiCategories.firstIndex { $0.id == model?.emojiCategory } ?? 0
    for (index, button) in buttons.enumerated() {
      button.state = index == selected ? .on : .off
      button.isEnabled = canInteract
      button.setAccessibilitySelected(index == selected)
      button.needsDisplay = true
    }
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

final class NativeEmojiCategoryButton: NSButton {
  private var hovering = false
  private var hoverTrackingArea: NSTrackingArea?
  override var acceptsFirstResponder: Bool { isEnabled && state == .on }
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
    if state == .on || (hovering && isEnabled) {
      (state == .on
        ? NSColor.controlAccentColor.withAlphaComponent(0.16)
        : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
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
