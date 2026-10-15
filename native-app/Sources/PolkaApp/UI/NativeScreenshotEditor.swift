import AppKit
import PolkaCore
import SwiftUI

private final class NativeScreenshotWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  override func performClose(_ sender: Any?) {
    if delegate?.windowShouldClose?(self) != false { close() }
  }
}

private final class NativeScreenshotHostingView<Content: View>: NSHostingView<Content> {
  override var isOpaque: Bool { false }
}

@MainActor final class NativeScreenshotEditor: NSWindowController, NSWindowDelegate {
  let shot: NativeScreenshotDocument
  var onClose: (() -> Void)?
  let desktopFrame: CGRect?
  var mirrors: [NativeScreenshotEditor] = []
  weak var overlayRoot: NativeScreenshotEditor?
  var liveImage: (() async throws -> CGImage)?
  var showsTools: Bool {
    guard let desktopFrame else { return true }
    let area = shot.areaPreview ?? shot.area
    let scale = desktopFrame.width / shot.fullBounds.width
    let selected = CGRect(
      x: desktopFrame.minX + area.minX * scale,
      y: desktopFrame.minY + area.minY * scale, width: area.width * scale,
      height: area.height * scale)
    func overlap(_ editor: NativeScreenshotEditor) -> CGFloat {
      let part = selected.intersection(editor.window?.frame ?? .zero)
      return part.isNull ? 0 : part.width * part.height
    }
    return group.max { overlap($0) < overlap($1) } === self
  }
  var group: [NativeScreenshotEditor] {
    let root = overlayRoot ?? self
    return [root] + root.mirrors
  }
  func hide() { for editor in group { editor.window?.orderOut(nil) } }
  func fullImageRect(in bounds: CGRect) -> CGRect {
    if let desktopFrame, let frame = window?.frame {
      return desktopFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
    return NativeScreenshotCanvas.fullImageRect(in: bounds, size: shot.fullBounds.size)
  }
  var copyImage: ((Data) throws -> Void)?
  var addToShelf: ((Data, String) throws -> Void)?
  private(set) var savePanel: NSSavePanel?
  private var monitor: Any?
  private var exportTask: Task<Void, Never>?
  weak var canvas: NativeScreenshotCanvas?
  init(
    shot: NativeScreenshotDocument, screenFrame: CGRect? = nil, desktopFrame: CGRect? = nil
  ) {
    self.shot = shot
    self.desktopFrame = desktopFrame
    let window = NativeScreenshotWindow(
      contentRect: screenFrame ?? NSScreen.main?.frame
        ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
      styleMask: [.borderless, .closable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.title = shot.title
    window.identifier = NSUserInterfaceItemIdentifier("screenshot-editor")
    window.minSize = NSSize(width: 740, height: 440)
    window.isReleasedWhenClosed = false
    window.acceptsMouseMovedEvents = true
    window.delegate = self
    window.contentView = NativeScreenshotHostingView(
      rootView: NativeScreenshotEditorView(document: shot, editor: self))
    window.level = desktopFrame == nil ? .floating : .screenSaver
    if desktopFrame != nil {
      // WindowServer ignores fully transparent pixels when routing mouse input.
      // Keep the desktop visible while retaining an input surface for drawing.
      window.backgroundColor = NSColor.black.withAlphaComponent(0.001)
      window.isOpaque = false
      window.hasShadow = false
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window, self.window?.isKeyWindow == true else {
        return event
      }
      let text = self.window?.firstResponder as? NSTextView
      let key = NativeKeyInput(
        code: event.keyCode, characters: event.characters ?? "",
        modifiers: event.modifierFlags, repeatKey: event.isARepeat,
        composing: text?.hasMarkedText() ?? false, editing: text?.isEditable ?? false)
      return self.handleKeyboard(key) ? nil : event
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  func present() {
    NSApp.activate(ignoringOtherApps: true)
    for mirror in mirrors { mirror.window?.orderFrontRegardless() }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
    canvas?.textEditor?.undoManager
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !shot.busy, sender.attachedSheet == nil, finishText() else { return false }
    return true
  }
  func windowWillClose(_ notification: Notification) {
    exportTask?.cancel()
    for mirror in mirrors {
      mirror.onClose = nil
      mirror.close()
    }
    mirrors.removeAll()
    window?.contentView = nil
    canvas = nil
    onClose?()
    onClose = nil
  }
  @discardableResult func handleKeyboard(_ key: NativeKeyInput) -> Bool {
    guard !key.composing, nativeCommandInteractionAllowed else { return false }
    let flags = key.modifiers.intersection([.command, .shift, .control, .option])
    let cmd = flags == .command
    let shiftCmd = flags == [.command, .shift]
    if !key.editing, window?.firstResponder === canvas, canvas?.areaKeyboard == true,
      [36, 48, 123, 124, 125, 126].contains(key.code), flags.isEmpty || flags == .shift
    {
      if !key.repeatKey && !shot.busy { canvas?.areaKey(key.code, shift: flags == .shift) }
      return true
    }
    if !key.editing, flags.isEmpty, key.code == 36, shot.objectDraft?.kind == .text {
      if !key.repeatKey && !shot.busy { editSelectedText() }
      return true
    }
    if !key.editing, window?.firstResponder === canvas, flags.isEmpty || flags == .shift,
      shot.objectDraft != nil, key.code != 48 || shot.objectDraft?.kind != .text,
      [48, 123, 124, 125, 126].contains(key.code)
    {
      if !key.repeatKey && !shot.busy { canvas?.editObjectKey(key.code, shift: flags == .shift) }
      return true
    }
    if flags.isEmpty, key.code == 51, !key.editing, shot.objectDraft != nil {
      if !key.repeatKey && !shot.busy { deleteObject() }
      return true
    }
    if (cmd && key.code == 36) || (flags.isEmpty && key.code == 53), canvas?.textEditor != nil {
      if !key.repeatKey && !shot.busy { _ = finishText() }
      return true
    }
    if flags.isEmpty, key.code == 53, !key.editing {
      if !key.repeatKey && !shot.busy {
        if shot.objectDraft != nil {
          shot.finishObject()
          canvas?.needsDisplay = true
        } else {
          discard()
        }
      }
      return true
    }
    let known =
      (cmd && [18, 19, 20, 8, 1, 6, 13, 15].contains(key.code))
      || (shiftCmd && [1, 6].contains(key.code))
    if key.editing, canvas?.textEditor != nil, window?.firstResponder === canvas?.textEditor,
      key.code == 6, cmd || shiftCmd
    {
      if !key.repeatKey && !shot.busy {
        if shiftCmd { redo() } else { undo() }
      }
      return true
    }
    // NSTextView owns text editing, including undo and clipboard operations.
    if key.editing && ((cmd && [8, 6].contains(key.code)) || (shiftCmd && key.code == 6)) {
      return false
    }
    guard known else { return false }
    if key.repeatKey || shot.busy { return true }
    switch (key.code, shiftCmd) {
    case (18, _): select(.arrow)
    case (19, _): select(.text)
    case (20, _): select(.rectangle)
    case (8, _): copyScreenshot()
    case (1, true): shelf()
    case (1, false): save()
    case (6, true): redo()
    case (6, false): undo()
    case (13, _): discard()
    case (15, _): adjustArea()
    default: break
    }
    return true
  }
  @discardableResult func finishText() -> Bool {
    if let text = window?.firstResponder as? NSTextView {
      guard !text.hasMarkedText() else { return false }
      if text.isFieldEditor, let canvas { window?.makeFirstResponder(canvas) }
    }
    for editor in group {
      if editor.canvas?.textEditor?.hasMarkedText() == true { return false }
    }
    for editor in group where editor.canvas?.textEditor != nil {
      if editor.canvas?.finishText() == false { return false }
    }
    shot.commitText()
    shot.finishObject()
    return true
  }
  func editSelectedText() {
    guard !shot.busy, nativeCommandInteractionAllowed, let selected = shot.pendingObject,
      selected.kind == .text, finishText()
    else { return }
    let bounds = NativeScreenshotDocument.textBounds(selected)
    canvas?.beginText(at: CGPoint(x: bounds.midX, y: bounds.midY))
  }
  func discard() {
    guard !shot.busy, nativeCommandInteractionAllowed else { return }
    window?.performClose(nil)
  }
  func deleteObject() {
    guard !shot.busy, nativeCommandInteractionAllowed else { return }
    if let text = window?.firstResponder as? NSTextView, text.hasMarkedText() { return }
    shot.deleteObject()
  }
  var canUndo: Bool {
    canvas?.textEditor?.undoManager?.canUndo ?? (shot.canUndo || shot.objectDraft != nil)
  }
  var canRedo: Bool { canvas?.textEditor?.undoManager?.canRedo ?? shot.canRedo }
  func undo() {
    guard !shot.busy, nativeCommandInteractionAllowed else { return }
    if let text = canvas?.textEditor {
      guard !text.hasMarkedText() else { return }
      text.undoManager?.undo()
    } else {
      shot.undo()
    }
  }
  func redo() {
    guard !shot.busy, nativeCommandInteractionAllowed else { return }
    if let text = canvas?.textEditor {
      guard !text.hasMarkedText() else { return }
      text.undoManager?.redo()
    } else {
      shot.redo()
    }
  }
  func adjustArea() {
    guard !shot.busy, nativeCommandInteractionAllowed, let window,
      window.attachedSheet == nil, finishText()
    else { return }
    canvas?.focusArea()
  }
  func select(_ tool: NativeScreenshotMark.Kind) {
    guard !shot.busy, nativeCommandInteractionAllowed else { return }
    guard finishText() else { return }
    canvas?.stopArea()
    shot.tool = tool
  }
  func preparePNG(_ completed: @escaping (Data) -> Void) {
    guard finishText() else { return }
    guard let liveImage else {
      do { completed(try shot.png()) } catch { shot.message = error.localizedDescription }
      return
    }
    shot.busy = true
    exportTask = Task { @MainActor in
      do {
        let full = try await liveImage()
        try Task.checkCancellation()
        guard full.width == shot.fullSource.width, full.height == shot.fullSource.height,
          let cropped = full.cropping(
            to: CGRect(
              x: shot.area.minX,
              y: CGFloat(full.height) - shot.area.maxY, width: shot.area.width,
              height: shot.area.height))
        else { throw PolkaCoreError.invalid(localized("Could not render the screenshot")) }
        let data = try shot.png(background: cropped)
        shot.busy = false
        completed(data)
      } catch {
        shot.busy = false
        shot.message = error.localizedDescription
      }
    }
  }
  func copyScreenshot() {
    guard !shot.busy, nativeCommandInteractionAllowed, let copyImage else { return }
    preparePNG { [weak self] data in
      guard let self else { return }
      do {
        try copyImage(data)
        self.window?.performClose(nil)
      } catch { self.shot.message = error.localizedDescription }
    }
  }
  func shelf() {
    guard !shot.busy, nativeCommandInteractionAllowed, let addToShelf else { return }
    preparePNG { [weak self] data in
      guard let self else { return }
      do {
        try addToShelf(data, self.shot.id)
        self.window?.performClose(nil)
      } catch { self.shot.message = error.localizedDescription }
    }
  }
  func save() {
    guard !shot.busy, nativeCommandInteractionAllowed, let window else { return }
    preparePNG { [weak self] data in
      guard let self else { return }
      self.showSavePanel(data, window: window)
    }
  }
  private func showSavePanel(_ data: Data, window: NSWindow) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue =
      "Polka-\(shot.createdAt.formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).png"
    panel.canCreateDirectories = true
    shot.busy = true
    savePanel = panel
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      defer {
        self.shot.busy = false
        self.savePanel = nil
      }
      guard response == .OK, let url = panel.url else { return }
      do {
        try data.write(to: url, options: .atomic)
        self.shot.message = localized("Image Saved")
      } catch { self.shot.message = nativeImageSaveError(error) }
    }
  }
}

enum NativeScreenshotToolbarLayout {
  static func frame(
    selection: CGRect, screen: CGSize, toolbar: CGSize, above: Bool, topInset: CGFloat = 0
  ) -> CGRect {
    let gap: CGFloat = 10
    let margin: CGFloat = 8
    let x = max(
      margin, min(screen.width - toolbar.width - margin, selection.midX - toolbar.width / 2))
    let top = max(0, topInset) + margin
    let outside = above ? selection.minY - gap - toolbar.height : selection.maxY + gap
    let fits = above ? outside >= top : outside + toolbar.height <= screen.height - margin
    let inside = above ? selection.minY + gap : selection.maxY - gap - toolbar.height
    let y = max(top, min(screen.height - toolbar.height - margin, fits ? outside : inside))
    return CGRect(origin: CGPoint(x: x, y: y), size: toolbar)
  }
}
private struct NativeScreenshotEditorView: View {
  @ObservedObject var document: NativeScreenshotDocument
  weak var editor: NativeScreenshotEditor?
  @State private var toolsSize = CGSize(width: 510, height: 76)
  @State private var actionsSize = CGSize(width: 470, height: 40)
  var body: some View {
    GeometryReader { geometry in
      let full =
        editor?.fullImageRect(in: CGRect(origin: .zero, size: geometry.size))
        ?? NativeScreenshotCanvas.fullImageRect(
          in: CGRect(origin: .zero, size: geometry.size), size: document.fullBounds.size)
      let area = document.areaPreview ?? document.area
      let scale = full.width / document.fullBounds.width
      let selected = CGRect(
        x: full.minX + area.minX * scale,
        y: geometry.size.height - full.minY - area.maxY * scale,
        width: area.width * scale, height: area.height * scale)
      let screen = editor?.window?.screen
      let topInset = max(
        geometry.safeAreaInsets.top,
        max(
          screen?.safeAreaInsets.top ?? 0,
          (screen?.frame.maxY ?? 0) - (screen?.visibleFrame.maxY ?? 0)))
      let toolsFrame = NativeScreenshotToolbarLayout.frame(
        selection: selected, screen: geometry.size, toolbar: toolsSize, above: true,
        topInset: topInset)
      let actionsFrame = NativeScreenshotToolbarLayout.frame(
        selection: selected, screen: geometry.size, toolbar: actionsSize, above: false,
        topInset: topInset)
      ZStack(alignment: .topLeading) {
        NativeScreenshotCanvasBridge(document: document, editor: editor)
        VStack(spacing: 0) {
          HStack(spacing: 8) {
            tool(localized("Arrow"), .arrow, "⌘1")
            tool(localized("Text"), .text, "⌘2")
            tool(localized("Rectangle"), .rectangle, "⌘3")
            Divider().frame(height: 22)
            NativeIconButton(
              label: localized("Undo"), symbol: "arrow.uturn.backward", shortcut: "⌘Z",
              disabled: document.busy || editor?.canUndo != true
            ) { editor?.undo() }
            .opacity(document.busy || editor?.canUndo != true ? 0.35 : 1)
            NativeIconButton(
              label: localized("Redo"), symbol: "arrow.uturn.forward", shortcut: "⌘⇧Z",
              disabled: document.busy || editor?.canRedo != true
            ) { editor?.redo() }
            .opacity(document.busy || editor?.canRedo != true ? 0.35 : 1)
            NativeCommandButton(
              title: localized("Edit"), shortcut: "↩",
              disabled: document.busy || document.objectDraft?.kind != .text
            ) { editor?.editSelectedText() }
            .opacity(document.busy || document.objectDraft?.kind != .text ? 0.35 : 1)
            NativeCommandButton(
              title: localized("Delete"), shortcut: "⌫",
              disabled: document.busy || document.objectDraft == nil
            ) { editor?.deleteObject() }
            .opacity(document.busy || document.objectDraft == nil ? 0.35 : 1)
          }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
          Group {
            HStack(spacing: 10) {
              if document.editingKind == .arrow {
                colorPicker("Color", color: $document.style.arrowColor)
                numberControl(
                  "Width", value: $document.style.arrowWidth, range: 1...32,
                  identifier: "screenshot-arrow-width")
              } else if document.editingKind == .rectangle {
                colorPicker("Color", color: $document.style.rectangleColor)
                numberControl(
                  "Width", value: $document.style.rectangleWidth, range: 1...32,
                  identifier: "screenshot-rectangle-width")
                Toggle(localized("Filled"), isOn: $document.style.rectangleFilled)
                  .toggleStyle(.checkbox).accessibilityIdentifier("screenshot-rectangle-filled")
              } else {
                colorPicker("Color", color: $document.style.textColor)
                colorPicker("Background", color: $document.style.textBackground, opacity: true)
                numberControl(
                  "Size", value: $document.style.textSize, range: 8...160,
                  identifier: "screenshot-text-size")
              }
            }.font(.system(size: 12)).frame(height: 26).disabled(document.busy)
              .padding(.horizontal, 8).padding(.bottom, 6)
          }
        }.frame(width: 440).fixedSize(horizontal: false, vertical: true).background(
          .regularMaterial, in: RoundedRectangle(cornerRadius: 9)
        )
        .onGeometryChange(for: CGSize.self) {
          $0.size
        } action: {
          toolsSize = $0
        }
        .help(
          document.objectDraft?.kind == .text
            ? localized("Drag text to move · Double-click or Return to edit · Arrow keys move")
            : localized(
              "Drag handles or the object · Tab selects a handle · Arrow keys move · Backspace deletes"
            )
        )
        .position(x: toolsFrame.midX, y: toolsFrame.midY)
        .opacity(editor?.showsTools == false ? 0 : 1)
        .allowsHitTesting(editor?.showsTools != false)
        HStack(spacing: 6) {
          NativeCommandButton(title: localized("Copy"), shortcut: "⌘C", disabled: document.busy) {
            editor?.copyScreenshot()
          }
          NativeCommandButton(title: localized("Save…"), shortcut: "⌘S", disabled: document.busy) {
            editor?.save()
          }
          NativeCommandButton(
            title: localized("Add to File Shelf"), shortcut: "⌘⇧S",
            disabled: document.busy || editor?.addToShelf == nil
          ) { editor?.shelf() }
          Divider().frame(height: 20)
          NativeCommandButton(
            title: localized("Discard"), shortcut: "Esc", disabled: document.busy
          ) { editor?.discard() }
          .help(
            localized("Closing this window discards the screenshot. Copy or save it to keep it."))
        }
        .padding(6).fixedSize().background(
          .regularMaterial, in: RoundedRectangle(cornerRadius: 9)
        )
        .onGeometryChange(for: CGSize.self) {
          $0.size
        } action: {
          actionsSize = $0
        }
        .position(x: actionsFrame.midX, y: actionsFrame.midY)
        .opacity(editor?.showsTools == false ? 0 : 1)
        .allowsHitTesting(editor?.showsTools != false)
        if !document.message.isEmpty, editor?.showsTools != false {
          Text(document.message).font(.system(size: 11)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).lineLimit(2)
            .frame(width: actionsSize.width - 16, height: 30).padding(.horizontal, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .help(document.message)
            .position(
              x: actionsFrame.midX,
              y: actionsFrame.maxY + 40 <= geometry.size.height - 8
                ? actionsFrame.maxY + 22 : actionsFrame.minY - 22)
        }
      }
    }.environment(\.colorScheme, .dark)
  }
  private func numberControl(
    _ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, identifier: String
  ) -> some View {
    HStack(spacing: 5) {
      Text(localized(title))
      NativeScreenshotNumberField(
        value: value, range: range, title: localized(title), identifier: identifier,
        disabled: document.busy
      )
      .frame(width: 48, height: 24)
      Text("px")
      Stepper(localized(title), value: value, in: range).labelsHidden().fixedSize()
    }.fixedSize()
  }
  private func colorPicker(_ title: String, color: Binding<NSColor>, opacity: Bool = false)
    -> some View
  {
    ColorPicker(
      localized(title),
      selection: Binding(
        get: { Color(nsColor: color.wrappedValue) },
        set: {
          color.wrappedValue = NSColor($0).usingColorSpace(.deviceRGB) ?? NSColor($0)
        }), supportsOpacity: opacity
    ).fixedSize().accessibilityIdentifier("screenshot-" + title)
  }
  private func tool(_ title: String, _ kind: NativeScreenshotMark.Kind, _ shortcut: String)
    -> some View
  {
    NativeIconButton(
      label: title,
      symbol: kind == .arrow ? "arrow.up.right" : kind == .text ? "textformat" : "rectangle",
      shortcut: shortcut, disabled: document.busy, prominent: document.tool == kind
    ) { editor?.select(kind) }
    .accessibilityIdentifier("screenshot-tool-" + kind.rawValue)
  }
}

private struct NativeScreenshotCanvasBridge: NSViewRepresentable {
  @ObservedObject var document: NativeScreenshotDocument
  weak var editor: NativeScreenshotEditor?
  func makeNSView(context: Context) -> NativeScreenshotCanvas {
    let view = NativeScreenshotCanvas()
    view.document = document
    view.editor = editor
    view.toolTip = localized(
      "Drag borders to move · Drag handles to resize · ⌘R focuses handles · Tab chooses · Arrow keys adjust"
    )
    editor?.canvas = view
    return view
  }
  func updateNSView(_ view: NativeScreenshotCanvas, context: Context) {
    view.document = document
    view.editor = editor
    editor?.canvas = view
    view.updateTextEditor()
    view.needsDisplay = true
  }
}

@MainActor final class NativeScreenshotCanvas: NSView, NSTextViewDelegate {
  var document: NativeScreenshotDocument?
  weak var editor: NativeScreenshotEditor?
  private(set) var textEditor: NSTextView?
  private var start: CGPoint?
  private var end: CGPoint?
  private var dragOriginal: NativeScreenshotMark?
  private var dragOrigin: CGPoint?
  private var activeHandle = 2
  private var resizeDraft: NativeScreenshotArea?
  private var resizeOriginal: CGRect?
  private var resizeOrigin: CGPoint?
  private var areaHandle = 4
  private(set) var areaKeyboard = false
  private var cursorTracking: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let cursorTracking { removeTrackingArea(cursorTracking) }
    let tracking = NSTrackingArea(
      rect: .zero, options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved],
      owner: self, userInfo: nil)
    cursorTracking = tracking
    addTrackingArea(tracking)
  }
  func areaTarget(at point: CGPoint) -> Int? {
    guard let document else { return nil }
    let selection = areaRect(document.area)
    let handles = NativeScreenshotArea(document).points(selection)
    if let index = handles.indices.first(where: {
      hypot(handles[$0].x - point.x, handles[$0].y - point.y) <= 12
    }) {
      return index
    }
    return selection.insetBy(dx: -6, dy: -6).contains(point)
      && !selection.insetBy(dx: 6, dy: 6).contains(point) ? 8 : nil
  }
  func pointer(at point: CGPoint) -> NSCursor {
    guard let document, !document.busy else { return .arrow }
    if let target = resizeDraft == nil ? areaTarget(at: point) : areaHandle {
      if target == 8 { return resizeDraft == nil ? .openHand : .closedHand }
      let positions: [NSCursor.FrameResizePosition] = [
        .bottomLeft, .bottom, .bottomRight, .right, .topRight, .top, .topLeft, .left,
      ]
      return .frameResize(position: positions[target], directions: .all)
    }
    guard imageRect.contains(point) else { return .arrow }
    return document.tool == .text ? .iBeam : .crosshair
  }
  override func cursorUpdate(with event: NSEvent) {
    pointer(at: convert(event.locationInWindow, from: nil)).set()
  }
  override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }
  static func fullImageRect(in bounds: CGRect, size: CGSize) -> CGRect {
    let scale = min((bounds.width - 32) / size.width, (bounds.height - 32) / size.height)
    let rendered = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
      x: bounds.midX - rendered.width / 2, y: bounds.midY - rendered.height / 2,
      width: rendered.width, height: rendered.height)
  }
  var fullImageRect: CGRect {
    guard let document else { return .zero }
    return editor?.fullImageRect(in: bounds)
      ?? Self.fullImageRect(in: bounds, size: document.fullBounds.size)
  }
  func areaRect(_ area: CGRect) -> CGRect {
    guard let document else { return .zero }
    let scale = fullImageRect.width / document.fullBounds.width
    return CGRect(
      x: fullImageRect.minX + area.minX * scale, y: fullImageRect.minY + area.minY * scale,
      width: area.width * scale, height: area.height * scale)
  }
  func stopArea() {
    areaKeyboard = false
    resizeDraft = nil
    resizeOriginal = nil
    resizeOrigin = nil
    document?.areaPreview = nil
    needsDisplay = true
  }
  func focusArea() {
    areaKeyboard = true
    window?.makeFirstResponder(self)
    needsDisplay = true
  }
  func areaKey(_ code: UInt16, shift: Bool) {
    guard let document else { return }
    if code == 36 || code == 53 {
      stopArea()
    } else if code == 48 {
      areaHandle = (areaHandle + (shift ? 8 : 1)) % 9
    } else {
      let draft = NativeScreenshotArea(document)
      let step: CGFloat = shift ? 10 : 1
      draft.move(
        draft.rect, handle: areaHandle,
        delta: CGPoint(
          x: code == 123 ? -step : code == 124 ? step : 0,
          y: code == 125 ? -step : code == 126 ? step : 0))
      document.adjustArea(draft.rect)
    }
    needsDisplay = true
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  var imageRect: CGRect {
    guard let document else { return .zero }
    return areaRect(document.area)
  }
  func imagePoint(_ point: CGPoint) -> CGPoint? {
    guard let document, !imageRect.isEmpty else { return nil }
    return CGPoint(
      x: max(
        0,
        min(document.size.width, (point.x - imageRect.minX) * document.size.width / imageRect.width)
      ),
      y: max(
        0,
        min(
          document.size.height, (point.y - imageRect.minY) * document.size.height / imageRect.height
        )))
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let document, let context = NSGraphicsContext.current?.cgContext,
      !imageRect.isEmpty
    else { return }
    context.clear(bounds)
    if editor?.desktopFrame != nil {
      context.saveGState()
      context.translateBy(x: imageRect.minX, y: imageRect.minY)
      context.scaleBy(
        x: imageRect.width / document.size.width, y: imageRect.height / document.size.height)
      context.clip(to: CGRect(origin: .zero, size: document.size))
      let pending = document.pendingObject
      for original in document.marks where original.id != document.editingTextID {
        NativeScreenshotDocument.draw(
          original.id == pending?.id ? pending! : original,
          in: context, size: document.size)
      }
      if textEditor == nil, let text = document.pendingText {
        NativeScreenshotDocument.draw(text, in: context, size: document.size)
      }
      context.restoreGState()
    } else if let image = try? document.rendered() {
      context.draw(document.fullSource, in: fullImageRect)
      context.draw(image, in: imageRect)
    }
    let selection = areaRect(document.areaPreview ?? document.area)
    context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
    context.addRect(bounds)
    context.addRect(selection)
    context.drawPath(using: .eoFill)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(1)
    context.stroke(selection)
    for (index, point) in NativeScreenshotArea(document).points(selection).enumerated() {
      context.setFillColor(
        (areaKeyboard && index == areaHandle ? NSColor.controlAccentColor : .white).cgColor)
      context.fill(CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
    }
    if let selected = document.pendingObject {
      let scale = imageRect.width / document.size.width
      if selected.kind == .text {
        let bounds = NativeScreenshotDocument.textBounds(selected)
        let frame = CGRect(
          x: imageRect.minX + bounds.minX * scale, y: imageRect.minY + bounds.minY * scale,
          width: bounds.width * scale, height: bounds.height * scale)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.stroke(frame.insetBy(dx: -2, dy: -2))
      }
      for (index, point) in objectHandles(selected) {
        let center = CGPoint(
          x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
        let handle = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
        context.setFillColor((activeHandle == index ? NSColor.controlAccentColor : .white).cgColor)
        context.fillEllipse(in: handle)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: handle)
      }
    }
    if let start, let end, document.tool != .text {
      context.saveGState()
      context.translateBy(x: imageRect.minX, y: imageRect.minY)
      context.scaleBy(
        x: imageRect.width / document.size.width, y: imageRect.height / document.size.height)
      NativeScreenshotDocument.draw(
        document.mark(start: start, end: end), in: context, size: document.size)
      context.restoreGState()
    }
  }
  override func mouseDown(with event: NSEvent) {
    guard let document, !document.busy, nativeCommandInteractionAllowed else { return }
    let point = convert(event.locationInWindow, from: nil)
    if let index = areaTarget(at: point) {
      guard finishText() else { return }
      window?.makeFirstResponder(self)
      document.finishObject()
      areaKeyboard = true
      areaHandle = index
      resizeDraft = NativeScreenshotArea(document)
      resizeOriginal = document.area
      resizeOrigin = point
      pointer(at: point).set()
      return
    }
    areaKeyboard = false
    // A click that ends text editing is consumed; it never creates another mark.
    if textEditor != nil {
      _ = finishText()
      return
    }
    guard imageRect.contains(point), let location = imagePoint(point) else {
      document.finishObject()
      return
    }
    window?.makeFirstResponder(self)
    let tolerance = 8 * document.size.width / imageRect.width
    if let selected = document.pendingObject, selected.kind != .text {
      for (index, point) in objectHandles(selected) {
        if hypot(location.x - point.x, location.y - point.y) <= tolerance {
          startObjectDrag(selected, at: location, handle: index)
          return
        }
      }
    }
    if let hit = document.object(at: location, tolerance: tolerance) {
      let mark = document.pendingObject?.id == hit.id ? document.pendingObject! : hit
      document.finishObject()
      if mark.kind == .text && event.clickCount >= 2 {
        beginText(at: location)
      } else {
        document.selectObject(mark)
        startObjectDrag(mark, at: location, handle: 2)
      }
    } else if document.objectDraft != nil {
      document.finishObject()
    } else if document.tool == .text {
      beginText(at: location)
    } else {
      start = location
      end = location
    }
    needsDisplay = true
  }
  private func startObjectDrag(_ mark: NativeScreenshotMark, at point: CGPoint, handle: Int) {
    activeHandle = handle
    dragOriginal = mark
    dragOrigin = point
    needsDisplay = true
  }
  func objectHandles(_ mark: NativeScreenshotMark) -> [(Int, CGPoint)] {
    if mark.kind == .text { return [] }
    var points = [(0, mark.start), (1, mark.end)]
    if mark.kind == .rectangle {
      points.append((3, CGPoint(x: mark.start.x, y: mark.end.y)))
      points.append((4, CGPoint(x: mark.end.x, y: mark.start.y)))
    }
    return points
  }
  func moveObject(_ mark: NativeScreenshotMark, by delta: CGPoint, handle: Int)
    -> NativeScreenshotMark
  {
    guard let document else { return mark }
    var result = mark
    func bounded(_ point: CGPoint) -> CGPoint {
      CGPoint(
        x: max(0, min(document.size.width, point.x)), y: max(0, min(document.size.height, point.y)))
    }
    if mark.kind == .text {
      let bounds = NativeScreenshotDocument.textBounds(mark)
      let dx = max(
        -bounds.minX, min(max(0, document.size.width - bounds.width) - bounds.minX, delta.x))
      let dy = max(
        -bounds.minY, min(max(0, document.size.height - bounds.height) - bounds.minY, delta.y))
      result.start = CGPoint(x: mark.start.x + dx, y: mark.start.y + dy)
      result.end = CGPoint(x: mark.end.x + dx, y: mark.end.y + dy)
    } else if handle == 2 {
      let dx = max(
        -min(mark.start.x, mark.end.x),
        min(document.size.width - max(mark.start.x, mark.end.x), delta.x))
      let dy = max(
        -min(mark.start.y, mark.end.y),
        min(document.size.height - max(mark.start.y, mark.end.y), delta.y))
      result.start = CGPoint(x: mark.start.x + dx, y: mark.start.y + dy)
      result.end = CGPoint(x: mark.end.x + dx, y: mark.end.y + dy)
    } else if mark.kind == .rectangle && handle == 3 {
      result.start.x = bounded(CGPoint(x: mark.start.x + delta.x, y: 0)).x
      result.end.y = bounded(CGPoint(x: 0, y: mark.end.y + delta.y)).y
    } else if mark.kind == .rectangle && handle == 4 {
      result.end.x = bounded(CGPoint(x: mark.end.x + delta.x, y: 0)).x
      result.start.y = bounded(CGPoint(x: 0, y: mark.start.y + delta.y)).y
    } else if handle == 0 {
      result.start = bounded(CGPoint(x: mark.start.x + delta.x, y: mark.start.y + delta.y))
    } else {
      result.end = bounded(CGPoint(x: mark.end.x + delta.x, y: mark.end.y + delta.y))
    }
    return result
  }
  override func mouseDragged(with event: NSEvent) {
    guard let document, !document.busy, nativeCommandInteractionAllowed else { return }
    if let draft = resizeDraft, let original = resizeOriginal, let origin = resizeOrigin {
      let point = convert(event.locationInWindow, from: nil)
      pointer(at: point).set()
      let scale = fullImageRect.width / document.fullBounds.width
      draft.move(
        original, handle: areaHandle,
        delta: CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale))
      document.areaPreview = draft.rect
      needsDisplay = true
      return
    }
    let point = imagePoint(convert(event.locationInWindow, from: nil))
    if let original = dragOriginal, let origin = dragOrigin, let point {
      document.objectDraft = moveObject(
        original, by: CGPoint(x: point.x - origin.x, y: point.y - origin.y), handle: activeHandle)
    } else if start != nil {
      end = point
    }
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    if let document, let draft = resizeDraft {
      document.adjustArea(draft.rect)
      document.areaPreview = nil
      resizeDraft = nil
      resizeOriginal = nil
      resizeOrigin = nil
      cursorUpdate(with: event)
      needsDisplay = true
      return
    }
    if let document, dragOriginal != nil, let updated = document.pendingObject {
      document.finishObject()
      document.selectObject(updated)
    } else if let document, let start, let end, hypot(end.x - start.x, end.y - start.y) >= 2 {
      let mark = document.mark(start: start, end: end)
      document.add(mark)
      document.selectObject(mark)
      activeHandle = 2
    }
    dragOriginal = nil
    dragOrigin = nil
    start = nil
    end = nil
    needsDisplay = true
  }
  func editObjectKey(_ code: UInt16, shift: Bool) {
    guard let document, !document.busy, let selected = document.pendingObject else { return }
    if code == 53 {
      document.finishObject()
      dragOriginal = nil
      dragOrigin = nil
    } else if code == 48 {
      let handles = selected.kind == .rectangle ? [0, 1, 3, 4, 2] : [0, 1, 2]
      let index = handles.firstIndex(of: activeHandle) ?? 0
      activeHandle = handles[(index + (shift ? handles.count - 1 : 1)) % handles.count]
    } else {
      let step: CGFloat = shift ? 10 : 1
      let delta = CGPoint(
        x: code == 123 ? -step : code == 124 ? step : 0,
        y: code == 125 ? -step : code == 126 ? step : 0)
      let updated = moveObject(selected, by: delta, handle: activeHandle)
      document.objectDraft = updated
      document.finishObject()
      document.selectObject(updated)
    }
    needsDisplay = true
  }
  func beginText(at point: CGPoint) {
    guard let document, !document.busy else { return }
    document.beginText(at: point)
    let text = NativeScreenshotTextView(frame: .zero)
    text.isVerticallyResizable = false
    text.isHorizontallyResizable = false
    text.wantsLayer = true
    text.layer?.borderWidth = 1
    text.layer?.borderColor = NSColor.controlAccentColor.cgColor
    text.isRichText = false
    text.importsGraphics = false
    text.allowsUndo = true
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.textContainerInset = .zero
    text.textContainer?.lineFragmentPadding = 0
    text.textContainer?.widthTracksTextView = false
    text.textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
    text.string = document.label
    text.delegate = self
    text.setAccessibilityIdentifier("screenshot-inline-text")
    text.setAccessibilityLabel(localized("Text on the image"))
    text.setAccessibilityHelp(localized("Esc or ⌘Return to finish"))
    textEditor = text
    addSubview(text)
    updateTextEditor()
    window?.makeFirstResponder(text)
    if document.editingTextID != nil {
      let scale = imageRect.width / document.size.width
      let clicked = CGPoint(
        x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
      if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
      let index = text.characterIndexForInsertion(at: text.convert(clicked, from: self))
      text.setSelectedRange(
        NSRange(location: min(index, (text.string as NSString).length), length: 0))
    } else {
      text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
    }
  }
  func updateTextEditor() {
    guard let document, let anchor = document.textAnchor, let text = textEditor,
      !imageRect.isEmpty, !text.hasMarkedText()
    else { return }
    let scale = imageRect.width / document.size.width
    let font = NSFont.systemFont(ofSize: document.style.textSize * scale, weight: .semibold)
    if text.font != font { text.font = font }
    if text.textColor != document.style.textColor { text.textColor = document.style.textColor }
    text.backgroundColor = document.style.textBackground
    text.drawsBackground = document.style.textBackground.alphaComponent > 0
    text.insertionPointColor = document.style.textColor
    text.isEditable = !document.busy
    let measured = NativeScreenshotDocument.attributedText(
      document.label.isEmpty ? " " : document.label, style: document.style
    ).size()
    let x = imageRect.minX + anchor.x * scale
    let top = imageRect.minY + anchor.y * scale
    let height = max(font.ascender - font.descender + font.leading, measured.height * scale)
    text.frame = NSRect(
      x: x, y: top - height, width: max(20, min(imageRect.maxX - x, measured.width * scale + 12)),
      height: height)
    if (text.typingAttributes[.font] as? NSFont) != font
      || (text.typingAttributes[.foregroundColor] as? NSColor) != document.style.textColor
    {
      text.typingAttributes = [.font: font, .foregroundColor: document.style.textColor]
    }
  }
  override func layout() {
    super.layout()
    updateTextEditor()
  }
  func textDidChange(_ notification: Notification) {
    guard let text = textEditor, let document else { return }
    document.label = text.string
    updateTextEditor()
  }
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard !textView.hasMarkedText() else { return false }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      return finishText()
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)),
      NSApp.currentEvent?.modifierFlags.contains(.command) == true
    {
      return finishText()
    }
    return false
  }
  @discardableResult func finishText() -> Bool {
    guard textEditor?.hasMarkedText() != true else { return false }
    document?.commitText()
    dragOriginal = nil
    dragOrigin = nil
    start = nil
    end = nil
    removeTextEditor()
    return true
  }
  func cancelText() {
    document?.cancelText()
    removeTextEditor()
  }
  private func removeTextEditor() {
    guard let text = textEditor else { return }
    if window?.firstResponder === text { window?.makeFirstResponder(self) }
    text.delegate = nil
    text.undoManager?.removeAllActions()
    text.removeFromSuperview()
    textEditor = nil
    needsDisplay = true
  }
  override func cancelOperation(_ sender: Any?) {
    _ = finishText()
    document?.finishObject()
    start = nil
    end = nil
    needsDisplay = true
  }
}

/// Each placement owns its typing history; undo must not target an old, removed editor.
private final class NativeScreenshotTextView: NSTextView {
  private let typingUndo = UndoManager()
  override var undoManager: UndoManager? { typingUndo }
}
