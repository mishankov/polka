import XCTest

@testable import PolkaApp

final class NativeActivationTests: XCTestCase {
  func testDelayedHideDeactivationIsIgnoredUntilRequestedActivationCompletes() {
    var transition = NativeShelfActivationTransition()
    transition.willHide()
    transition.requestFocus(revision: 41)
    // Property isActive may still be true at show; it does not complete the
    // WindowServer hide/activate sequence captured by the desktop regression.
    XCTAssertTrue(
      transition.ignoresTransientLoss(revision: 41, anotherKeyWindow: false, outsideClick: false))
    transition.cancel()  // applicationDidBecomeActive
    XCTAssertFalse(
      transition.ignoresTransientLoss(revision: 41, anotherKeyWindow: false, outsideClick: false))
  }
  func testRealOutsideClicksAndOwnedWindowBlurRemainDismissibleDuringActivation() {
    var transition = NativeShelfActivationTransition()
    transition.willHide()
    transition.requestFocus(revision: 2)
    XCTAssertFalse(
      transition.ignoresTransientLoss(revision: 2, anotherKeyWindow: false, outsideClick: true))
    XCTAssertFalse(
      transition.ignoresTransientLoss(revision: 2, anotherKeyWindow: true, outsideClick: false))
  }
  func testNewPresentationReplacesActivationRevisionAndExplicitCloseCancelsHold() {
    var transition = NativeShelfActivationTransition()
    transition.willHide()
    transition.requestFocus(revision: 2)
    transition.requestFocus(revision: 3)
    XCTAssertFalse(
      transition.ignoresTransientLoss(revision: 2, anotherKeyWindow: false, outsideClick: false))
    XCTAssertTrue(
      transition.ignoresTransientLoss(revision: 3, anotherKeyWindow: false, outsideClick: false))
    transition.cancel()  // Escape, Close Window, Settings, incoming drag, or Quit.
    XCTAssertFalse(
      transition.ignoresTransientLoss(revision: 3, anotherKeyWindow: false, outsideClick: false))
    transition.requestFocus(revision: 4)
    XCTAssertEqual(transition.state, .idle)
  }
  func testOrdinaryOpeningNeverSuppressesFocusLoss() {
    var transition = NativeShelfActivationTransition()
    transition.requestFocus(revision: 1)
    XCTAssertFalse(
      transition.ignoresTransientLoss(revision: 1, anotherKeyWindow: false, outsideClick: false))
    transition.willHide()
    // A hidden app with no new shelf request has no dismissal immunity either.
    XCTAssertFalse(
      transition.ignoresTransientLoss(revision: 1, anotherKeyWindow: false, outsideClick: false))
  }
}
