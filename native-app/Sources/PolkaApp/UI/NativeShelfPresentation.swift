import AppKit
import QuartzCore
import SwiftUI

/// Animate only the clipping layer. SwiftUI and native controls keep their final
/// layout while Core Animation reveals them independently of main-thread work.
final class NativeShelfPresentationView: NSView {
  static let openingDuration: TimeInterval = 0.2
  static let closingDuration: TimeInterval = 0.15
  static let animationKey = "shelf-reveal"
  let revealMask = CAShapeLayer()
  private let outline = NativeShelfOutlineView()
  private let hosting: NSHostingView<NativeShelfView>
  private var presented = false
  private var topInset: CGFloat = 0

  init(model: NativeUIModel) {
    hosting = NSHostingView(rootView: NativeShelfView(model: model))
    super.init(frame: .zero)
    wantsLayer = true
    revealMask.fillColor = NSColor.black.cgColor
    layer?.mask = revealMask
    hosting.autoresizingMask = [.width, .height]
    addSubview(hosting)
    outline.autoresizingMask = [.width, .height]
    addSubview(outline)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    hosting.frame = bounds
    outline.frame = bounds
    if revealMask.frame != bounds || revealMask.path == nil {
      // Window geometry changes are immediate, including preview/editor expansion.
      revealMask.removeAnimation(forKey: Self.animationKey)
      updateMask()
    }
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    revealMask.contentsScale = window?.backingScaleFactor ?? 1
  }

  func setPresented(
    _ visible: Bool, topInset: CGFloat, animated: Bool = true, reduceMotion: Bool? = nil
  ) {
    layoutSubtreeIfNeeded()
    guard presented != visible || self.topInset != topInset else { return }
    // Reversing a close starts at the currently displayed shape, avoiding a jump.
    let previous = revealMask.presentation()?.path ?? revealMask.path
    let visibilityChanged = presented != visible
    presented = visible
    self.topInset = topInset
    revealMask.removeAnimation(forKey: Self.animationKey)
    updateMask()
    guard visibilityChanged, animated,
      !(reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
      let previous
    else { return }
    let animation = CABasicAnimation(keyPath: "path")
    animation.fromValue = previous
    animation.toValue = revealMask.path
    animation.duration = visible ? Self.openingDuration : Self.closingDuration
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    revealMask.add(animation, forKey: Self.animationKey)
  }

  private func updateMask() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    revealMask.frame = bounds
    revealMask.path = Self.path(in: bounds, visible: presented, topInset: topInset)
    CATransaction.commit()
  }

  static func path(in bounds: CGRect, visible: Bool, topInset: CGFloat) -> CGPath {
    let width = visible ? bounds.width : min(96, bounds.width)
    let height = visible ? bounds.height : min(bounds.height, max(3, topInset))
    let left = bounds.midX - width / 2
    let right = left + width
    let top = bounds.maxY
    let bottom = top - height
    let radius = min(visible ? 22 : 12, width / 2, height / 2)
    // Identical path segments in both states are required for interpolation.
    let path = CGMutablePath()
    path.move(to: CGPoint(x: left, y: top))
    path.addLine(to: CGPoint(x: right, y: top))
    path.addLine(to: CGPoint(x: right, y: bottom + radius))
    path.addQuadCurve(
      to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
    path.addLine(to: CGPoint(x: left + radius, y: bottom))
    path.addQuadCurve(
      to: CGPoint(x: left, y: bottom + radius), control: CGPoint(x: left, y: bottom))
    path.closeSubpath()
    return path
  }

  /// An open contour keeps the shelf attached to the display edge, without a
  /// horizontal keyline crossing the hardware notch. Inset the stroke so it
  /// stays inside the reveal mask, including the rounded lower corners.
  static func outlinePath(in bounds: CGRect) -> CGPath {
    let path = CGMutablePath()
    guard bounds.width > 1, bounds.height > 1 else { return path }
    let left = bounds.minX + 0.5
    let right = bounds.maxX - 0.5
    let bottom = bounds.minY + 0.5
    let top = bounds.maxY
    let radius = min(21.5, (right - left) / 2, (top - bottom) / 2)
    path.move(to: CGPoint(x: left, y: top))
    path.addLine(to: CGPoint(x: left, y: bottom + radius))
    path.addQuadCurve(
      to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
    path.addLine(to: CGPoint(x: right - radius, y: bottom))
    path.addQuadCurve(
      to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
    path.addLine(to: CGPoint(x: right, y: top))
    return path
  }
}

/// Draw above the hosted content, while letting every pointer event through.
private final class NativeShelfOutlineView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
    context.setLineWidth(1)
    context.addPath(NativeShelfPresentationView.outlinePath(in: bounds))
    context.strokePath()
  }
}
