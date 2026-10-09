import AppKit
import QuartzCore
import XCTest

@testable import PolkaApp

final class NativeShelfPresentationTests: XCTestCase {
  @MainActor func testRevealAnimatesMaskWithoutResizingContentOrRestartingOnNavigation() throws {
    let view = NativeShelfPresentationView(model: NativeUIModel())
    view.frame = CGRect(x: 0, y: 0, width: 560, height: 542)
    view.layoutSubtreeIfNeeded()
    view.setPresented(true, topInset: 32, reduceMotion: false)
    let animation = try XCTUnwrap(
      view.revealMask.animation(forKey: NativeShelfPresentationView.animationKey)
        as? CABasicAnimation)
    XCTAssertEqual(animation.keyPath, "path")
    XCTAssertEqual(animation.duration, NativeShelfPresentationView.openingDuration)
    let from = try XCTUnwrap(animation.fromValue) as! CGPath
    let to = try XCTUnwrap(animation.toValue) as! CGPath
    XCTAssertEqual(from.boundingBoxOfPath.height, 3)
    XCTAssertEqual(to.boundingBoxOfPath, view.bounds)
    XCTAssertTrue(view.layer?.mask === view.revealMask)
    XCTAssertEqual(view.subviews.first?.frame, view.bounds)
    view.setPresented(true, topInset: 32, reduceMotion: false)
    XCTAssertEqual(
      view.revealMask.animation(forKey: NativeShelfPresentationView.animationKey)?.beginTime,
      animation.beginTime, "Switching destinations must not restart the reveal")
    view.setPresented(false, topInset: 32, reduceMotion: false)
    let close = try XCTUnwrap(
      view.revealMask.animation(forKey: NativeShelfPresentationView.animationKey)
        as? CABasicAnimation)
    XCTAssertEqual(close.duration, NativeShelfPresentationView.closingDuration)
    XCTAssertEqual(
      view.revealMask.path?.boundingBoxOfPath, CGRect(x: 232, y: 510, width: 96, height: 32))
    XCTAssertEqual(view.subviews.first?.frame, view.bounds)
    view.setPresented(true, topInset: 32, reduceMotion: false)
    XCTAssertEqual(view.revealMask.path?.boundingBoxOfPath, view.bounds)
    XCTAssertNotNil(view.revealMask.animation(forKey: NativeShelfPresentationView.animationKey))
  }

  @MainActor func testReduceMotionImmediateCloseAndResizeDoNotLeaveAnimations() {
    let view = NativeShelfPresentationView(model: NativeUIModel())
    view.frame = CGRect(x: 0, y: 0, width: 560, height: 510)
    view.setPresented(true, topInset: 0, reduceMotion: true)
    XCTAssertNil(view.revealMask.animationKeys())
    XCTAssertEqual(view.revealMask.path?.boundingBoxOfPath, view.bounds)
    view.setPresented(false, topInset: 0, animated: false, reduceMotion: false)
    XCTAssertNil(view.revealMask.animationKeys())
    view.setPresented(true, topInset: 0, reduceMotion: false)
    view.frame.size = CGSize(width: 960, height: 680)
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    XCTAssertNil(view.revealMask.animationKeys())
    XCTAssertEqual(view.revealMask.path?.boundingBoxOfPath, view.bounds)
    XCTAssertEqual(view.subviews.first?.frame, view.bounds)
  }

  func testPathsStayTopCenteredAndHaveMatchingSegmentsForInterpolation() {
    let bounds = CGRect(x: 0, y: 0, width: 560, height: 542)
    func segments(_ path: CGPath) -> [CGPathElementType] {
      var result: [CGPathElementType] = []
      path.applyWithBlock { result.append($0.pointee.type) }
      return result
    }
    let open = NativeShelfPresentationView.path(in: bounds, visible: true, topInset: 32)
    for inset: CGFloat in [0, 32] {
      let closed = NativeShelfPresentationView.path(in: bounds, visible: false, topInset: inset)
      XCTAssertEqual(closed.boundingBoxOfPath.midX, bounds.midX)
      XCTAssertEqual(closed.boundingBoxOfPath.maxY, bounds.maxY)
      XCTAssertEqual(segments(open), segments(closed))
    }
    XCTAssertFalse(open.contains(CGPoint(x: 1, y: 1)))
    XCTAssertTrue(open.contains(CGPoint(x: 1, y: 541)))
  }
}
