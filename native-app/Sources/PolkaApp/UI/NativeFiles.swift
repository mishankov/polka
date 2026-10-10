import AppKit
import PolkaCore
import SwiftUI
import UniformTypeIdentifiers

struct NativeFileShelfView: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    VStack(spacing: 0) {
      NativeBuiltinHeader(model: model, title: localized("Files on the Shelf")) {
        NativeCommandButton(
          title: localized("Clear Shelf"), shortcut: "⌘⇧⌫",
          disabled: model.busy || model.files.isEmpty
        ) { model.removeSelectedFiles(clear: true) }.accessibilityIdentifier("files-clear")
      }
      Text(localized("Drag files here, then take them to another app.")).font(.system(size: 12))
        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(
          .horizontal, 12
        ).padding(.bottom, 10)
      Divider()
      NativeErrorNotice(text: model.error).padding(.horizontal, 10)
      ScrollView {
        LazyVStack(spacing: 4) {
          if model.files.isEmpty {
            VStack(spacing: 12) {
              Image(systemName: "folder").font(.system(size: 40)).foregroundStyle(.secondary)
              Text(localized("Leave Files Here")).font(.system(size: 16, weight: .semibold))
              Text(
                localized(
                  "They stay in their original locations. The shelf keeps links until you quit Polka."
                )
              ).font(
                .system(size: 12)
              ).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(40)
          }
          ForEach(model.files) { file in
            HStack(spacing: 0) {
              NativeDraggableFileRow(model: model, file: file).frame(height: 62)
              NativeIconButton(
                label: localized("Remove {0} from Shelf", String(describing: file.name)),
                symbol: "trash",
                shortcut: "⌘⌫",
                disabled: model.busy
              ) {
                model.selectedFiles = [file.id]
                model.removeSelectedFiles()
              }.padding(.trailing, 8)
            }.background(
              model.selectedFiles.contains(file.id) ? Color.accentColor.opacity(0.12) : .clear,
              in: RoundedRectangle(cornerRadius: 7)
            ).padding(.horizontal, 6)
          }
        }.padding(.vertical, 8).background(
          NativeScrollPositionBridge(
            offset: $model.listScrollOffset, token: "files-list-\(model.visible)"))
      }
      Divider()
      NativeToolbar {
        Text(
          model.selectedFiles.isEmpty
            ? localized("Files: {0}", String(describing: model.files.count))
            : localized("Selected: {0}", String(describing: model.selectedFiles.count)))
        Spacer()
        NativeCommandButton(
          title: localized("Remove from Shelf"), symbol: "trash", shortcut: "⌘⌫",
          disabled: model.busy || model.selectedFiles.isEmpty
        ) { model.removeSelectedFiles() }.accessibilityIdentifier("files-remove")
      }.font(.system(size: 11)).foregroundStyle(.secondary)
      NativeKeyboardHint(text: localized("⌘ / ⇧ select multiple · ⌘A all"))
      Text(
        localized(
          "Clearing or removing items from the shelf only removes links. Files are not synced.")
      )
      .font(
        .system(size: 10)
      ).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("native-files")
  }
}

struct NativeDraggableFileRow: NSViewRepresentable {
  var model: NativeUIModel
  var file: NativeUIFile
  func makeNSView(context: Context) -> NativeFileDragView { NativeFileDragView() }
  func updateNSView(_ view: NativeFileDragView, context: Context) {
    view.model = model
    view.file = file
    view.needsDisplay = true
    view.setAccessibilityLabel(file.name)
    view.setAccessibilityHelp(
      file.available ? file.path : localized("Moved, deleted, or unavailable"))
    view.setAccessibilityIdentifier("file-\(file.id)")
    view.setAccessibilityValue(
      model.selectedFiles.contains(file.id) ? localized("Selected") : localized("Not selected"))
  }
}
@MainActor final class NativeFileDragView: NSView, NSDraggingSource {
  weak var model: NativeUIModel?
  var file: NativeUIFile?
  private var down: NSEvent?
  private var dragging = false
  override var acceptsFirstResponder: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }
  required init?(coder: NSCoder) { super.init(coder: coder) }
  override func draw(_ dirtyRect: NSRect) {
    guard let file else { return }
    let icon = NSWorkspace.shared.icon(forFile: file.path)
    icon.draw(
      in: NSRect(x: 12, y: (bounds.height - 32) / 2, width: 32, height: 32), from: .zero,
      operation: .sourceOver, fraction: file.available ? 1 : 0.4)
    let width = max(0, bounds.width - 62)
    file.name.draw(
      in: NSRect(x: 56, y: 31, width: width, height: 18),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: file.available ? NSColor.labelColor : NSColor.secondaryLabelColor,
      ])
    (file.available ? file.path : localized("Moved, deleted, or unavailable")).draw(
      in: NSRect(x: 56, y: 13, width: width, height: 15),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
      ])
  }
  override func mouseDown(with event: NSEvent) {
    guard let model, let file, !model.busy else { return }
    down = event
    dragging = false
    window?.makeFirstResponder(self)
    // Preserve an existing multi-selection until we know this is a click, so
    // dragging any selected row exports the whole selection.
    if !model.selectedFiles.contains(file.id)
      || !event.modifierFlags.intersection([.command, .control, .shift]).isEmpty
    {
      model.selectFile(file.id, modifiers: event.modifierFlags)
    }
  }
  override func mouseUp(with event: NSEvent) {
    if !dragging, let down, let file, let model,
      down.modifierFlags.intersection([.command, .control, .shift]).isEmpty
    {
      model.selectFile(file.id, modifiers: [])
    }
    down = nil
  }
  override func mouseDragged(with event: NSEvent) {
    guard !dragging, let down, let file, let model, !model.busy, file.available else { return }
    guard
      hypot(
        event.locationInWindow.x - down.locationInWindow.x,
        event.locationInWindow.y - down.locationInWindow.y) > 3
    else { return }
    let ids = model.selectedFiles.contains(file.id) ? Array(model.selectedFiles) : [file.id]
    do {
      guard let validate = model.fileDragURLs else { return }
      let urls = try validate(ids)
      guard !urls.isEmpty else { return }
      let draggingItems = urls.enumerated().map { index, url -> NSDraggingItem in
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
          NSRect(
            x: point.x + CGFloat(index) * 5, y: point.y - CGFloat(index) * 5, width: 32, height: 32),
          contents: NSWorkspace.shared.icon(forFile: url.path))
        return item
      }
      dragging = true
      model.fileDragStarted?()
      beginDraggingSession(with: draggingItems, event: event, source: self)
    } catch { model.error = error.localizedDescription }
  }
  override func accessibilityPerformPress() -> Bool {
    guard let model, let file, !model.busy else { return false }
    model.selectFile(file.id, modifiers: [])
    window?.makeFirstResponder(self)
    return true
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { [.copy, .link] }
  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    model?.fileDragEnded?()
    down = nil
    dragging = false
  }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
}

/// File URL drops are accepted over every shelf destination, just as on the
/// existing shelf, without reading the clipboard or activating another app.
struct NativeFileDropModifier: ViewModifier {
  @ObservedObject var model: NativeUIModel
  func body(content: Content) -> some View {
    content.overlay(alignment: .top) {
      if model.incomingFileDropTargeted && model.visible && !model.busy
        && !model.incomingFileDropPending
      {
        NativeIncomingFileDropHint(topInset: model.topInset)
          .allowsHitTesting(false)
      }
    }
  }
}

/// AppKit routes unclaimed file drags to the window, including the scroll view's
/// viewport, empty space, and native file rows. A SwiftUI ancestor drop handler
/// does not consistently receive drags over those AppKit-backed children.
extension ShelfPanel: NSDraggingDestination {
  private func incomingOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let model = dropModel, model.settings.builtinApps.allows(destination: "files"),
      model.visible, !model.busy, !model.incomingFileDropPending,
      isVisible, attachedSheet == nil, NSApp.modalWindow == nil,
      NSApp.keyWindow?.attachedSheet == nil, NSApp.keyWindow?.sheetParent == nil,
      (sender.draggingSource as? NSView)?.window !== self,
      contentView?.bounds.contains(sender.draggingLocation) == true,
      sender.draggingPasteboard.canReadObject(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    else { return [] }
    let allowed = sender.draggingSourceOperationMask
    if allowed.contains(.copy) { return .copy }
    if allowed.contains(.link) { return .link }
    return []
  }
  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropTrace?("entered", sender)
    return draggingUpdated(sender)
  }
  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    let operation = incomingOperation(sender)
    if let model = dropModel, model.incomingFileDropTargeted != !operation.isEmpty {
      model.incomingFileDropTargeted = !operation.isEmpty
    }
    return operation
  }
  func draggingExited(_ sender: NSDraggingInfo?) { dropModel?.incomingFileDropTargeted = false }
  func draggingEnded(_ sender: NSDraggingInfo) { dropModel?.incomingFileDropTargeted = false }
  func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    dropTrace?("prepare", sender)
    return !incomingOperation(sender).isEmpty
  }
  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    dropTrace?("perform", sender)
    guard !incomingOperation(sender).isEmpty,
      let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !urls.isEmpty, urls.count <= 1000
    else { return false }
    let providers = urls.map { url in
      let provider = NSItemProvider()
      provider.registerDataRepresentation(
        forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
      ) { completion in
        completion(url.dataRepresentation, nil)
        return nil
      }
      return provider
    }
    return dropModel?.acceptIncomingFiles(providers) ?? false
  }
  func concludeDragOperation(_ sender: NSDraggingInfo?) {
    dropModel?.incomingFileDropTargeted = false
  }
}

extension NativeUIModel {
  /// Provider decoding can outlive an entire presentation. Keep Escape usable,
  /// and commit only to the presentation in which the files were released.
  @discardableResult func acceptIncomingFiles(_ providers: [NSItemProvider]) -> Bool {
    guard settings.builtinApps.allows(destination: "files"), visible, !busy,
      !incomingFileDropPending, !providers.isEmpty, providers.count <= 1000,
      NSApp?.modalWindow == nil, NSApp?.keyWindow?.attachedSheet == nil,
      NSApp?.keyWindow?.sheetParent == nil
    else { return false }
    let revision = sessionRevision
    let token = UUID()
    incomingFileDropToken = token
    incomingFileDropPending = true
    incomingFileDropTargeted = false
    Task { @MainActor in
      defer {
        if incomingFileDropToken == token {
          incomingFileDropPending = false
          incomingFileDropToken = nil
        }
      }
      var paths: [String] = []
      for provider in providers {
        let data: Data? = await withCheckedContinuation { continuation in
          provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            continuation.resume(returning: data)
          }
        }
        guard visible, revision == sessionRevision, incomingFileDropToken == token else { return }
        if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
          paths.append(url.path)
        }
      }
      guard !busy else { return }
      guard !paths.isEmpty else {
        error = localized("Drag local files from Finder.")
        return
      }
      // After decoding, the ordinary guarded command owns the brief commit.
      // Both native drops and UI drops dispatch the same platform action.
      busy = true
      error = ""
      defer { busy = false }
      do {
        guard let action else {
          throw NSError(
            domain: "Polka", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: localized("This action is currently unavailable.")
            ])
        }
        try await action(NativeUICommand("shelf.files.add", ids: paths))
      } catch {
        if visible && revision == sessionRevision { self.error = error.localizedDescription }
      }
    }
    return true
  }
}

/// The incoming target covers the results area, retaining the heading and the
/// existing controls above it. Its outline communicates where to release files.
struct NativeIncomingFileDropHint: View {
  var topInset: CGFloat
  var body: some View {
    Text(localized("Drop to Leave Files on the Shelf"))
      .font(.system(size: 14)).foregroundStyle(.white)
      .multilineTextAlignment(.center).padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
        Color(red: 21 / 255, green: 21 / 255, blue: 21 / 255).opacity(237 / 255),
        in: RoundedRectangle(cornerRadius: 12)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(
            Color(red: 170 / 255, green: 170 / 255, blue: 170 / 255),
            style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
      }
      .padding(.top, topInset + 90).padding(.horizontal, 12).padding(.bottom, 12)
      .accessibilityIdentifier("native-file-drop-hint")
  }
}
