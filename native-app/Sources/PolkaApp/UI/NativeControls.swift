import AppKit
import SwiftUI

struct NativeCommandButton: View {
  var title: String
  var symbol: String = ""
  var shortcut: String = ""
  var disabled = false
  var prominent = false
  var destructive = false
  var action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if !symbol.isEmpty { Image(systemName: symbol) }
        Text(title)
        if !shortcut.isEmpty { Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary) }
      }
    }
    .buttonStyle(.bordered)
    .tint(destructive ? .red : prominent ? .accentColor : nil)
    .disabled(disabled)
    .help(title + (shortcut.isEmpty ? "" : " · " + shortcut))
    .accessibilityHint(shortcut.isEmpty ? "" : "Сочетание клавиш: " + shortcut)
  }
}
struct NativeIconButton: View {
  var label: String
  var symbol: String
  var shortcut = ""
  var disabled = false
  var action: () -> Void
  var body: some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 23, height: 23) }
      .buttonStyle(.borderless).disabled(disabled)
      .help(label + (shortcut.isEmpty ? "" : " · " + shortcut))
      .accessibilityLabel(label).accessibilityHint(
        shortcut.isEmpty ? "" : "Сочетание клавиш: " + shortcut)
  }
}
struct NativeErrorNotice: View {
  var text: String
  var body: some View {
    if !text.isEmpty {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
        Text(text).textSelection(.enabled)
        Spacer(minLength: 0)
      }
      .font(.system(size: 12)).foregroundStyle(.red).padding(10)
      .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
      .accessibilityElement(children: .combine)
    }
  }
}
struct NativeSearchField: View {
  @Binding var text: String
  var placeholder: String
  var maxLength = 10000
  var focusToken: String
  @State private var focused = false
  var body: some View {
    NativeSearchInput(
      text: $text, placeholder: placeholder, maxLength: maxLength, focusToken: focusToken,
      focused: $focused
    )
    // AppKit's window-level focus ring bypasses the animated shelf mask.
    // A SwiftUI border shares the same clipping as the field and shelf.
    .overlay {
      Capsule().strokeBorder(Color.accentColor, lineWidth: 2).clipShape(Capsule())
        .opacity(focused ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}
private struct NativeSearchInput: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var maxLength: Int
  var focusToken: String
  @Binding var focused: Bool
  func makeNSView(context: Context) -> NSSearchField {
    let field = NativeLargeSearchField()
    field.identifier = NSUserInterfaceItemIdentifier("polka-search")
    field.cell = NativeLargeSearchFieldCell(textCell: "")
    // Replacing an AppKit cell resets its editing flags.
    field.isEditable = true
    field.isSelectable = true
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.cell?.usesSingleLineMode = true
    field.placeholderString = placeholder
    field.delegate = context.coordinator
    // AppKit's stock search bezel stays small even at extra-large size.
    // Draw the full-height bezel, retaining native text editing and buttons.
    field.controlSize = .extraLarge
    field.font = .systemFont(ofSize: 20)
    field.sendsSearchStringImmediately = true
    // Keep native search/editor insets; isBordered resets isBezeled, so set
    // the latter last. The cell draws its contents without the small bezel.
    field.isBordered = false
    field.drawsBackground = false
    field.isBezeled = true
    field.focusRingType = .none
    field.cell?.focusRingType = .none
    field.onFocusChanged = { [weak coordinator = context.coordinator] focused in
      coordinator?.setFocused(focused)
    }
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    field.setAccessibilityLabel(placeholder)
    field.setAccessibilityIdentifier("polka-search")
    return field
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 320, height: NativeLargeSearchField.controlHeight)
  }
  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    field.placeholderString = placeholder
    context.coordinator.synchronize(field, text: text)
    if context.coordinator.focusToken != focusToken {
      context.coordinator.focusToken = focusToken
      (field as? NativeLargeSearchField)?.requestKeyboardFocus()
    }
  }
  static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
    let native = field as? NativeLargeSearchField
    native?.cancelKeyboardFocus()
    native?.onFocusChanged = nil
    // AppKit shares one field editor per window. Release it before this
    // search view disappears, so a destination without search cannot keep
    // an editor/delegate belonging to the previous destination.
    field.delegate = nil
    if let editor = field.currentEditor(), let window = field.window,
      window.firstResponder === editor
    {
      window.endEditing(for: field)
      if window.firstResponder === editor { window.makeFirstResponder(nil) }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: NativeSearchInput
    var focusToken: String?
    private var synchronizing = false
    init(_ parent: NativeSearchInput) { self.parent = parent }
    func synchronize(_ field: NSSearchField, text: String) {
      let editor = (field.currentEditor() as? NSTextView).flatMap { editor in
        field.window?.firstResponder === editor ? editor : nil
      }
      // Leave marked text and its selection under the input method's
      // control. The ordinary delegate applies the committed text.
      guard editor?.hasMarkedText() != true else { return }
      guard field.stringValue != text || editor.map({ $0.string != text }) == true else { return }
      synchronizing = true
      defer { synchronizing = false }
      let selection = editor?.selectedRange()
      field.stringValue = text
      if let editor {
        if editor.string != text { editor.string = text }
        if let selection {
          let count = (text as NSString).length
          let location =
            selection.location == NSNotFound ? count : max(0, min(selection.location, count))
          editor.setSelectedRange(
            NSRange(location: location, length: max(0, min(selection.length, count - location))))
        }
      }
    }
    func setFocused(_ focused: Bool) { if parent.focused != focused { parent.focused = focused } }
    func controlTextDidBeginEditing(_ notification: Notification) {
      (notification.object as? NativeLargeSearchField)?.reportFocus()
    }
    func controlTextDidEndEditing(_ notification: Notification) { setFocused(false) }
    func controlTextDidChange(_ notification: Notification) {
      guard !synchronizing, let field = notification.object as? NSSearchField else { return }
      if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
      let value = nativeLimitedText(field.stringValue, utf16Limit: parent.maxLength)
      if value != field.stringValue { field.stringValue = value }
      parent.text = value
    }
  }
}

final class NativeLargeSearchField: NSSearchField {
  static let controlHeight: CGFloat = 44
  var onFocusChanged: ((Bool) -> Void)?
  private var pendingFocus = false
  private var focusObservers: [NSObjectProtocol] = []
  func reportFocus() {
    guard let window, let editor = currentEditor() else {
      onFocusChanged?(false)
      return
    }
    onFocusChanged?(window.isKeyWindow && editor === window.firstResponder)
  }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    DispatchQueue.main.async { [weak self] in self?.reportFocus() }
    return accepted
  }
  func cancelKeyboardFocus() { pendingFocus = false }
  func requestKeyboardFocus() {
    pendingFocus = true
    DispatchQueue.main.async { [weak self] in self?.fulfillPendingFocus() }
  }
  private func fulfillPendingFocus() {
    guard pendingFocus, let window, window.isKeyWindow, window.attachedSheet == nil,
      !((window.firstResponder as? NSTextView)?.hasMarkedText() ?? false)
    else { return }
    if window.makeFirstResponder(self) {
      pendingFocus = false
      reportFocus()
    }
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    focusObservers.forEach(NotificationCenter.default.removeObserver)
    focusObservers.removeAll()
    if let window {
      for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
        focusObservers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
              self?.fulfillPendingFocus()
              self?.reportFocus()
            }
          })
      }
      DispatchQueue.main.async { [weak self] in
        self?.fulfillPendingFocus()
        self?.reportFocus()
      }
    }
  }
  deinit { focusObservers.forEach(NotificationCenter.default.removeObserver) }
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: Self.controlHeight)
  }
  override var searchTextBounds: NSRect {
    (cell as? NSSearchFieldCell)?.searchTextRect(forBounds: bounds) ?? super.searchTextBounds
  }
  override var searchButtonBounds: NSRect {
    (cell as? NSSearchFieldCell)?.searchButtonRect(forBounds: bounds) ?? super.searchButtonBounds
  }
  override var cancelButtonBounds: NSRect {
    (cell as? NSSearchFieldCell)?.cancelButtonRect(forBounds: bounds) ?? super.cancelButtonBounds
  }
  private var bezel: NSBezierPath {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    return NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
  }
  override func draw(_ dirtyRect: NSRect) {
    let path = bezel
    NSColor.controlBackgroundColor.setFill()
    path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 1
    path.stroke()
    super.draw(dirtyRect)
  }
}

/// The same public metrics position native drawing, button hit targets, and the
/// field editor, so typed text and IME composition align with the placeholder.
final class NativeLargeSearchFieldCell: NSSearchFieldCell {
  override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
    drawInterior(withFrame: cellFrame, in: controlView)
  }
  override var cellSize: NSSize {
    NSSize(width: super.cellSize.width, height: NativeLargeSearchField.controlHeight)
  }
  override func cellSize(forBounds rect: NSRect) -> NSSize {
    NSSize(
      width: super.cellSize(forBounds: rect).width, height: NativeLargeSearchField.controlHeight)
  }
  override func drawingRect(forBounds rect: NSRect) -> NSRect { searchTextRect(forBounds: rect) }
  override func searchTextRect(forBounds rect: NSRect) -> NSRect {
    let font = self.font ?? NSFont.systemFont(ofSize: 20)
    let height = min(
      max(0, rect.height - 12), max(24, ceil(font.ascender - font.descender + font.leading)))
    return NSRect(
      x: rect.minX + 38, y: rect.midY - height / 2, width: max(0, rect.width - 76), height: height)
  }
  override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
    NSRect(x: rect.minX + 12, y: rect.midY - 10, width: 20, height: 20)
  }
  override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
    NSRect(x: rect.maxX - 32, y: rect.midY - 10, width: 20, height: 20)
  }
}

struct NativeShortcutRecorder: NSViewRepresentable {
  var value: String
  var disabled = false
  var onRecord: (String) -> Void
  func makeNSView(context: Context) -> NativeShortcutCaptureView { NativeShortcutCaptureView() }
  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NativeShortcutCaptureView, context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 250, height: proposal.height ?? 30)
  }
  func updateNSView(_ view: NativeShortcutCaptureView, context: Context) {
    view.value = value
    view.enabled = !disabled
    view.record = onRecord
    view.needsDisplay = true
  }
}
final class NativeShortcutCaptureView: NSView {
  var value = ""
  var enabled = true
  var recording = false
  var record: ((String) -> Void)?
  override var acceptsFirstResponder: Bool { enabled }
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Записать сочетание клавиш")
  }
  required init?(coder: NSCoder) { super.init(coder: coder) }
  override var intrinsicContentSize: NSSize { NSSize(width: 250, height: 30) }
  override func mouseDown(with event: NSEvent) { if enabled { window?.makeFirstResponder(self) } }
  override func becomeFirstResponder() -> Bool {
    recording = true
    needsDisplay = true
    return true
  }
  override func resignFirstResponder() -> Bool {
    recording = false
    needsDisplay = true
    return true
  }
  override func accessibilityPerformPress() -> Bool {
    guard enabled else { return false }
    window?.makeFirstResponder(self)
    return true
  }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 1, dy: 1)
    NSColor.controlBackgroundColor.setFill()
    let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    path.fill()
    (recording ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
    path.lineWidth = recording ? 2 : 1
    path.stroke()
    let label =
      recording
      ? "Нажмите сочетание клавиш…" : value.isEmpty ? "Не назначено" : nativeShortcutLabel(value)
    label.draw(
      in: rect.insetBy(dx: 8, dy: 6),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: enabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
      ])
    setAccessibilityValue(label)
  }
  override func keyDown(with event: NSEvent) {
    if event.isARepeat { return }
    if event.keyCode == 48 {
      window?.selectNextKeyView(self)
      return
    }
    if event.keyCode == 53 {
      window?.makeFirstResponder(nil)
      return
    }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard !flags.intersection([.command, .control, .option]).isEmpty else { return }
    let letters: [UInt16: String] = [
      0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
      12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
      37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
      22: "6", 26: "7", 28: "8", 25: "9", 29: "0", 49: "Space", 122: "F1", 120: "F2", 99: "F3",
      118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11",
      111: "F12",
    ]
    guard let key = letters[event.keyCode] else { return }
    var modifiers: [String] = []
    if flags.contains(.command) { modifiers.append("CommandOrControl") }
    if flags.contains(.control) { modifiers.append("Control") }
    if flags.contains(.option) { modifiers.append("Alt") }
    if flags.contains(.shift) { modifiers.append("Shift") }
    record?((modifiers + [key]).joined(separator: "+"))
    window?.makeFirstResponder(nil)
  }
}

/// Icons use immutable data URLs. Keeping their decoded images avoids rebuilding
/// an NSImage every time selection or unrelated shelf state changes. File paths
/// intentionally bypass this cache because their contents may change in place.
@MainActor final class NativeImageCache {
  static let shared = NativeImageCache()
  private struct Entry {
    var image: NSImage?
    var cost: Int
    var accessed: Int
  }
  private var entries: [String: Entry] = [:]
  private var clock = 0
  let maximumEntries: Int
  let maximumBytes: Int
  let maximumEntryBytes: Int
  let maximumDataURLBytes: Int
  private(set) var retainedBytes = 0
  private(set) var decodeCount = 0
  var count: Int { entries.count }
  init(
    maximumEntries: Int = 128, maximumBytes: Int = 8 * 1024 * 1024,
    maximumEntryBytes: Int = 1024 * 1024, maximumDataURLBytes: Int = 256 * 1024
  ) {
    self.maximumEntries = max(0, maximumEntries)
    self.maximumBytes = max(0, maximumBytes)
    self.maximumEntryBytes = max(0, maximumEntryBytes)
    self.maximumDataURLBytes = max(0, maximumDataURLBytes)
  }
  func image(_ value: String) -> NSImage? {
    guard value.hasPrefix("data:image/") else { return nil }
    clock += 1
    if var entry = entries[value] {
      entry.accessed = clock
      entries[value] = entry
      return entry.image
    }
    let data = value.firstIndex(of: ",").flatMap {
      Data(base64Encoded: String(value[value.index(after: $0)...]))
    }
    let image: NSImage?
    if let data {
      decodeCount += 1
      image = NSImage(data: data)
    } else {
      image = nil
    }
    // Large clipboard images remain usable without retaining them in an
    // icon cache. The budget includes the URL, compressed data and pixels.
    guard value.utf8.count <= maximumDataURLBytes else { return image }
    var cost = value.utf8.count + (data?.count ?? 0)
    if let image {
      for representation in image.representations {
        let (pixels, overflow) = representation.pixelsWide.multipliedReportingOverflow(
          by: representation.pixelsHigh)
        guard !overflow, pixels >= 0, pixels <= maximumEntryBytes / 4 else { return image }
        cost += pixels * 4
        guard cost <= maximumEntryBytes else { return image }
      }
    }
    guard maximumEntries > 0, cost <= maximumEntryBytes, cost <= maximumBytes else { return image }
    while entries.count >= maximumEntries || retainedBytes + cost > maximumBytes {
      guard let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed }) else { break }
      retainedBytes -= oldest.value.cost
      entries.removeValue(forKey: oldest.key)
    }
    entries[value] = Entry(image: image, cost: cost, accessed: clock)
    retainedBytes += cost
    return image
  }
}

@MainActor func nativeImage(_ value: String) -> NSImage? {
  if value.hasPrefix("data:image/") { return NativeImageCache.shared.image(value) }
  if value.hasPrefix("data:"), let comma = value.firstIndex(of: ","),
    let data = Data(base64Encoded: String(value[value.index(after: comma)...]))
  {
    return NSImage(data: data)
  }
  if let url = URL(string: value), url.isFileURL { return NSImage(contentsOf: url) }
  if value.hasPrefix("/") { return NSImage(contentsOfFile: value) }
  return nil
}

/// Observe only the scroll view that owns this representable. Using its native
/// clip view preserves pixel scroll position when a shelf session is resumed.
struct NativeScrollPositionBridge: NSViewRepresentable {
  @Binding var offset: CGFloat
  var token: String
  func makeNSView(context: Context) -> NativeScrollObserverView {
    let view = NativeScrollObserverView()
    view.coordinator = context.coordinator
    return view
  }
  func updateNSView(_ view: NativeScrollObserverView, context: Context) {
    context.coordinator.parent = self
    if context.coordinator.token != token {
      context.coordinator.token = token
      context.coordinator.needsRestore = true
    }
    view.connect()
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  static func dismantleNSView(_ view: NativeScrollObserverView, coordinator: Coordinator) {
    coordinator.disconnect()
  }
  @MainActor final class Coordinator {
    var parent: NativeScrollPositionBridge
    var token = ""
    var needsRestore = true
    var restoring = false
    weak var scrollView: NSScrollView?
    var observer: NSObjectProtocol?
    init(_ parent: NativeScrollPositionBridge) { self.parent = parent }
    func disconnect() {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      scrollView = nil
    }
    func connect(_ scroll: NSScrollView) {
      if scrollView !== scroll {
        disconnect()
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
          forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self, weak scroll] _ in
          MainActor.assumeIsolated {
            guard let self, let scroll, !self.restoring, !self.needsRestore else { return }
            let value = scroll.contentView.bounds.origin.y
            if abs(self.parent.offset - value) > 0.5 { self.parent.offset = value }
          }
        }
      }
      if needsRestore {
        needsRestore = false
        restoring = true
        let value = parent.offset
        DispatchQueue.main.async { [weak self, weak scroll] in
          guard let self, let scroll else { return }
          let maximum = max(
            0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
          scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, value))))
          scroll.reflectScrolledClipView(scroll.contentView)
          self.restoring = false
        }
      }
    }
  }
}
final class NativeScrollObserverView: NSView {
  var coordinator: NativeScrollPositionBridge.Coordinator?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    connect()
  }
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    connect()
  }
  func connect() {
    var ancestor = superview
    while let view = ancestor {
      if let scroll = view as? NSScrollView {
        coordinator?.connect(scroll)
        return
      }
      ancestor = view.superview
    }
  }
}

func nativeLimitedText(_ text: String, utf16Limit: Int) -> String {
  guard text.utf16.count > utf16Limit else { return text }
  var count = 0
  var result = String.UnicodeScalarView()
  for scalar in text.unicodeScalars {
    let width = scalar.value > 0xffff ? 2 : 1
    guard count + width <= utf16Limit else { break }
    result.append(scalar)
    count += width
  }
  return String(result)
}
