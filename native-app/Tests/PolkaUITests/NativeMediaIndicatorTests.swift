import AppKit
import SwiftUI
import XCTest

@testable import PolkaApp

final class NativeMediaIndicatorTests: XCTestCase {
  @MainActor func testRendererLeavesHousingAndOutsideOfStrokeTransparent() throws {
    let geometry = NativeMediaIndicatorGeometry(
      screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      leftArea: CGRect(x: 0, y: 768, width: 410, height: 32),
      rightArea: CGRect(x: 590, y: 768, width: 410, height: 32), safeTop: 32, scale: 2)
    let cases: [(NativeMediaPresentation, [CGFloat], [CGFloat])] = [
      (
        .init(camera: "active", microphone: "inactive"), [1, 81 / 255, 78 / 255],
        [1, 81 / 255, 78 / 255]
      ),
      (
        .init(camera: "inactive", microphone: "active"), [242 / 255, 163 / 255, 69 / 255],
        [242 / 255, 163 / 255, 69 / 255]
      ),
      (
        .init(camera: "active", microphone: "active"), [1, 81 / 255, 78 / 255],
        [242 / 255, 163 / 255, 69 / 255]
      ),
      (
        .init(camera: "unknown", microphone: "unknown"), [169 / 255, 175 / 255, 166 / 255],
        [169 / 255, 175 / 255, 166 / 255]
      ),
    ]
    for (state, leftColor, rightColor) in cases {
      let size = geometry.panelFrame.size
      let view = NSHostingView(
        rootView: NativeMediaIndicatorView(state: state, geometry: geometry)
          .frame(width: size.width, height: size.height))
      view.frame = CGRect(origin: .zero, size: size)
      view.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(
        NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
      bitmap.size = size
      view.cacheDisplay(in: view.bounds, to: bitmap)
      func sample(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
      }
      let notch = geometry.notch
      for (x, expected) in [(notch.minX + 30, leftColor), (notch.maxX - 30, rightColor)] {
        let color = try sample(x, notch.maxY + 1.5)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.02)
        XCTAssertEqual(color.redComponent, expected[0], accuracy: 0.06)
        XCTAssertEqual(color.greenComponent, expected[1], accuracy: 0.06)
        XCTAssertEqual(color.blueComponent, expected[2], accuracy: 0.06)
        XCTAssertEqual(
          try sample(x, notch.maxY + 4).alphaComponent, 0, accuracy: 0.02,
          "A broad halo must not extend below the contour")
      }
      XCTAssertEqual(
        try sample(notch.midX, notch.midY).alphaComponent, 0, accuracy: 0.02,
        "The renderer must stroke the path, rather than fill the housing")
      XCTAssertEqual(try sample(notch.minX - 5, notch.midY).alphaComponent, 0, accuracy: 0.02)
      for y: CGFloat in [0.5, 1.5, 3.5, 6.5] {
        for x in [notch.minX - 1.5, notch.maxX + 1.5] {
          XCTAssertGreaterThan(try sample(x, y).alphaComponent, 0.9)
        }
        for x in [notch.minX - 5, notch.maxX + 5] {
          XCTAssertEqual(try sample(x, y).alphaComponent, 0, accuracy: 0.02)
        }
      }
      // SwiftUI's vertical-edge rasterization can leave a small antialiased
      // component even at this fractional-point sample. It must still cover
      // the pixel, while the surrounding samples above remain transparent.
      XCTAssertGreaterThan(try sample(notch.minX - 1.5, notch.midY).alphaComponent, 0.9)
      XCTAssertGreaterThan(
        try sample(notch.minX, notch.midY).alphaComponent, 0.9,
        "Wider stroke must overlap the housing so small contour errors are covered")
    }
  }

  @MainActor func testOverlayCannotTakeFocusOrMouseEvents() {
    _ = NSApplication.shared
    let panel = NativeMediaIndicatorPanel()
    defer { panel.close() }
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertFalse(panel.isOpaque)
    XCTAssertFalse(panel.hasShadow)
    XCTAssertEqual(panel.sharingType, .none)
    XCTAssertEqual(panel.level, .screenSaver)
    XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
  }

  func testEveryDeviceStateRemainsExplicitInAccessibilityLabel() {
    for camera in ["active", "inactive", "unknown", "disabled"] {
      for microphone in ["active", "inactive", "unknown", "disabled"] {
        let state = NativeMediaPresentation(camera: camera, microphone: microphone)
        XCTAssertTrue(state.label.contains("Камера:"))
        XCTAssertTrue(state.label.contains("Микрофон:"))
        if [camera, microphone].contains("unknown") {
          XCTAssertTrue(state.label.contains("статус недоступен"))
        }
        if [camera, microphone].contains("disabled") {
          XCTAssertTrue(state.label.contains("отслеживание выключено"))
        }
        XCTAssertEqual(
          state.visible,
          [camera, microphone].contains {
            $0 == "active" || $0 == "unknown"
          })
      }
    }
  }
}
