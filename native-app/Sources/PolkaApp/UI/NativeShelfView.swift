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
    .background(NativeKeyboardBridge(model: model).frame(width: 0, height: 0))
    .background(Color.black)
    .onChange(of: model.query) { _, _ in
      model.selectedID = nil
      model.notice = ""
      model.searchRevision += 1
    }
    .modifier(NativeFileDropModifier(model: model))
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
          text: $model.query, placeholder: "Найти или посчитать…",
          focusToken: "apps-\(model.visible)-\(model.sessionRevision)"
        ).frame(maxWidth: .infinity).frame(height: 44)
        NativeIconButton(
          label: "Настройки", symbol: "gearshape", shortcut: "⌘,", disabled: model.busy
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
              NativeCommandButton(title: "Обновить список", disabled: model.busy) {
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
                  position < 9 ? "Открыть: ⌘\(position + 1)" : "Открыть: Enter"
                )
                .onHover { if $0, model.selectedID != result.id { model.selectedID = result.id } }
            }
            if results.isEmpty {
              if model.storageStatus == "starting" || model.catalogLoading {
                ProgressView().frame(maxWidth: .infinity).padding(24)
              } else {
                Text(
                  model.query.isEmpty
                    ? "Список приложений пока пуст. Попробуйте обновить его."
                    : "Ничего не найдено. Попробуйте другое слово."
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
            ? "Выполняем…" : model.catalogLoading ? "Ищем…" : "Результаты · \(results.count)")
        Spacer()
        Text("↑ ↓ выбрать   ↵ открыть   esc закрыть")
      }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
    }
  }
  private var welcome: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Всё начинается с полки").font(.system(size: 14, weight: .semibold))
      Text(
        "Открывайте приложения и находите скопированное. Вернуться сюда можно через значок в строке меню, наведением к вырезу камеры или \(nativeShortcutLabel(model.settings.launcherShortcut))."
      ).font(.system(size: 12)).foregroundStyle(.secondary)
      HStack {
        NativeCommandButton(title: "Понятно", disabled: model.busy) {
          model.perform(
            NativeUICommand(
              "settings.set", strings: ["key": "shelfIntroduced"], bools: ["value": true]))
        }
        NativeCommandButton(title: "Настроить полку", shortcut: "⌘,", disabled: model.busy) {
          model.perform(NativeUICommand("shelf.settings"))
        }
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
      Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
  }
  private func group(_ result: NativeUISearchRow) -> String {
    result.kind == "calculation"
      ? "Калькулятор"
      : result.kind == "clip" || result.kind == "more-clips" || result.kind == "more-snippets"
        ? (result.snippet || result.kind == "more-snippets" ? "Сниппеты" : "Буфер обмена")
        : "Приложения"
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
      HStack {
        NativeIconButton(
          label: "Назад", symbol: "arrow.left", shortcut: model.draft != nil ? "esc" : "⌫",
          disabled: model.busy
        ) { model.back() }
        Text(
          model.draft != nil
            ? (model.draft!.id.isEmpty ? "Создать сниппет" : "Изменить сниппет")
            : isSnippets ? "Сниппеты" : "Буфер обмена"
        ).font(.system(size: 17, weight: .semibold))
        if model.settings.paused, !isSnippets {
          Text("Запись на паузе").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer()
        if isSnippets, model.draft == nil {
          NativeCommandButton(
            title: "Создать", symbol: "plus", shortcut: "⌘N",
            disabled: !model.writable || model.busy
          ) { model.createSnippet() }
        }
        if !isSnippets, model.draft == nil {
          Menu {
            Button("Копировать без вставки · ⇧↵") {
              if let clip = model.preview ?? model.selectedClip {
                model.chooseClip(clip, copyOnly: true)
              }
            }.disabled(model.selectedClip == nil || model.busy)
            Button("Очистить историю на всех связанных Mac… · ⌘⇧⌫") {
              model.showClearConfirmation()
            }.disabled(!model.writable || model.clips.isEmpty || model.busy)
          } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
          }.menuStyle(.borderlessButton).fixedSize()
        }
      }.padding(12)
      if model.draft == nil, model.previewID == nil, !model.confirmClear {
        NativeSearchField(
          text: $model.query,
          placeholder: isSnippets
            ? "Найти текст или название…" : "Найти текст, в том числе на изображениях…",
          focusToken: "\(model.destination)-\(model.visible)-list-\(model.sessionRevision)"
        ).frame(maxWidth: .infinity).frame(height: 44).padding(.horizontal, 12).padding(.bottom, 10)
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
      HStack {
        if model.draft != nil {
          Text("⌘↵ сохранить   esc отменить")
        } else if model.previewID != nil || model.confirmClear {
          Text("⌫ / esc вернуться к списку")
        } else {
          Text("↑ ↓ выбрать   ↵ \(model.canPaste ? "вставить" : "копировать")   esc закрыть")
          Spacer()
          Button("⌘↵ просмотр") { if let clip = model.selectedClip { model.openPreview(clip) } }
            .buttonStyle(.plain).disabled(model.selectedClip == nil || model.busy)
        }
      }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
    }.accessibilityIdentifier(isSnippets ? "native-snippets" : "native-clipboard")
  }
  private var editor: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Название (необязательно)").font(.system(size: 12))
      TextField(
        "",
        text: Binding(
          get: { model.draft?.name ?? "" },
          set: { model.draft?.name = nativeLimitedText($0, utf16Limit: 120) })
      ).textFieldStyle(.roundedBorder).focused($editorNameFocused).disabled(model.busy)
        .accessibilityIdentifier("snippet-name")
      Text("Текст").font(.system(size: 12))
      TextEditor(
        text: Binding(get: { model.draft?.content ?? "" }, set: { model.draft?.content = $0 })
      ).font(.system(size: 14)).padding(4).background(
        Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)
      ).disabled(model.busy).accessibilityIdentifier("snippet-content")
      Text(
        model.draft?.id.isEmpty == false
          ? "Одинаковый текст может быть у разных сниппетов."
          : "Сниппет будет сохранён отдельно от истории буфера."
      ).font(.system(size: 11)).foregroundStyle(.secondary)
      HStack {
        NativeCommandButton(
          title: "Сохранить", shortcut: "⌘↵",
          disabled: model.busy || !model.writable || model.draft?.content.isEmpty != false,
          prominent: true
        ) { model.saveSnippet() }.accessibilityIdentifier("snippet-save")
        NativeCommandButton(title: "Отмена", shortcut: "esc", disabled: model.busy) { model.back() }
        if model.busy { ProgressView().controlSize(.small) }
      }
    }.padding(14).onAppear { editorNameFocused = true }
  }
  private var confirmation: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Удалить историю на всех связанных Mac?").font(.system(size: 18, weight: .semibold))
      Text(
        "Закреплённые записи тоже будут удалены. Удаление передастся связанным Mac, в том числе после их подключения. Сниппеты и текущий буфер обмена останутся на месте."
      ).font(.system(size: 13)).foregroundStyle(.secondary)
      HStack {
        NativeCommandButton(
          title: "Удалить на всех связанных Mac", shortcut: "⌘↵",
          disabled: model.busy || !model.writable, destructive: true
        ) { model.clearHistory() }
        NativeCommandButton(title: "Отмена", shortcut: "esc", disabled: model.busy) { model.back() }
      }
      Spacer()
    }.padding(20).accessibilityIdentifier("clear-history-confirmation")
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
                  ? "История недоступна"
                  : !model.query.isEmpty
                    ? "Ничего не найдено"
                    : isSnippets ? "Сохраните готовый текст" : "Здесь появится скопированное"
              ).font(.system(size: 15, weight: .semibold))
              Text(
                model.storageStatus == "failed"
                  ? "Восстановите доступ к хранилищу и перезапустите Полку."
                  : !model.query.isEmpty
                    ? "Попробуйте другое слово."
                    : isSnippets
                      ? "Создайте сниппет для адреса, реквизитов или стандартного ответа."
                      : model.settings.paused
                        ? "Включите сохранение буфера обмена в настройках приложения."
                        : "Скопируйте текст или изображение в любой программе."
              ).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(32)
          }
          ForEach(Array(model.clipResults.enumerated()), id: \.element.id) { position, clip in
            HStack(spacing: 6) {
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
                          ? nativeClipboardSnippet(clip, query: model.query) : "Изображение")
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
                .accessibilityHint(position < 9 ? "Выбрать: ⌘\(position + 1)" : "Выбрать: Enter")
              if model.selectedClip?.id == clip.id {
                if clip.kind == "text" {
                  NativeIconButton(
                    label: clip.snippet ? "Изменить сниппет" : "Создать сниппет", symbol: "pencil",
                    shortcut: "⌘E",
                    disabled: !model.writable || model.busy
                      || !model.settings.builtinApps.allows(destination: "snippets")
                  ) { model.edit(clip) }
                }
                if clip.kind == "image" || nativeWebURL(clip.content) != nil {
                  NativeIconButton(
                    label: clip.kind == "image"
                      ? "Сохранить изображение…" : "Открыть ссылку в браузере",
                    symbol: clip.kind == "image" ? "arrow.down.to.line" : "arrow.up.right",
                    shortcut: clip.kind == "image"
                      ? "⌘S" + (position < 9 ? " / ⌘⌥\(position + 1)" : "")
                      : (position < 9 ? "⌘⌥\(position + 1)" : ""), disabled: model.busy
                  ) { model.secondaryClipAction(clip) }
                }
                NativeIconButton(
                  label: "Просмотреть запись", symbol: "eye", shortcut: "⌘↵", disabled: model.busy
                ) { model.openPreview(clip) }
                if !isSnippets {
                  NativeIconButton(
                    label: clip.pinned ? "Открепить" : "Закрепить",
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
                  label: "Удалить запись", symbol: "trash", shortcut: "⌘⌫",
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
        Text("Запускаем наблюдение за буфером обмена…")
        if model.settings.pasteOnSelect {
          Text(
            model.destination == "emoji"
              ? "Пока эмодзи только копируется — вставьте его ⌘V."
              : "Пока запись только копируется — вставьте её ⌘V.")
        }
      }.font(.system(size: 11)).foregroundStyle(.secondary).frame(
        maxWidth: .infinity, alignment: .leading
      ).padding(10)
    } else if model.settings.pasteOnSelect, model.pasteAccess != "granted" {
      HStack(alignment: .top) {
        Text(
          model.pasteAccess == "required"
            ? "Для автоматической вставки нужен Универсальный доступ. До разрешения используйте ⌘V."
            : "Автоматическая вставка недоступна. Запись можно скопировать и вставить через ⌘V."
        ).font(.system(size: 11)).foregroundStyle(.secondary)
        if model.pasteAccess == "required" {
          Button("Разрешить…") {
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
            ? "Хранилище синхронизации недоступно"
            : model.destination == "snippets" ? "Сниппеты недоступны" : "История буфера недоступна")
        Text(
          sync
            ? "Синхронизация остановлена. Локальная история и остальные функции Полки остаются доступны."
            : model.preferencesAvailable
              ? "Новые записи не сохраняются. Сохранённые записи можно просматривать и копировать. Синхронизация остановлена."
              : "Не удалось загрузить сохранённую историю и её настройки. Сохранение новых записей, наведение, сочетание истории и автоматическая вставка недоступны. Эмодзи можно копировать."
        ).font(.system(size: 11)).foregroundStyle(.secondary)
        Text(
          "Файл не сброшен. Восстановите доступ к хранилищу и перезапустите Полку. Перед заменой файла сохраните его зашифрованную копию."
        ).font(.system(size: 11)).foregroundStyle(.secondary)
        if ["decrypt", "encrypt"].contains(stage) {
          Text(
            "Если macOS запросит доступ к «polka Safe Storage», введите пароль связки «Вход» и выберите «Разрешать всегда»."
          ).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        DisclosureGroup("Подробности ошибки") {
          Text(diagnostic + (code.isEmpty ? "" : " · " + code)).font(.system(size: 11))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
        NativeCommandButton(title: "Показать файл в Finder", disabled: model.busy) {
          model.perform(
            NativeUICommand("clipboardHistory.revealStorage", strings: ["store": store]))
        }
      }.padding(.vertical, 8)
    }
  }
}
