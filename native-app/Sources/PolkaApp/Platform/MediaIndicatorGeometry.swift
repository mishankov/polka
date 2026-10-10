import AppKit
import SwiftUI

/// AppKit exposes the cutout's safe bounds, not its corner curves. Keep the
/// approximation and all screen-to-overlay coordinates in one place.
struct NativeMediaIndicatorGeometry {
  let panelFrame: CGRect
  /// Top-down coordinates in the overlay's content view.
  let notch: CGRect
  let strokeWidth: CGFloat
  let gap: CGFloat
  let hardwareOverlap: CGFloat
  let bottomRadius: CGFloat
  var hasNotch: Bool { notch.width > 0 && notch.height > 0 }

  init(screen: NSScreen) {
    self.init(
      screenFrame: screen.frame, leftArea: screen.auxiliaryTopLeftArea,
      rightArea: screen.auxiliaryTopRightArea, safeTop: screen.safeAreaInsets.top,
      scale: screen.backingScaleFactor)
  }

  init(
    screenFrame: CGRect, leftArea: CGRect?, rightArea: CGRect?, safeTop: CGFloat,
    scale: CGFloat
  ) {
    let scale = scale.isFinite && scale > 0 ? scale : 1
    strokeWidth = (4 * scale).rounded() / scale
    // The hardware photograph exposed wallpaper in the intentional 0.5 pt
    // gap. Start the visible stroke at the cutout edge instead.
    gap = 0
    // The physical housing hides the inner point of the widened stroke.
    hardwareOverlap = 1
    let width: CGFloat
    let height: CGFloat
    let center: CGFloat
    if let leftArea, let rightArea, safeTop > 0,
      rightArea.minX > leftArea.maxX,
      leftArea.maxX >= screenFrame.minX, rightArea.minX <= screenFrame.maxX
    {
      width = rightArea.minX - leftArea.maxX
      height = min(safeTop, screenFrame.height)
      center = (leftArea.maxX + rightArea.minX) / 2
    } else {
      width = 0
      height = 0
      center = screenFrame.midX
    }
    let panelWidth = min(screenFrame.width, width > 0 ? width + 124 : 116)
    let panelHeight = min(screenFrame.height, max(46, height + gap + strokeWidth + 2))
    // NSWindow rounds frames to whole points, even on Retina. Integralize
    // first, then preserve the fractional hardware position inside the panel.
    panelFrame =
      CGRect(
        x: max(screenFrame.minX, min(screenFrame.maxX - panelWidth, center - panelWidth / 2)),
        y: screenFrame.maxY - panelHeight, width: panelWidth, height: panelHeight
      ).integral
    notch = CGRect(
      x: center - width / 2 - panelFrame.minX,
      y: panelFrame.maxY - screenFrame.maxY, width: width, height: height)
    // Refined against the independent photo trace, not a mask made from
    // these same radii. Scale with housing height at other display settings.
    // These remain estimates (see docs/media-indicator.md).
    bottomRadius = min(height * 0.30, width / 4)
  }

  var contour: Path {
    guard hasNotch else { return Path() }
    return Self.contour(
      notch: notch, bottomRadius: bottomRadius,
      offset: gap + strokeWidth / 2 - hardwareOverlap)
  }

  /// Straight sides reach the display edge; only the bottom corners curve.
  /// Offset the lower arcs to preserve the stroke's distance from the housing.
  static func contour(
    notch: CGRect, bottomRadius: CGFloat,
    offset: CGFloat
  ) -> Path {
    let left = notch.minX
    let right = notch.maxX
    let bottom = notch.maxY
    let lower = bottomRadius + offset
    var path = Path()
    path.move(to: CGPoint(x: left - offset, y: notch.minY))
    path.addLine(to: CGPoint(x: left - offset, y: bottom - bottomRadius))
    path.addArc(
      center: CGPoint(x: left + bottomRadius, y: bottom - bottomRadius),
      radius: lower, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
    path.addLine(to: CGPoint(x: right - bottomRadius, y: bottom + offset))
    path.addArc(
      center: CGPoint(x: right - bottomRadius, y: bottom - bottomRadius),
      radius: lower, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
    path.addLine(to: CGPoint(x: right + offset, y: notch.minY))
    return path
  }
}

final class NativeMediaIndicatorPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    sharingType = .none
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
  }
}
