import AppKit
import PolkaCore
import SwiftUI

let nativeSettingsPanes: [(id: String, label: String, icon: String)] = [
  ("general", "Основные", "slider.horizontal.3"), ("shelf", "Полка и сочетания", "command"),
  ("clipboard", "Буфер обмена", "clipboard"),
  ("builtin-apps", "Встроенные приложения", "square.grid.2x2"),
  ("about", "О приложении", "info.circle"),
]

struct NativeSettingsView: View {
  @ObservedObject var model: NativeUIModel
  private var pane: (id: String, label: String, icon: String) {
    nativeSettingsPanes.first { $0.id == model.settingsPane } ?? nativeSettingsPanes[0]
  }
  private var subtitle: String {
    switch model.settingsPane {
    case "builtin-apps": "Выберите приложения, которые нужны на полке."
    case "shelf": "Открытие полки, быстрые команды и индикаторы устройств."
    case "clipboard": "Сохранение, вставка и история на других Mac."
    case "about": "Версия приложения и обновления."
    default: "Запуск приложения и работа в фоне."
    }
  }
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Полка").font(.system(size: 18, weight: .semibold))
          Text("Настройки").font(.system(size: 12)).foregroundStyle(.secondary)
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
              Text("Открыть полку").font(.system(size: 12, weight: .medium))
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
      }.frame(width: 210).background(Color(nsColor: .windowBackgroundColor))
      Divider()
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
      NativeSettingsGroup("Приложения на полке") {
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
        "Изменения применяются сразу. Данные, настройки и черновики сохраняются; полка и настройки всегда доступны."
      )
      note(
        "При отключении истории новые копирования не сохраняются, распознавание изображений останавливается. После включения действует прежняя настройка сохранения. Синхронизация и срок хранения продолжают работать по своим настройкам в разделе «Буфер обмена»."
      )
      note(
        "Отключение сниппетов и эмодзи скрывает их команды; общие службы копирования и вставки остаются доступны другим приложениям. Отключение файлов убирает цель перетаскивания у верхнего края; ссылки на файлы сохраняются до выхода из Полки."
      )
    }
  }
  private var general: some View {
    VStack(alignment: .leading, spacing: 20) {
      NativeUpdateNotice(model: model)
      NativeSettingsGroup("Запуск и работа в фоне") {
        settingToggle(
          "Запускать при входе в macOS", detail: "В фоне, без открытия полки.",
          value: model.settings.login, enabled: !model.busy
        ) {
          model.perform(NativeUICommand("system.login", bools: ["enabled": $0]))
        }
      }
      note(
        "После закрытия окон Полка продолжает сохранять историю и реагировать на сочетания. Для выхода выберите «Выйти из Полки» в строке меню или нажмите ⌘Q."
      )
    }
  }
  private var shelf: some View {
    VStack(alignment: .leading, spacing: 20) {
      NativeSettingsGroup("Открытие полки") {
        settingToggle(
          "Открывать при наведении",
          detail:
            "Наведите указатель на вырез камеры или середину верхнего края экрана. Поиск сразу получит фокус.",
          value: model.settings.hoverEnabled, enabled: model.writable && !model.busy
        ) { model.preference("hoverEnabled", $0) }
        if !model.writable {
          note(
            "Восстановите доступ к хранилищу и перезапустите Полку, чтобы изменить эту настройку.")
        }
      }
      NativeSettingsGroup("Сочетание для запуска") {
        shortcutRow("Открыть полку", value: model.settings.launcherShortcut, disabled: model.busy) {
          model.perform(NativeUICommand("launcher.setShortcut", strings: ["accelerator": $0]))
        }
        NativeErrorNotice(text: model.settings.launcherShortcutError)
        HStack {
          NativeCommandButton(
            title: "Открыть полку", shortcut: nativeShortcutLabel(model.settings.launcherShortcut),
            disabled: model.busy
          ) { model.navigate("apps") }
          Spacer(minLength: 8)
          NativeCommandButton(
            title: "Отключить сочетание",
            disabled: model.busy || model.settings.launcherShortcut.isEmpty
          ) { model.perform(NativeUICommand("launcher.setShortcut", strings: ["accelerator": ""])) }
        }
      }
      NativeSettingsGroup("Индикаторы активности") {
        settingToggle("Камера", value: model.settings.cameraEnabled, enabled: !model.busy) {
          model.perform(
            NativeUICommand(
              "mediaIndicator.setTracking", strings: ["device": "camera"], bools: ["enabled": $0]))
        }
        Divider()
        settingToggle("Микрофон", value: model.settings.microphoneEnabled, enabled: !model.busy) {
          model.perform(
            NativeUICommand(
              "mediaIndicator.setTracking", strings: ["device": "microphone"],
              bools: ["enabled": $0]))
        }
        if !model.settings.mediaActivity.isEmpty { note(model.settings.mediaActivity) }
      }
      note(
        "Индикаторы видны у выреза камеры или в центре верхнего края. При демонстрации экрана они могут попасть в трансляцию; чтобы скрыть их, выключите оба."
      )
    }
  }
  private var clipboard: some View {
    VStack(alignment: .leading, spacing: 20) {
      NativeStorageNotice(model: model)
      NativeErrorNotice(text: model.helperError)
      if model.helperStatus == "starting" { note("Запускаем наблюдение за буфером…") }
      if !model.settings.builtinApps.allows(destination: "clipboard") {
        note(
          "История отключена в разделе «Встроенные приложения». Новые копирования не сохраняются, сочетание не активно. Настройки ниже сохраняются для повторного включения; синхронизация и срок хранения продолжают действовать."
        )
      }
      NativeSettingsGroup("Сохранение истории") {
        settingToggle(
          "Сохранять текст и изображения",
          detail:
            "До 200 записей и 128 МБ, локально в зашифрованном виде. Конфиденциальные и временные данные пропускаются, если программа пометила их.",
          value: !model.settings.paused, enabled: model.writable && !model.busy
        ) { model.preference("paused", !$0) }
        Divider()
        HStack(spacing: 12) {
          Text("Хранить незакреплённые записи").font(.system(size: 13))
          Spacer(minLength: 8)
          Picker(
            "Хранить незакреплённые записи",
            selection: Binding(
              get: { model.settings.retentionDays },
              set: {
                model.perform(
                  NativeUICommand("clipboardHistory.preferences", ints: ["retentionDays": $0]))
              })
          ) {
            Text("1 день").tag(1)
            Text("7 дней").tag(7)
            Text("30 дней").tag(30)
          }.labelsHidden().frame(width: 112).disabled(!model.writable || model.busy)
        }
        note("Закреплённые записи сохраняются дольше выбранного срока.")
      }
      NativeSettingsGroup("Выбор записи") {
        settingToggle(
          "Вставлять в предыдущее поле",
          detail: model.settings.pasteOnSelect
            ? "Enter вставляет выбранную запись. ⇧Enter только копирует её."
            : "Выбранная запись только копируется. Вставьте её вручную через ⌘V.",
          value: model.settings.pasteOnSelect, enabled: model.writable && !model.busy
        ) { model.preference("pasteOnSelect", $0) }
        if model.settings.pasteOnSelect {
          Divider()
          if model.pasteAccess == "granted" {
            note("Универсальный доступ разрешён.")
          } else {
            note(
              model.pasteAccess == "required"
                ? "Для вставки разрешите Универсальный доступ в настройках macOS. Пока можно копировать и вставлять вручную через ⌘V."
                : "Не удалось проверить разрешение macOS. Пока можно копировать и вставлять вручную через ⌘V."
            )
            if model.pasteAccess == "required" {
              NativeCommandButton(
                title: "Разрешить автоматическую вставку…", disabled: !model.writable || model.busy
              ) { model.perform(NativeUICommand("clipboardHistory.requestPasteAccess")) }
            }
          }
        }
      }
      NativeSettingsGroup("Сочетание для истории") {
        NativeErrorNotice(text: model.settings.clipboardShortcutError)
        shortcutRow(
          "Открыть историю", value: model.settings.clipboardShortcut,
          disabled: !model.writable || model.busy
        ) {
          model.perform(NativeUICommand("clipboardHistory.shortcut", strings: ["accelerator": $0]))
        }
        HStack {
          NativeCommandButton(
            title: "Открыть историю",
            shortcut: nativeShortcutLabel(model.settings.clipboardShortcut),
            disabled: model.busy || !model.settings.builtinApps.allows(destination: "clipboard")
          ) { model.perform(NativeUICommand("clipboardHistory.show")) }
          Spacer(minLength: 8)
          NativeCommandButton(
            title: "Отключить сочетание",
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
    NativeSettingsGroup("История на других Mac") {
      settingToggle(
        "Синхронизировать по локальной сети",
        detail:
          "Текст, изображения, закрепление и удаление передаются напрямую между связанными Mac. Текущий буфер обмена не меняется.",
        value: model.settings.syncEnabled, enabled: syncAvailable && !model.busy
      ) { model.perform(NativeUICommand("clipboardHistory.syncEnabled", bools: ["enabled": $0])) }
      if model.settings.syncStatus == "starting" { note("Загрузка настроек синхронизации…") }
      if model.settings.syncStatus == "blocked" {
        NativeErrorNotice(text: "Синхронизация остановлена: хранилище истории недоступно.")
      }
      NativeStorageNotice(model: model, store: "sync")
      NativeErrorNotice(text: model.settings.syncError)
      if model.settings.syncEnabled, syncAvailable {
        Divider()
        note(
          "Этот Mac: \(model.settings.deviceName). При первом соединении и после перерыва объединяется вся сохранённая история. Срок хранения остаётся отдельным на каждом Mac."
        )
        if model.settings.paused {
          note(
            "Сохранение истории на паузе. Синхронизация продолжится, когда вы включите сохранение.")
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
                    ? "На паузе"
                    : peer.status == "syncing"
                      ? "Синхронизация…"
                      : peer.status == "connected" ? "История синхронизирована" : "Нет соединения"
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
            NativeCommandButton(title: "Отвязать", shortcut: "⌘⌥⌫", disabled: model.busy) {
              model.selectedPeerID = peer.id
              model.perform(
                NativeUICommand("clipboardHistory.syncForget", strings: ["id": peer.id]))
            }
          }
        }
        if !model.settings.peers.isEmpty {
          NativeCommandButton(
            title: "Синхронизировать сейчас", disabled: model.busy || model.settings.paused
          ) { model.perform(NativeUICommand("clipboardHistory.syncNow")) }
        }
        if !model.settings.invitation.isEmpty {
          Text("Код для другого Mac").font(.system(size: 12, weight: .medium))
          Text(model.settings.invitation).font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
          note(
            "На другом Mac включите синхронизацию и вставьте этот код. Он действует 5 минут и связывает одно устройство. Передавайте его только своему Mac."
          )
          HStack {
            NativeCommandButton(title: "Скопировать код", disabled: model.busy) {
              model.perform(NativeUICommand("clipboardHistory.copyPairingCode"))
            }
            NativeCommandButton(title: "Отменить код", disabled: model.busy) {
              model.perform(NativeUICommand("clipboardHistory.syncCancelInvite"))
            }
          }
        } else {
          NativeCommandButton(
            title: "Получить код для другого Mac", shortcut: "⌘⇧N", disabled: model.busy
          ) { model.perform(NativeUICommand("clipboardHistory.syncInvite")) }
        }
        Text("Код с другого Mac").font(.system(size: 12, weight: .medium))
        TextEditor(text: $model.pairingCode).font(.system(size: 11, design: .monospaced)).frame(
          height: 75
        ).padding(4).background(
          Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)
        ).disabled(model.busy).accessibilityIdentifier("sync-pairing-code")
        NativeCommandButton(
          title: "Связать Mac и объединить историю", shortcut: "⌘↵",
          disabled: model.busy
            || model.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          prominent: true
        ) { model.pairMac() }
        note(
          model.settings.nearby.isEmpty
            ? "Другие Mac пока не найдены. Включите синхронизацию на втором Mac и проверьте, что оба подключены к одной сети."
            : "Другие Mac в сети: " + model.settings.nearby.joined(separator: ", "))
      }
    }
  }
  private var syncAvailable: Bool {
    model.settings.syncStorageStatus == "ready"
      && !["blocked", "starting"].contains(model.settings.syncStatus)
  }
  private var about: some View {
    VStack(alignment: .leading, spacing: 20) {
      NativeSettingsGroup("Полка") {
        note("Приложения и история буфера обмена — на одной полке.")
        NativeUpdatesView(model: model)
      }
      note("История хранится локально в зашифрованном виде.")
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
      Text("Обновления").font(.system(size: 17, weight: .semibold))
      Text(
        model.settings.currentVersion.isEmpty
          ? "Загрузка версии…" : "Полка \(model.settings.currentVersion)"
      ).font(.system(size: 12)).foregroundStyle(.secondary)
      if !model.settings.updateMessage.isEmpty {
        Text(model.settings.updateMessage).font(.system(size: 12)).foregroundStyle(
          model.settings.updateStatus == "error" ? .red : .secondary
        ).textSelection(.enabled)
      }
      if model.settings.updateStatus != "unavailable" {
        Text("Обновления проверяются и загружаются автоматически. Установка — после подтверждения.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if model.settings.updateStatus == "current" {
        Text("Установлена последняя версия.").font(.system(size: 13))
      }
      if !model.settings.updateVersion.isEmpty {
        Text(
          "\(model.settings.updateStatus == "ready" ? "Готова к установке" : "Доступна версия") \(model.settings.updateVersion)"
        ).font(.system(size: 13))
      }
      if model.settings.updateNotification == "skipped" {
        Text("Вы пропустили эту версию. Её можно установить здесь.").font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      if model.settings.updateNotification == "deferred" {
        Text(
          "Напомним \(nativeClipDate(model.settings.updateRemindAfter)). Можно обновиться сейчас."
        ).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if model.settings.updateStatus == "downloading" {
        ProgressView(value: model.settings.updateProgress, total: 100)
        Text("Загружено \(Int(model.settings.updateProgress))%").font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      if model.settings.updateStatus == "ready" {
        Text("Приложение перезапустится для установки обновления.").font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      if ["idle", "current", "error", "checking"].contains(model.settings.updateStatus) {
        NativeCommandButton(
          title: model.settings.updateStatus == "checking" ? "Проверяем…" : "Проверить обновления",
          shortcut: "⌘R", disabled: model.busy || model.settings.updateStatus == "checking"
        ) { model.perform(NativeUICommand("updates.check")) }
      }
      if ["ready", "installing"].contains(model.settings.updateStatus) {
        NativeCommandButton(
          title: "Установить и перезапустить", shortcut: "⌘⇧U",
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
          Text("Доступна Полка \(model.settings.updateVersion)").font(
            .system(size: 13, weight: .semibold))
          Spacer()
          Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        HStack(spacing: 5) {
          NativeCommandButton(
            title: model.settings.updateStatus == "error"
              ? "Повторить проверку" : "Обновить и перезапустить",
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
            title: "Завтра", disabled: model.busy || model.settings.updateStatus == "installing"
          ) {
            model.perform(NativeUICommand("updates.remind", strings: ["version": displayedVersion]))
          }
          NativeCommandButton(
            title: "Пропустить", disabled: model.busy || model.settings.updateStatus == "installing"
          ) {
            model.perform(NativeUICommand("updates.skip", strings: ["version": displayedVersion]))
          }
          NativeCommandButton(title: "Что нового", disabled: model.busy) {
            model.perform(NativeUICommand("shelf.settings", strings: ["section": "about"]))
          }
        }
      }.padding(10).background(
        Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
  }
  private var status: String {
    switch model.settings.updateStatus {
    case "installing": return "Устанавливаем…"
    case "checking": return "Проверяем…"
    case "downloading": return "Загружаем… \(Int(model.settings.updateProgress))%"
    case "ready": return "Готова к установке"
    default: return "Ошибка обновления"
    }
  }
}

/// A native source list owns Up/Down/Home/End and VoiceOver selection. Keeping
/// the sidebar in AppKit avoids requiring pointer input to change settings tabs.
struct NativeSettingsSidebar: NSViewRepresentable {
  @ObservedObject var model: NativeUIModel
  func makeCoordinator() -> Coordinator { Coordinator(model) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.contentView.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
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
    table.setAccessibilityLabel("Разделы настроек")
    scroll.documentView = table
    context.coordinator.table = table
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.model = model
    let index = nativeSettingsPanes.firstIndex { $0.id == model.settingsPane } ?? 0
    if context.coordinator.table?.selectedRow != index {
      context.coordinator.table?.selectRowIndexes(
        IndexSet(integer: index), byExtendingSelection: false)
    }
    context.coordinator.synchronizeCells()
  }
  @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var model: NativeUIModel
    weak var table: NSTableView?
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
      cell.textField?.textColor = .labelColor
      cell.imageView?.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
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
    NSColor.controlAccentColor.withAlphaComponent(contrast ? 0.25 : 0.13).setFill()
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
  @State private var language = "ru"
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Что нового").font(.system(size: 15, weight: .semibold))
        Spacer()
        Picker("Язык примечаний к выпуску", selection: $language) {
          Text("Русский").tag("ru")
          Text("English").tag("en")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 180).accessibilityLabel(
          "Язык примечаний к выпуску")
      }
      // Release notes are plain text, including any HTML-like characters.
      Text(nativeReleaseNoteText(settings, language: language)).font(.system(size: 13))
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
    ? "Для этого выпуска примечания не опубликованы."
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
    button.controlSize = .small
    button.setAccessibilityLabel(title)
    button.state = enabled ? .on : .off
    button.setAvailable(model.canChangeBuiltinApps, focusRevision: model.settingsFocusRevision)
    button.setAccessibilityIdentifier("builtin-app-toggle-" + appID)
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
