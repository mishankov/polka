import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeBrowseResumeTests: XCTestCase {
  @MainActor func testEveryShelfAppRestoresAfterFullyClosingAndExpiresAtOneMinute() {
    for destination in [ShelfDestination.apps, .clipboard, .snippets, .emoji, .files] {
      let lifecycle = ShelfLifecycle()
      let model = NativeUIModel()
      let start = Date(timeIntervalSince1970: 100)
      let (initial, _) = lifecycle.begin(destination, now: 0)
      XCTAssertTrue(lifecycle.commit(initial.revision))
      model.present(destination: destination.rawValue, now: start)
      model.query = "Remembered query"
      model.selectedID = "remembered-selection"
      model.listScrollOffset = 320
      model.emojiCategory = "Symbols"
      model.emojiTone = "all"
      XCTAssertTrue(lifecycle.close(now: 1000))
      model.conceal(now: start.addingTimeInterval(1))
      XCTAssertTrue(lifecycle.finishClose(lifecycle.revision))
      let (reopened, _) = lifecycle.begin(nil, now: 60_999)
      XCTAssertEqual(reopened.destination, destination)
      XCTAssertTrue(reopened.resumes)
      model.present(
        destination: reopened.destination.rawValue, resume: reopened.resumes,
        now: start.addingTimeInterval(60.999))
      XCTAssertEqual(model.query, "Remembered query")
      XCTAssertEqual(model.selectedID, "remembered-selection")
      XCTAssertEqual(model.listScrollOffset, 320)
      XCTAssertEqual(model.emojiCategory, "Symbols")
      XCTAssertTrue(lifecycle.commit(reopened.revision))
      XCTAssertTrue(lifecycle.close(now: 61_000))
      model.conceal(now: start.addingTimeInterval(61))
      XCTAssertTrue(lifecycle.finishClose(lifecycle.revision))
      let (expired, _) = lifecycle.begin(nil, now: 121_000)
      XCTAssertEqual(expired.destination, .apps)
      XCTAssertFalse(expired.resumes)
      model.present(
        destination: expired.destination.rawValue, resume: expired.resumes,
        now: start.addingTimeInterval(121))
      XCTAssertEqual(model.query, "")
      XCTAssertNil(model.selectedID)
      XCTAssertEqual(model.listScrollOffset, 0)
    }
  }
  @MainActor func testFileSelectionResumeExcludesRemovedReferencesAndExplicitEntryIsFresh() {
    let model = NativeUIModel()
    let start = Date(timeIntervalSince1970: 100)
    model.files = [
      NativeUIFile(id: "kept", name: "Kept", path: "/synthetic/kept"),
      NativeUIFile(id: "removed", name: "Removed", path: "/synthetic/removed"),
    ]
    model.present(destination: "files", now: start)
    model.selectedFiles = ["kept", "removed"]
    model.fileAnchor = "removed"
    model.conceal(now: start)
    model.files.removeLast()
    model.present(destination: "files", resume: true, now: start.addingTimeInterval(2))
    XCTAssertEqual(model.selectedFiles, ["kept"])
    XCTAssertNil(model.fileAnchor)
    model.present(destination: "files", now: start.addingTimeInterval(3))
    XCTAssertTrue(model.selectedFiles.isEmpty)
  }
  @MainActor func testRestoredBrowseFilteringUpdatesWhenQueryCategoryToneAndItemsChange() {
    let model = NativeUIModel()
    model.present(destination: "clipboard")
    model.clips = [NativeUIClip(id: "a", content: "Alpha"), NativeUIClip(id: "b", content: "Beta")]
    model.query = "Alpha"
    XCTAssertEqual(model.clipResults.map(\.id), ["a"])
    model.clips[0].content = "Changed"
    XCTAssertTrue(model.clipResults.isEmpty)
    model.query = "Beta"
    XCTAssertEqual(model.clipResults.map(\.id), ["b"])
    model.snippets = [NativeUIClip(id: "snippet", content: "Beta", snippet: true)]
    model.destination = "snippets"
    XCTAssertEqual(model.clipResults.map(\.id), ["snippet"])
    var searches = 0
    model.emojiProvider = { query, category, tone in
      searches += 1
      return [NativeUIEmoji(id: "\(query):\(category):\(tone)", value: "🙂", name: "Synthetic")]
    }
    for _ in 0..<100 {
      _ = model.emojiResults
      _ = model.selectedEmoji
    }
    XCTAssertEqual(searches, 1)
    model.emojiCategory = "Symbols"
    _ = model.emojiResults
    model.emojiTone = "all"
    _ = model.emojiResults
    model.query = "heart"
    _ = model.emojiResults
    XCTAssertEqual(searches, 4)
    model.emojiProvider = { _, _, _ in [] }
    XCTAssertTrue(model.emojiResults.isEmpty)
  }
  func testExplicitDestinationOverridesRememberedShelfApp() {
    let lifecycle = ShelfLifecycle()
    let (first, _) = lifecycle.begin(.files, now: 0)
    XCTAssertTrue(lifecycle.commit(first.revision))
    XCTAssertTrue(lifecycle.close(now: 10))
    XCTAssertTrue(lifecycle.finishClose(lifecycle.revision))
    let (explicit, _) = lifecycle.begin(.apps, now: 11)
    XCTAssertEqual(explicit.destination, .apps)
    XCTAssertFalse(explicit.resumes)
  }
}
