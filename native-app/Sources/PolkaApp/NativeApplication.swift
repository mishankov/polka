import AppKit
import Carbon
import Combine
import CryptoKit
import Darwin
import PolkaCore
import SwiftUI

final class ShelfPanel: NSPanel {
  weak var dropModel: NativeUIModel?
  var dropTrace: ((String, NSDraggingInfo) -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// A hide request can reach WindowServer after a new show has already observed
/// the old active state. Only the subsequent activation notification completes
/// that transition; property snapshots and event-loop delays cannot do so.
struct NativeShelfActivationTransition {
  enum State: Equatable {
    case idle, hidden
    case awaiting(Int)
  }
  private(set) var state: State = .idle
  mutating func willHide() { state = .hidden }
  mutating func requestFocus(revision: Int) {
    if state != .idle { state = .awaiting(revision) }
  }
  mutating func cancel() { state = .idle }
  func ignoresTransientLoss(revision: Int, anotherKeyWindow: Bool, outsideClick: Bool) -> Bool {
    state == .awaiting(revision) && !anotherKeyWindow && !outsideClick
  }
}

@MainActor
final class NativeApplication: NSObject, NSApplicationDelegate, NSWindowDelegate,
  NSMenuItemValidation
{
  let model = NativeUIModel()
  var platform: NativePlatform!
  private var shelf: ShelfPanel!
  private var settingsWindow: NSWindow?
  private var tray: NSStatusItem?
  private let lifecycle = ShelfLifecycle()
  private var activationTransition = NativeShelfActivationTransition()
  private let hover = ShelfHover()
  private var hoverTimer: Timer?
  private var observer: NSObjectProtocol?
  private var media: NativeMediaMonitor?
  private var mediaPreviewWindow: NSWindow?
  private var openedByHover = false
  private var incomingDrag = false
  private var incomingCount = 0
  private var incomingEndDeferred = false
  private var incomingEndTask: Task<Void, Never>?
  private var terminating = false
  private var shutdownFinished = false
  private var lockFD: Int32 = -1
  private var subscriptions = Set<AnyCancellable>()
  private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
  private var suspensions = Set<String>()
  private var fixtureTimer: Timer?
  private var fixtureCommandID = ""
  private var fixtureCommandBusy = false
  private var presentationScreen: NSScreen?
  private var outsideClickMonitor: Any?
  private var quitKeyMonitor: Any?
  private let fixture = NativeProfile.isolatedFixture
  private(set) var smokeLifecycleTrace: [String] = []
  private func traceLifecycle(_ event: String) {
    guard fixture else { return }
    smokeLifecycleTrace.append(
      "\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(event) r=\(lifecycle.revision) phase=\(lifecycle.phase) activation=\(activationTransition.state) visible=\(model.visible) key=\(shelf?.isKeyWindow ?? false) active=\(NSApp.isActive) hidden=\(NSApp.isHidden) keyWindow=\(NSApp.keyWindow?.identifier?.rawValue ?? "nil")"
    )
    if smokeLifecycleTrace.count > 80 { smokeLifecycleTrace.removeFirst() }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    if ProcessInfo.processInfo.environment["POLKA_NATIVE_FIXTURE"] == "1", !fixture {
      fputs(
        "Native fixture requires a disposable profile inside the temporary directory.\n", stderr)
      requestQuit()
      return
    }
    do {
      let root = NativeProfile.path()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      lockFD = open(
        root.appendingPathComponent("native-instance.lock").path, O_CREAT | O_RDWR, 0o600)
      guard lockFD >= 0 else {
        throw PolkaCoreError.storage("Не удалось открыть блокировку профиля")
      }
      let instanceName = Notification.Name(
        "app.polka.native.open."
          + SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined())
      if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        DistributedNotificationCenter.default().postNotificationName(
          instanceName, object: nil, userInfo: nil, deliverImmediately: true)
        close(lockFD)
        lockFD = -1
        NSApp.terminate(nil)
        return
      }
      let distributed = DistributedNotificationCenter.default()
      notifications.append(
        (
          distributed,
          distributed.addObserver(forName: instanceName, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in await self?.show(nil) }
          }
        ))
      let blockedStartup = fixture && CommandLine.arguments.contains("--native-startup-close-smoke")
      platform = try NativePlatform(
        model: model, root: root, fixture: fixture,
        encryption: blockedStartup ? NativeSmokeBlockedEncryption() : nil)
      platform.show = { [weak self] destination, query in
        await self?.show(destination, query: query)
      }
      platform.hide = { [weak self] cancel in self?.hide(cancelPaste: cancel, force: true) }
      platform.openSettings = { [weak self] pane in self?.openSettings(pane) }
      platform.currentPanel = { [weak self] in self?.shelf }
      platform.showIncomingFiles = { [weak self] in
        guard let self, platform.builtinApps.allows(destination: "files") else { return }
        // The helper can emit enter from both its strip and its polling timer.
        // Preserve the current presentation and any provider already decoding.
        if lifecycle.requested && (incomingDrag || model.destination == "files") {
          if incomingEndDeferred && NSEvent.pressedMouseButtons & 1 != 0 {
            cancelIncomingEnd()
            incomingEndDeferred = false
          }
          return
        }
        cancelIncomingEnd()
        incomingDrag = true
        incomingEndDeferred = false
        incomingCount = platform.files.items.count
        await show("files", byHover: false, drag: true)
      }
      platform.endIncomingFiles = { [weak self] in
        guard let self else { return }
        guard incomingDrag || incomingEndDeferred else { return }
        cancelIncomingEnd()
        incomingEndDeferred = true
        let revision = lifecycle.revision
        // Mouse release is observed by another process. Its IPC can beat the
        // AppKit drop callback, so retain the shelf through a short release grace period.
        incomingEndTask = Task { @MainActor [weak self] in
          do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
          guard let self, lifecycle.revision == revision, incomingEndDeferred else { return }
          incomingEndTask = nil
          if !model.incomingFileDropPending { finishIncomingFiles() }
        }
      }
      platform.filesDropped = { [weak self] in
        guard let self, !terminating, platform.builtinApps.allows(destination: "files") else {
          return
        }
        cancelIncomingEnd()
        incomingDrag = false
        incomingEndDeferred = false
        model.incomingFileDropTargeted = false
        if model.destination != "files" || !lifecycle.requested {
          await show("files")
        } else {
          NSApp.activate(ignoringOtherApps: true)
          shelf.makeKeyAndOrderFront(nil)
          shelf.makeFirstResponder(nil)
        }
      }
      installMenus()
      makeShelf()
      // Keep the app-wide menu command available with non-Latin layouts and
      // while a sheet owns input. Shortcut recording and IME retain their keys.
      quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let responder = (event.window ?? NSApp.keyWindow)?.firstResponder
        guard event.keyCode == 12,
          event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
          !(responder is NativeShortcutCaptureView),
          !((responder as? NSTextView)?.hasMarkedText() ?? false),
          !NSMenuTrackingState.shared.active
        else { return event }
        if !event.isARepeat { self?.quitAction() }
        return nil
      }
      outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
      ]) { [weak self] _ in
        MainActor.assumeIsolated { self?.dismissForFocusLoss(reason: "outside-click") }
      }
      model.$previewID.combineLatest(model.$draft.map { $0 != nil }.removeDuplicates()).sink {
        [weak self] _ in
        DispatchQueue.main.async {
          guard let self, self.lifecycle.requested else { return }
          self.geometry()
        }
      }.store(in: &subscriptions)
      model.$query.removeDuplicates().sink { [weak self] _ in
        self?.platform.anchorCalculationDate()
      }.store(in: &subscriptions)
      model.$incomingFileDropPending.removeDuplicates().sink { [weak self] pending in
        guard !pending else { return }
        DispatchQueue.main.async {
          guard let self, self.incomingEndDeferred, self.incomingEndTask == nil,
            !self.model.incomingFileDropPending
          else { return }
          self.finishIncomingFiles()
        }
      }.store(in: &subscriptions)
      media = NativeMediaMonitor(settings: platform.settings, model: model, fixture: fixture)
      platform.mediaTracking = { [weak self] device, enabled in
        try self?.media?.set(device, enabled: enabled)
      }
      installPowerObservers()
      observer = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
      hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.stepHover() }
      }
      Task {
        await platform.initialize()
        // Demonstrate the real overlays without probing or activating devices.
        if fixture, ProcessInfo.processInfo.environment["POLKA_NATIVE_MEDIA_DEMO"] == "1" {
          _ = media?.showFixture(.init(camera: "active", microphone: "active"))
        }
        if let update = NativeProfile.update {
          await platform.waitForInitialization()
          if update.mode == "updates" {
            self.startUpdateFixtureDriver(update)
          } else {
            self.writeUpdateReceipt(update)
            self.requestQuit()
          }
          return
        }
        if !CommandLine.arguments.contains("--hidden") && !self.launchedAtLogin { await show(nil) }
        if fixture, ProcessInfo.processInfo.environment["POLKA_NATIVE_MEDIA_PREVIEW"] == "1" {
          mediaPreviewWindow = nativeMediaGlassPreviewWindow()
        }
        if CommandLine.arguments.contains("--native-smoke") { await smoke() }
        if CommandLine.arguments.contains("--native-settings-smoke") {
          await smoke(settingsOnly: true)
        }
        if CommandLine.arguments.contains("--native-scroll-smoke") { await scrollSmoke() }
        if CommandLine.arguments.contains("--native-startup-close-smoke") {
          await startupCloseSmoke()
        }
        if CommandLine.arguments.contains("--native-notice-quit-smoke") { await noticeQuitSmoke() }
        if fixture, CommandLine.arguments.contains("--native-file-drop-smoke"),
          let path = ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_RESULT"]
        {
          await platform.waitForInitialization()
          let result = await nativeFileDropSmoke(application: self, shelf: shelf, model: model)
          if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
          {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
          }
          nativeSmokePostQuit(shelf)
        }
        if fixture, CommandLine.arguments.contains("--native-external-file-drop-smoke"),
          let path = ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_RESULT"]
        {
          await platform.waitForInitialization()
          let result = await nativeExternalFileDropSmoke(
            application: self, shelf: shelf, model: model, platform: platform)
          if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
          {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
          }
          nativeSmokePostQuit(shelf)
        }
      }
    } catch {
      let alert = NSAlert()
      alert.messageText = "Не удалось запустить Полку"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      NSApp.terminate(nil)
    }
  }
  private func makeShelf() {
    shelf = ShelfPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
      styleMask: [.borderless], backing: .buffered, defer: false)
    shelf.identifier = NSUserInterfaceItemIdentifier("polka-shelf")
    // Destinations create their native controls after the panel is already
    // open. Keep Tab navigation current as SwiftUI changes the view tree.
    shelf.autorecalculatesKeyViewLoop = true
    shelf.title = "Полка"
    shelf.delegate = self
    shelf.isReleasedWhenClosed = false
    shelf.hidesOnDeactivate = false
    shelf.isFloatingPanel = true
    // The content fills the notch with opaque black. The window itself remains
    // nonopaque so the rounded bottom corners can reveal the desktop.
    shelf.backgroundColor = .clear
    shelf.isOpaque = false
    // The system shadow adds a closed keyline across the hardware notch.
    // NativeShelfPresentationView draws only the sides and bottom instead.
    shelf.hasShadow = false
    shelf.level = .statusBar
    shelf.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    shelf.contentView = NativeShelfPresentationView(model: model)
    shelf.dropModel = model
    shelf.registerForDraggedTypes([.fileURL])
  }
  private func installMenus() {
    NSApp.mainMenu = makeMainMenu()
    installTrayMenu()
  }
  // Constructing the menu does not install global shortcuts, a status item, or
  // platform services. Tests can inspect its native responder-chain contracts.
  func makeMainMenu() -> NSMenu {
    let menu = NSMenu()
    let appItem = NSMenuItem(title: "Полка", action: nil, keyEquivalent: "")
    let appMenu = NSMenu(title: "Полка")
    appMenu.addItem(withTitle: "Настройки…", action: #selector(settingsAction), keyEquivalent: ",")
      .target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Скрыть Полку", action: #selector(hideApplicationAction(_:)), keyEquivalent: "h"
    ).target = self
    let hideOthers = appMenu.addItem(
      withTitle: "Скрыть остальные", action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    hideOthers.target = NSApp
    appMenu.addItem(
      withTitle: "Показать все", action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: ""
    ).target = NSApp
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Выйти из Полки", action: #selector(quitAction), keyEquivalent: "q")
      .target = self
    appItem.submenu = appMenu
    menu.addItem(appItem)
    let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
    let edit = NSMenu(title: "Правка")
    for (title, action, key) in [
      ("Отменить", Selector(("undo:")), "z"),
      ("Повторить", Selector(("redo:")), "Z"), ("Вырезать", #selector(NSText.cut(_:)), "x"),
      ("Копировать", #selector(NSText.copy(_:)), "c"),
      ("Вставить", #selector(NSText.paste(_:)), "v"),
      ("Выбрать всё", #selector(NSText.selectAll(_:)), "a"),
    ] {
      let item = edit.addItem(withTitle: title, action: action, keyEquivalent: key)
      if action == Selector(("redo:")) { item.keyEquivalentModifierMask = [.command, .shift] }
    }
    editItem.submenu = edit
    menu.addItem(editItem)
    let windowItem = NSMenuItem(title: "Окно", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Окно")
    windowMenu.addItem(
      withTitle: "Закрыть окно", action: #selector(closeWindowAction(_:)), keyEquivalent: "w"
    ).target = self
    windowItem.submenu = windowMenu
    menu.addItem(windowItem)
    return menu
  }
  private func installTrayMenu() {
    tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let url = Bundle.main.url(forResource: "polkaTemplate", withExtension: "png"),
      let image = NSImage(contentsOf: url)
    {
      image.isTemplate = true
      tray?.button?.image = image
    } else {
      tray?.button?.title = "П"
    }
    let trayMenu = NSMenu()
    for (title, action) in [
      ("Открыть полку", #selector(shelfAction)),
      ("История буфера обмена", #selector(historyAction)), ("Сниппеты", #selector(snippetsAction)),
      ("Файлы на полке", #selector(filesAction)), ("Настройки…", #selector(settingsAction)),
      ("О приложении и обновления", #selector(aboutAction)),
    ] { trayMenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
    trayMenu.addItem(.separator())
    trayMenu.addItem(withTitle: "Выйти из Полки", action: #selector(quitAction), keyEquivalent: "q")
      .target = self
    tray?.menu = trayMenu
  }
  @objc private func shelfAction() { Task { await show(nil) } }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    Task { await show(nil) }
    return false
  }
  @objc private func historyAction() { Task { await show("clipboard") } }
  @objc private func snippetsAction() { Task { await show("snippets") } }
  @objc private func filesAction() { Task { await show("files") } }
  @objc private func settingsAction() { openSettings(nil) }
  @objc private func aboutAction() { openSettings("about") }
  @objc private func quitAction() { requestQuit() }
  @objc private func closeWindowAction(_ sender: Any?) {
    guard !model.busy, NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else {
      return
    }
    if NSApp.keyWindow === shelf {
      model.closeShelf()
    } else {
      NSApp.keyWindow?.performClose(sender)
    }
  }
  @objc private func hideApplicationAction(_ sender: Any?) {
    guard !model.busy, NSApp.modalWindow == nil,
      !NSApp.windows.contains(where: { $0.attachedSheet != nil })
    else { return }
    // Finish ordering out while the app is still active. Delaying it until
    // after NSApp.hide can leave AppKit retaining a non-key panel as keyWindow,
    // making subsequent makeKeyAndOrderFront calls ineffective on unhide.
    platform?.cancelPaste()
    hide(cancelPaste: false)
    NSApp.hide(sender)
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let destinations: [Selector: String] = [
      #selector(historyAction): "clipboard", #selector(snippetsAction): "snippets",
      #selector(filesAction): "files",
    ]
    if let destination = item.action.flatMap({ destinations[$0] }) {
      return model.settings.builtinApps.allows(destination: destination) && !model.busy
        && NSApp.modalWindow == nil && !NSApp.windows.contains { $0.attachedSheet != nil }
    }
    if item.action == #selector(closeWindowAction(_:)) {
      return !model.busy && NSApp.modalWindow == nil && NSApp.keyWindow != nil
        && NSApp.keyWindow?.attachedSheet == nil
    }
    if item.action == #selector(hideApplicationAction(_:)) {
      return !model.busy && NSApp.modalWindow == nil
        && !NSApp.windows.contains(where: { $0.attachedSheet != nil })
    }
    return true
  }
  func requestQuit() {
    activationTransition.cancel()
    // AppKit may reject terminate before calling the delegate while a sheet is
    // open. Cancel it first, then leave the current event/actor task before quit.
    DispatchQueue.main.async {
      for window in NSApp.windows {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
      }
      NSApp.terminate(nil)
    }
  }
  private func screen() -> NSScreen {
    NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen
      .main ?? NSScreen.screens[0]
  }
  private func geometry() {
    let screen = presentationScreen ?? screen()
    let expanded = model.previewID != nil || model.draft != nil
    // Every shelf destination, preview and editor shares the launcher's width.
    let width = min(CGFloat(560), screen.frame.width)
    let top = screen.safeAreaInsets.top
    let center =
      (screen.auxiliaryTopLeftArea.flatMap { left in
        screen.auxiliaryTopRightArea.map { (left.maxX + $0.minX) / 2 }
      }) ?? screen.frame.midX
    let height = min((expanded ? CGFloat(680) : 510) + top, screen.frame.height)
    if model.topInset != top { model.topInset = top }
    let frame = NSRect(
      x: max(screen.frame.minX, min(screen.frame.maxX - width, center - width / 2)),
      y: screen.frame.maxY - height, width: width, height: height)
    if shelf.frame != frame { shelf.setFrame(frame, display: true) }
  }
  func show(_ requested: String?, query: String = "", byHover: Bool = false, drag: Bool = false)
    async
  {
    let destination = requested == "toggle-clipboard" ? "clipboard" : requested
    if let destination, !platform.builtinApps.allows(destination: destination) { return }
    let navigationCommands: Set<String> = [
      "launcher.show", "launcher.openMac", "clipboardHistory.show", "shelf.showSnippets",
      "shelf.showEmoji", "shelf.showFiles", "shelf.files.add", "builtinApps.setEnabled",
    ]
    guard
      !model.busy || model.pendingCommand.map(navigationCommands.contains) == true
        || (requested == "files" && model.incomingFileDropPending)
    else { return }
    if requested == "toggle" || requested == "toggle-clipboard" {
      let destination = requested == "toggle-clipboard" ? "clipboard" : nil
      if lifecycle.requested && (destination == nil || model.destination == destination) {
        hide(force: true)
        return
      }
      await show(destination, query: query)
      return
    }
    guard !terminating, suspensions.isEmpty, NSApp.modalWindow == nil, shelf.attachedSheet == nil
    else { return }
    if !drag {
      cancelIncomingEnd()
      incomingEndDeferred = false
    }
    var (entry, newSession) = lifecycle.begin(
      requested.flatMap(ShelfDestination.init(rawValue:)), now: Date().timeIntervalSince1970 * 1000,
      query: query)
    if !platform.builtinApps.allows(destination: entry.destination.rawValue) {
      (entry, _) = lifecycle.begin(.apps, now: Date().timeIntervalSince1970 * 1000)
    }
    if drag {
      activationTransition.cancel()
    } else {
      activationTransition.requestFocus(revision: entry.revision)
    }
    if newSession { await platform.beginSession() }
    guard lifecycle.requested, lifecycle.revision == entry.revision,
      platform.builtinApps.allows(destination: entry.destination.rawValue)
    else { return }
    model.present(
      destination: entry.destination.rawValue, resume: entry.resumes,
      searchQuery: entry.resumes ? nil : query)
    if entry.destination == .apps, !newSession { Task { try? await platform.refreshCatalog() } }
    openedByHover = byHover
    incomingDrag = drag
    if !drag { incomingEndDeferred = false }
    presentationScreen = screen()
    geometry()
    (shelf.contentView as? NativeShelfPresentationView)?.setPresented(
      true, topInset: model.topInset)
    lifecycle.commit(entry.revision)
    traceLifecycle("show-\(entry.destination.rawValue)")
    if drag {
      shelf.orderFrontRegardless()
    } else {
      NSApp.activate(ignoringOtherApps: true)
      shelf.makeKeyAndOrderFront(nil)
      if entry.destination == .files { shelf.makeFirstResponder(nil) }
      // Hiding/unhiding an accessory app completes asynchronously. Its pending
      // activation can clear a key-window request made in this same turn.
      let revision = entry.revision
      DispatchQueue.main.async { [weak self] in
        guard let self, self.lifecycle.revision == revision else { return }
        self.focusPresentedShelf()
      }
    }
  }
  private func finishIncomingFiles() {
    cancelIncomingEnd()
    incomingDrag = false
    incomingEndDeferred = false
    model.incomingFileDropTargeted = false
    if platform.files.items.count == incomingCount { hide() }
  }
  private func cancelIncomingEnd() {
    incomingEndTask?.cancel()
    incomingEndTask = nil
  }
  func hide(cancelPaste: Bool = true, force: Bool = false, reason: String = "command") {
    guard shelf != nil, shelf.attachedSheet == nil else { return }
    if model.busy && cancelPaste && !force { return }
    activationTransition.cancel()
    guard lifecycle.close(now: Date().timeIntervalSince1970 * 1000) else { return }
    traceLifecycle("hide-\(reason)")
    cancelIncomingEnd()
    incomingDrag = false
    incomingEndDeferred = false
    model.incomingFileDropTargeted = false
    if cancelPaste { platform?.cancelPaste() }
    model.conceal()
    (shelf.contentView as? NativeShelfPresentationView)?.setPresented(
      false, topInset: model.topInset, animated: cancelPaste)
    let revision = lifecycle.revision
    hover.dismiss()
    if !cancelPaste {
      shelf.orderOut(nil)
      lifecycle.finishClose(revision)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + NativeShelfPresentationView.closingDuration) {
      [weak self] in
      guard let self, self.lifecycle.revision == revision, !self.lifecycle.requested else { return }
      self.shelf.orderOut(nil)
      self.lifecycle.finishClose(revision)
    }
  }
  func openSettings(_ pane: String?) {
    guard !model.busy || model.pendingCommand == "shelf.settings", NSApp.modalWindow == nil,
      !NSApp.windows.contains(where: { $0.attachedSheet != nil })
    else { return }
    activationTransition.cancel()
    hide(force: true)
    if let pane { model.settingsPane = pane }
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
        defer: false)
      window.identifier = NSUserInterfaceItemIdentifier("polka-settings")
      window.title = "Настройки — Полка"
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.titlebarSeparatorStyle = .none
      window.minSize = NSSize(width: 660, height: 480)
      window.isReleasedWhenClosed = false
      window.center()
      window.contentView = NSHostingView(rootView: NativeSettingsView(model: model))
      settingsWindow = window
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }
  func windowDidResignKey(_ notification: Notification) {
    guard (notification.object as? NSWindow) === shelf else { return }
    let revision = lifecycle.revision
    traceLifecycle("schedule-key-loss")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.lifecycle.revision == revision, !self.shelf.isKeyWindow else {
        self.traceLifecycle("skip-key-loss-\(revision)")
        return
      }
      self.dismissForFocusLoss(reason: "key-loss")
    }
  }
  func applicationDidResignActive(_ notification: Notification) {
    // A rapid Hide/unhide can enqueue this notification before a new
    // presentation, then deliver it after the application is active again.
    let revision = lifecycle.revision
    traceLifecycle("schedule-app-loss")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.lifecycle.revision == revision, !NSApp.isActive else {
        self.traceLifecycle("skip-app-loss-\(revision)")
        return
      }
      self.dismissForFocusLoss(reason: "app-loss")
    }
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    activationTransition.cancel()
    traceLifecycle("app-active")
    focusPresentedShelf()
  }
  func applicationWillHide(_ notification: Notification) {
    activationTransition.willHide()
    traceLifecycle("app-will-hide")
  }
  private func focusPresentedShelf() {
    guard !terminating, shelf != nil, lifecycle.phase == .open, model.visible,
      !incomingDrag, !NSApp.isHidden, NSApp.isActive,
      shelf.attachedSheet == nil, NSApp.modalWindow == nil,
      NSApp.keyWindow == nil || NSApp.keyWindow === shelf
    else { return }
    shelf.makeKeyAndOrderFront(nil)
  }
  private func dismissForFocusLoss(reason: String = "focus-loss") {
    guard shelf != nil, lifecycle.requested, !incomingDrag, !model.busy,
      shelf.attachedSheet == nil, NSApp.modalWindow == nil, !NSMenuTrackingState.shared.active
    else { return }
    let anotherKeyWindow = NSApp.keyWindow != nil && NSApp.keyWindow !== shelf
    if activationTransition.ignoresTransientLoss(
      revision: lifecycle.revision, anotherKeyWindow: anotherKeyWindow,
      outsideClick: reason == "outside-click")
    {
      traceLifecycle("ignore-activation-\(reason)")
      return
    }
    hide(reason: reason)
  }
  private func stepHover() {
    guard shelf != nil, suspensions.isEmpty, platform.history.preferencesAvailable,
      model.settings.hoverEnabled, !model.busy, !incomingDrag, !NSMenuTrackingState.shared.active,
      NSApp.modalWindow == nil, shelf.attachedSheet == nil
    else { return }
    if lifecycle.requested { geometry() }
    let screen = screen()
    let mouse = NSEvent.mouseLocation
    let notchWidth =
      screen.auxiliaryTopLeftArea.flatMap { left in
        screen.auxiliaryTopRightArea.map { max(0, $0.minX - left.maxX) }
      } ?? 0
    let notchHeight = notchWidth > 0 ? screen.safeAreaInsets.top : 0
    let width = notchWidth > 0 && notchHeight > 0 ? notchWidth : 96
    let height = notchWidth > 0 && notchHeight > 0 ? notchHeight : 3
    let center =
      screen.auxiliaryTopLeftArea.flatMap { left in
        screen.auxiliaryTopRightArea.map { (left.maxX + $0.minX) / 2 }
      } ?? screen.frame.midX
    let target = NSRect(
      x: center - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    let action = hover.step(
      now: Date().timeIntervalSince1970 * 1000, inTarget: target.contains(mouse),
      inCorridor: shelf.frame.contains(mouse), visible: lifecycle.requested)
    if action == true { Task { await show(nil, byHover: true) } }
    if action == false, openedByHover { hide() }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if shutdownFinished { return .terminateNow }
    if terminating { return .terminateCancel }
    terminating = true
    cancelIncomingEnd()
    // Sheet-based startup prompts must also release their awaiting task on quit.
    for window in sender.windows {
      if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
    }
    hoverTimer?.invalidate()
    media?.stop()
    fixtureTimer?.invalidate()
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    outsideClickMonitor = nil
    if let quitKeyMonitor { NSEvent.removeMonitor(quitKeyMonitor) }
    quitKeyMonitor = nil
    for (center, token) in notifications { center.removeObserver(token) }
    notifications.removeAll()
    Task {
      await platform?.shutdown()
      if lockFD >= 0 {
        flock(lockFD, LOCK_UN)
        close(lockFD)
      }
      shutdownFinished = true
      self.requestQuit()
    }
    // A deferred AppKit termination runs a modal loop which can prevent the
    // main actor from draining clipboard/helper shutdown. Finish asynchronously
    // and issue a fresh termination. Sparkle permits delayed/canceled quit
    // requests and waits for the application process to actually exit.
    return .terminateCancel
  }
  private func installPowerObservers() {
    let workspace = NSWorkspace.shared.notificationCenter
    for (name, reason, suspended) in [
      (NSWorkspace.willSleepNotification, "sleep", true),
      (NSWorkspace.didWakeNotification, "sleep", false),
    ] {
      notifications.append(
        (
          workspace,
          workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerChanged(reason, suspended: suspended) }
          }
        ))
    }
    let distributed = DistributedNotificationCenter.default()
    for (name, suspended) in [
      ("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false),
    ] {
      notifications.append(
        (
          distributed,
          distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.powerChanged("lock", suspended: suspended) }
          }
        ))
    }
  }
  private func powerChanged(_ reason: String, suspended: Bool) {
    if suspended {
      suspensions.insert(reason)
      hide(force: true)
      platform.cancelPaste()
      media?.suspend(reason)
    } else {
      suspensions.remove(reason)
      media?.resume(reason)
    }
  }
  private var launchedAtLogin: Bool {
    NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(
      forKeyword: keyAELaunchedAsLogInItem) != nil
  }
  private func writeUpdateReceipt(_ fixture: NativeProfile.UpdateFixture) {
    let snapshot = platform.history.snapshot()
    let receipt: [String: Any] = [
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "",
      "storageStatus": model.storageStatus,
      "clips": snapshot.clips.map { ["id": $0.id, "content": $0.content] },
      "snippets": snapshot.snippets.map { ["id": $0.id, "content": $0.content] },
      "updates": [
        "status": platform.updates.status, "version": platform.updates.version,
        "message": platform.updates.message,
      ],
      "commandAck": fixtureCommandID,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: receipt) {
      try? data.write(to: fixture.receipt, options: .atomic)
    }
  }
  private func startUpdateFixtureDriver(_ fixture: NativeProfile.UpdateFixture) {
    // Baked controls exist only in a disposable fixture identity and temporary
    // profile. They never read production data or invoke global input services.
    platform.updates.start()
    fixtureTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.writeUpdateReceipt(fixture)
        guard !self.fixtureCommandBusy,
          let data = try? Data(contentsOf: fixture.profile.appendingPathComponent("command.json")),
          let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let id = command["id"], id != self.fixtureCommandID,
          let name = command["name"],
          ["updates.check", "updates.install", "system.quit"].contains(name)
        else { return }
        self.fixtureCommandID = id
        self.fixtureCommandBusy = true
        Task {
          do { try await self.platform.handle(NativeUICommand(name)) } catch {
            self.model.error = error.localizedDescription
          }
          self.fixtureCommandBusy = false
          self.writeUpdateReceipt(fixture)
        }
      }
    }
  }
  private func scrollSmoke() async {
    guard fixture, let path = ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_RESULT"]
    else { return }
    await platform.waitForInitialization()
    let result = await nativeScrollSmoke(application: self, shelf: shelf, model: model)
    if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
      try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    nativeSmokePostQuit(shelf)
  }
  private func noticeQuitSmoke() async {
    guard fixture, let path = ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_RESULT"]
    else { return }
    for _ in 0..<100 {
      if shelf.attachedSheet != nil { break }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    let failures =
      shelf.attachedSheet == nil ? ["startup notice did not attach an asynchronous sheet"] : []
    let result: [String: Any] = [
      "ok": failures.isEmpty, "failures": failures,
      "nativeVisible": shelf.isVisible, "destination": model.destination,
      "storageStatus": model.storageStatus,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
      try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    nativeSmokePostQuit(shelf.attachedSheet ?? shelf, characters: "й")
  }
  private func startupCloseSmoke() async {
    guard fixture, let path = ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_RESULT"]
    else { return }
    let failures = await nativeSmokeStartupCloseFlows(
      application: self, shelf: shelf, model: model, platform: platform)
    let result: [String: Any] = [
      "ok": failures.isEmpty, "failures": failures,
      "nativeVisible": shelf.isVisible, "destination": model.destination,
      "storageStatus": model.storageStatus,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
      try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    nativeSmokePostQuit(shelf)
  }
  private func smoke(settingsOnly: Bool = false) async {
    guard fixture, let path = ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_RESULT"]
    else { return }
    for _ in 0..<100 where model.storageStatus == "starting" {
      try? await Task.sleep(nanoseconds: 25_000_000)
    }
    var failures: [String] = []
    if model.storageStatus != "ready" { failures.append("history not ready") }
    await show("snippets")
    model.createSnippet()
    model.draft?.content = "Native keyboard draft"
    try? await Task.sleep(nanoseconds: 100_000_000)
    if let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shelf.windowNumber,
      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
      keyCode: 36)
    {
      NSApp.postEvent(event, atStart: false)
    }
    for _ in 0..<100 {
      if model.snippets.contains(where: { $0.content == "Native keyboard draft" }) && !model.busy {
        break
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    platform.refresh()
    if !model.snippets.contains(where: { $0.content == "Native keyboard draft" }) {
      failures.append("Command Enter did not save snippet")
    }
    await show("clipboard")
    model.query = "Синтетическая"
    hide()
    await show(nil)
    if model.destination != "clipboard" || model.query != "Синтетическая" {
      failures.append("quick reopen lost browse context")
    }
    if let first = model.clips.first {
      try? await platform.handle(
        NativeUICommand("clipboardHistory.copy", strings: ["id": first.id]))
      if platform.capture.syntheticText != first.content {
        failures.append("copy did not use synthetic clipboard")
      }
    }
    await show("clipboard")
    if !settingsOnly {
      if let media {
        failures += await nativeMediaSmokeOverlay(application: self, shelf: shelf, monitor: media)
      }
      failures += nativeMediaSmokeScreenshots(shelf: shelf)
    }
    failures += await nativeSmokeAdditionalFlows(
      application: self, shelf: shelf, model: model, platform: platform, settingsOnly: settingsOnly)
    _ = media?.showFixture(.init(camera: "inactive", microphone: "inactive"))
    let result: [String: Any] = [
      "ok": failures.isEmpty, "failures": failures, "nativeVisible": shelf.isVisible,
      "destination": model.destination, "snippets": model.snippets.count,
    ]
    if let view = shelf.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      if let png = bitmap.representation(using: .png, properties: [:]),
        let screenshot = ProcessInfo.processInfo.environment["POLKA_NATIVE_SMOKE_SCREENSHOT"]
      {
        try? png.write(to: URL(fileURLWithPath: screenshot))
      }
    }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
      try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    nativeSmokePostQuit(shelf)
  }
}

@main struct PolkaNativeMain {
  @MainActor static func main() {
    let app = NSApplication.shared
    let delegate = NativeApplication()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
