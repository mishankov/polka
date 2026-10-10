import AppKit
import XCTest

@testable import PolkaApp

final class MediaIndicatorGeometryTests: XCTestCase {
  func testSidesAndBottomTouchIndependentPhotographedHousing() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appendingPathComponent(
        "tests/fixtures/media-indicator/macbook-photo.json"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let edge = try XCTUnwrap(object["leftEdge"] as? [[Double]])
    let measured = try XCTUnwrap(object["measuredRange"] as? [Int])
    for factor: CGFloat in [0.8, 1, 1.25] {
      let geometry = fixture(width: 185 * factor, height: 33.5 * factor, scale: 2)
      let stroke = geometry.contour.cgPath.copy(
        strokingWithWidth: geometry.strokeWidth,
        lineCap: .butt, lineJoin: .round, miterLimit: 10)
      for index in measured[0]...measured[1] {
        // The requested straight upper sides deliberately omit the photo's
        // outward-flared shoulders. Keep checking its vertical sides/bottom.
        guard edge[index][0] >= -0.01 else { continue }
        let point = CGPoint(x: edge[index][0] * factor, y: edge[index][1] * factor)
        let dx = edge[index + 1][0] - edge[index - 1][0]
        let dy = edge[index + 1][1] - edge[index - 1][1]
        let length = hypot(dx, dy)
        // Test the first backing pixel outside the photographed housing.
        // Its source points are independent of the renderer's circle radii.
        let x = point.x - dy / length * 0.5
        let y = point.y + dx / length * 0.5
        XCTAssertTrue(
          stroke.contains(CGPoint(x: geometry.notch.minX + x, y: y)),
          "Detached outline at photo point \(index), scale \(factor)")
        XCTAssertTrue(stroke.contains(CGPoint(x: geometry.notch.maxX - x, y: y)))
      }
    }
  }

  func testStrokeFitsNarrowWideAndScaledFixtures() {
    for width: CGFloat in [140, 185, 240] {
      for factor: CGFloat in [0.8, 1, 1.25] {
        for scale: CGFloat in [1, 1.5, 2] {
          let geometry = fixture(width: width * factor, height: 32 * factor, scale: scale)
          let notch = geometry.notch
          let stroke = geometry.contour.cgPath.copy(
            strokingWithWidth: geometry.strokeWidth,
            lineCap: .butt, lineJoin: .round, miterLimit: 10)
          XCTAssertTrue(geometry.hasNotch)
          XCTAssertEqual(geometry.strokeWidth, 4)
          XCTAssertEqual(geometry.hardwareOverlap, 1)
          XCTAssertEqual(geometry.gap, 0, "No wallpaper seam between the stroke and housing")
          let bounds = stroke.boundingBoxOfPath
          XCTAssertGreaterThanOrEqual(bounds.minX, 0)
          XCTAssertEqual(bounds.minY, notch.minY, accuracy: 0.00001)
          XCTAssertLessThanOrEqual(bounds.maxX, geometry.panelFrame.width)
          XCTAssertLessThanOrEqual(bounds.maxY, geometry.panelFrame.height)
          XCTAssertFalse(
            stroke.contains(CGPoint(x: notch.midX, y: notch.midY)),
            "The indicator must not fill the housing")
          // Test the visible stroke against distances from the *hardware*
          // sides and bottom, not from the path's control points.
          for distance: CGFloat in [
            -1.25, -0.5, 0.25, 1, 2.5, 3.25,
          ] {
            let expected =
              distance > -geometry.hardwareOverlap
              && distance < geometry.strokeWidth - geometry.hardwareOverlap
            XCTAssertEqual(
              stroke.contains(CGPoint(x: notch.minX - distance, y: notch.midY)), expected)
            XCTAssertEqual(
              stroke.contains(CGPoint(x: notch.maxX + distance, y: notch.midY)), expected)
            XCTAssertEqual(
              stroke.contains(CGPoint(x: notch.midX, y: notch.maxY + distance)), expected)
            // A circular lower corner must have the same gap and thickness.
            let radius = geometry.bottomRadius + distance
            let diagonal = radius / sqrt(2)
            XCTAssertEqual(
              stroke.contains(
                CGPoint(
                  x: notch.minX + geometry.bottomRadius - diagonal,
                  y: notch.maxY - geometry.bottomRadius + diagonal)), expected)
          }
        }
      }
    }
  }

  func testUpperSidesAreStraightToTheDisplayEdge() {
    let geometry = fixture(width: 185, height: 33.5, scale: 2)
    let notch = geometry.notch
    let stroke = geometry.contour.cgPath.copy(
      strokingWithWidth: geometry.strokeWidth,
      lineCap: .butt, lineJoin: .round, miterLimit: 10)
    // Check every upper backing-pixel row against fixed straight boundaries.
    // A curved shoulder would protrude or leave gaps at these samples.
    for y in stride(from: CGFloat(0.25), to: notch.midY, by: 0.5) {
      for distance: CGFloat in [-1.25, -0.5, 0.25, 1.5, 2.75, 3.25, 6] {
        let expected = distance > -1 && distance < 3
        XCTAssertEqual(stroke.contains(CGPoint(x: notch.minX - distance, y: y)), expected)
        XCTAssertEqual(stroke.contains(CGPoint(x: notch.maxX + distance, y: y)), expected)
      }
    }
    XCTAssertFalse(stroke.contains(CGPoint(x: notch.midX, y: 0.25)))
  }

  func testGlobalCoordinatesAndClampedPanelDoNotRecenterTheNotch() {
    let screen = CGRect(x: -1800, y: 250, width: 1600, height: 1000)
    let geometry = NativeMediaIndicatorGeometry(
      screenFrame: screen,
      leftArea: CGRect(x: screen.minX, y: 1218, width: 30, height: 32),
      rightArea: CGRect(x: screen.minX + 210, y: 1218, width: 1390, height: 32),
      safeTop: 32, scale: 2)
    XCTAssertEqual(geometry.panelFrame.minX, screen.minX)
    XCTAssertEqual(geometry.panelFrame.maxY, screen.maxY)
    XCTAssertEqual(geometry.notch.minX + geometry.panelFrame.minX, screen.minX + 30)
    XCTAssertEqual(geometry.notch.width, 180)
    XCTAssertNotEqual(geometry.notch.midX, geometry.panelFrame.width / 2)
  }

  @MainActor func testRetinaHalfPointNotchSurvivesAppKitWindowRounding() {
    let geometry = fixture(width: 185, height: 33.5, scale: 2)
    let panel = NativeMediaIndicatorPanel()
    defer { panel.close() }
    panel.setFrame(geometry.panelFrame, display: false)
    XCTAssertEqual(panel.frame, geometry.panelFrame)
    XCTAssertEqual(panel.frame.minX + geometry.notch.minX, 762.5)
    XCTAssertEqual(panel.frame.maxY - geometry.notch.maxY, 1073.5)
    XCTAssertEqual(geometry.notch.midX + panel.frame.minX, 855)
  }

  func testNoNotchAndInvalidSafeBoundsUseFallback() {
    let screen = CGRect(x: 1400, y: -200, width: 1920, height: 1080)
    for top: CGFloat in [0, 32] {
      let geometry = NativeMediaIndicatorGeometry(
        screenFrame: screen,
        leftArea: nil, rightArea: nil, safeTop: top, scale: 2)
      XCTAssertFalse(geometry.hasNotch)
      XCTAssertTrue(geometry.contour.isEmpty)
      XCTAssertEqual(geometry.panelFrame.midX, screen.midX)
      XCTAssertEqual(geometry.panelFrame.size, CGSize(width: 116, height: 46))
    }
    XCTAssertFalse(fixture(width: -1, height: 32, scale: 2).hasNotch)
    XCTAssertFalse(fixture(width: 180, height: 0, scale: 2).hasNotch)
  }

  private func fixture(width: CGFloat, height: CGFloat, scale: CGFloat)
    -> NativeMediaIndicatorGeometry
  {
    let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    return NativeMediaIndicatorGeometry(
      screenFrame: screen,
      leftArea: CGRect(x: 0, y: 1107 - height, width: (1710 - width) / 2, height: height),
      rightArea: CGRect(
        x: (1710 + width) / 2, y: 1107 - height,
        width: (1710 - width) / 2, height: height), safeTop: height, scale: scale)
  }
}
