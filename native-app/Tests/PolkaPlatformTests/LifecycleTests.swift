import PolkaCore
import XCTest

final class LifecycleTests: XCTestCase {
  func testCloseDuringPreparationRejectsLateCommitAndFinishesOnlyOnce() {
    let life = ShelfLifecycle()
    let (opening, _) = life.begin(.clipboard, now: 0)
    XCTAssertEqual(life.phase, .preparing)
    XCTAssertTrue(life.close(now: 1))
    let closingRevision = life.revision
    XCTAssertFalse(life.requested)
    XCTAssertFalse(life.close(now: 2))
    XCTAssertEqual(life.revision, closingRevision)
    XCTAssertFalse(life.commit(opening.revision))
    XCTAssertFalse(life.finishClose(opening.revision))
    XCTAssertTrue(life.finishClose(closingRevision))
    XCTAssertFalse(life.finishClose(closingRevision))
    XCTAssertEqual(life.phase, .hidden)
  }
  func testReopenDuringClosingCannotBeHiddenByOldAnimationCompletion() {
    let life = ShelfLifecycle()
    let (first, _) = life.begin(.files, now: 0)
    XCTAssertTrue(life.commit(first.revision))
    XCTAssertTrue(life.close(now: 1))
    let staleClose = life.revision
    let (reopened, newSession) = life.begin(nil, now: 2)
    XCTAssertTrue(newSession)
    XCTAssertEqual(reopened.sessionID, first.sessionID + 1)
    XCTAssertTrue(reopened.resumes)
    XCTAssertEqual(reopened.destination, .files)
    XCTAssertFalse(life.finishClose(staleClose))
    XCTAssertTrue(life.requested)
    XCTAssertTrue(life.commit(reopened.revision))
    XCTAssertFalse(life.finishClose(staleClose))
    XCTAssertEqual(life.phase, .open)
  }
  func testRepeatedCloseDoesNotExtendOneMinuteResumeDeadline() {
    let life = ShelfLifecycle()
    let (first, _) = life.begin(.emoji, now: 0)
    XCTAssertTrue(life.commit(first.revision))
    XCTAssertTrue(life.close(now: 100))
    XCTAssertFalse(life.close(now: 59_999))
    XCTAssertTrue(life.finishClose(life.revision))
    XCTAssertFalse(life.close(now: 60_000))
    let (entry, _) = life.begin(nil, now: 60_100)
    XCTAssertFalse(entry.resumes)
    XCTAssertEqual(entry.destination, .apps)
  }
  func testSupersededOpeningAndCloseDoNotOverrideLatestNavigation() {
    let life = ShelfLifecycle()
    let (first, _) = life.begin(.snippets, now: 0)
    let (latest, newSession) = life.begin(.emoji, now: 1)
    XCTAssertFalse(newSession)
    XCTAssertEqual(latest.sessionID, first.sessionID)
    XCTAssertFalse(life.commit(first.revision))
    XCTAssertTrue(life.commit(latest.revision))
    XCTAssertTrue(life.close(now: 2))
    let staleClose = life.revision
    let (explicit, _) = life.begin(.clipboard, now: 3)
    XCTAssertFalse(life.finishClose(staleClose))
    XCTAssertTrue(life.commit(explicit.revision))
    XCTAssertEqual(life.phase, .open)
  }
  func testResumeDeadlineAndExplicitNavigation() {
    let life = ShelfLifecycle()
    let (first, new) = life.begin(.snippets, now: 0)
    XCTAssertTrue(new)
    XCTAssertTrue(life.commit(first.revision))
    XCTAssertTrue(life.close(now: 100))
    XCTAssertTrue(life.finishClose(life.revision))
    let (resume, second) = life.begin(nil, now: 60_099)
    XCTAssertTrue(second)
    XCTAssertTrue(resume.resumes)
    XCTAssertEqual(resume.destination, .snippets)
    XCTAssertTrue(life.commit(resume.revision))
    XCTAssertTrue(life.close(now: 60_100))
    let (expired, _) = life.begin(nil, now: 120_100)
    XCTAssertFalse(expired.resumes)
    XCTAssertEqual(expired.destination, .apps)
    let (explicit, _) = life.begin(.clipboard, now: 120_101)
    XCTAssertFalse(explicit.resumes)
    XCTAssertFalse(life.commit(expired.revision))
    XCTAssertTrue(life.commit(explicit.revision))
  }
  func testCancelledPreparationDoesNotExtendRememberedContext() {
    let life = ShelfLifecycle()
    let (first, _) = life.begin(.emoji, now: 0)
    XCTAssertTrue(life.commit(first.revision))
    XCTAssertTrue(life.close(now: 100))
    let (pending, _) = life.begin(.clipboard, now: 1000)
    XCTAssertTrue(life.close(now: 2000))
    XCTAssertFalse(life.commit(pending.revision))
    let (entry, _) = life.begin(nil, now: 60_100)
    XCTAssertFalse(entry.resumes)
  }
  func testHoverDelaysAndExplicitDismissal() {
    let hover = ShelfHover()
    XCTAssertNil(hover.step(now: 0, inTarget: true, inCorridor: true, visible: false))
    XCTAssertNil(hover.step(now: 349, inTarget: true, inCorridor: true, visible: false))
    XCTAssertEqual(hover.step(now: 350, inTarget: true, inCorridor: true, visible: false), true)
    hover.dismiss()
    XCTAssertNil(hover.step(now: 1000, inTarget: true, inCorridor: true, visible: false))
    XCTAssertNil(hover.step(now: 1100, inTarget: false, inCorridor: false, visible: false))
    XCTAssertNil(hover.step(now: 1200, inTarget: true, inCorridor: true, visible: false))
    XCTAssertEqual(hover.step(now: 1550, inTarget: true, inCorridor: true, visible: false), true)
    XCTAssertNil(hover.step(now: 1700, inTarget: false, inCorridor: false, visible: true))
    XCTAssertEqual(hover.step(now: 1850, inTarget: false, inCorridor: false, visible: true), false)
  }
  func testFileReferencesDetectReplacementAndNeverDeleteOriginal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sample.txt")
    try Data("old".utf8).write(to: file)
    let shelf = FileShelf()
    try shelf.add([file.path, file.path])
    XCTAssertEqual(shelf.items.count, 1)
    let id = shelf.items[0].id
    let moved = root.appendingPathComponent("moved.txt")
    try FileManager.default.moveItem(at: file, to: moved)
    try Data("replacement".utf8).write(to: file)
    shelf.refresh()
    XCTAssertFalse(shelf.items[0].available)
    XCTAssertThrowsError(try shelf.drag([id]))
    shelf.remove([id])
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
  }
}
