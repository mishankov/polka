import AppKit
import SwiftUI

/// Keep incomplete input local until Return or focus loss; never apply partial numbers.
struct NativeScreenshotNumberField: NSViewRepresentable {
  @Binding var value: CGFloat
  let range: ClosedRange<CGFloat>
  let title: String
  let identifier: String
  let disabled: Bool
  static func committedValue(_ text: String, previous: CGFloat, range: ClosedRange<CGFloat>)
    -> CGFloat
  {
    guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite
    else { return previous }
    return min(range.upperBound, max(range.lowerBound, CGFloat(number.rounded())))
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.alignment = .right
    field.font = .systemFont(ofSize: 12)
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.commit(_:))
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.toolTip = "\(title) (\(Int(range.lowerBound))–\(Int(range.upperBound)) px)"
    field.setAccessibilityLabel(title)
    field.setAccessibilityIdentifier(identifier)
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    field.isEnabled = !disabled
    if field.currentEditor() == nil { field.stringValue = String(Int(value.rounded())) }
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: NativeScreenshotNumberField
    init(_ parent: NativeScreenshotNumberField) { self.parent = parent }
    @objc func commit(_ sender: NSTextField) {
      guard !parent.disabled else { return }
      if let editor = sender.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
      parent.value = NativeScreenshotNumberField.committedValue(
        sender.stringValue, previous: parent.value, range: parent.range)
      sender.stringValue = String(Int(parent.value.rounded()))
    }
    func controlTextDidEndEditing(_ notification: Notification) {
      if let field = notification.object as? NSTextField { commit(field) }
    }
  }
}
