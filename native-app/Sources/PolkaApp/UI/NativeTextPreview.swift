import AppKit
import PolkaCore
import SwiftUI

struct NativeColorSwatch: View {
  var color: ClipboardColor
  var body: some View {
    Canvas { context, size in
      let cell: CGFloat = size.height > 40 ? 12 : 6
      for row in 0..<Int(ceil(size.height / cell)) {
        for column in 0..<Int(ceil(size.width / cell)) {
          context.fill(
            Path(
              CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
            with: .color((row + column).isMultiple(of: 2) ? Color(white: 0.8) : Color(white: 0.5)))
        }
      }
      context.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .color(
          Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)))
    }.clipShape(RoundedRectangle(cornerRadius: 5)).overlay {
      RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.2), lineWidth: 1)
    }.accessibilityLabel("Цвет · непрозрачность \(Int((color.alpha * 100).rounded()))%")
  }
}

/// NSTextView provides selection, exact text, native accessibility and scrolling
/// in both directions, even for a 1 MB record or a single very long line.
struct NativePlainTextPreview: NSViewRepresentable {
  var text: String
  @Binding var scrollOffset: CGFloat
  var scrollToken: String = ""
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NativePreviewTextScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let view = NSTextView(frame: .zero)
    view.isEditable = false
    view.isSelectable = true
    view.isRichText = false
    view.isAutomaticLinkDetectionEnabled = false
    view.isAutomaticDataDetectionEnabled = false
    view.drawsBackground = false
    view.textContainerInset = NSSize(width: 16, height: 16)
    view.isHorizontallyResizable = true
    view.isVerticallyResizable = true
    view.minSize = .zero
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = false
    view.textContainer?.containerSize = view.maxSize
    view.setAccessibilityIdentifier("clipboard-preview-text")
    view.setAccessibilityLabel("Текст записи")
    scroll.documentView = view
    view.autoresizingMask = []
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NSTextView else { return }
    let position = context.coordinator.position
    position.parent = NativeScrollPositionBridge(offset: $scrollOffset, token: scrollToken)
    if position.token != scrollToken {
      position.token = scrollToken
      position.needsRestore = true
    }
    // Restore only after the text view has laid out its full document below.
    defer { position.connect(scroll) }
    guard context.coordinator.text != text else {
      return
    }
    context.coordinator.text = text
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      .foregroundColor: NSColor(white: 0.92, alpha: 1),
    ]
    let styled = NSAttributedString(string: text, attributes: attributes)
    view.textStorage?.setAttributedString(styled)
    (scroll as? NativePreviewTextScrollView)?.sizeDocument()
    view.setAccessibilityHelp("Выделите текст для копирования")
    view.setSelectedRange(NSRange(location: 0, length: 0))
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
  }
  func makeCoordinator() -> Coordinator {
    Coordinator(
      position: NativeScrollPositionBridge(offset: $scrollOffset, token: scrollToken)
        .makeCoordinator())
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.position.disconnect()
  }
  @MainActor
  final class Coordinator {
    var text: String?
    var position: NativeScrollPositionBridge.Coordinator
    init(position: NativeScrollPositionBridge.Coordinator) { self.position = position }
  }
}

final class NativePreviewTextScrollView: NSScrollView {
  override func layout() {
    super.layout()
    sizeDocument()
  }
  func sizeDocument() {
    guard let text = documentView as? NSTextView, let container = text.textContainer,
      let layout = text.layoutManager
    else { return }
    layout.ensureLayout(for: container)
    let used = layout.usedRect(for: container)
    let size = NSSize(
      width: max(contentSize.width, ceil(used.width) + text.textContainerInset.width * 2),
      height: max(contentSize.height, ceil(used.height) + text.textContainerInset.height * 2))
    text.minSize = contentSize
    if text.frame.size != size { text.setFrameSize(size) }
  }
}
