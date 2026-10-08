import AppKit
import Combine
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeLauncherPerformanceTests: XCTestCase {
  @MainActor func testSelectionAndRenderingReuseSearchWhileInputChangesStayFresh() {
    let model = NativeUIModel()
    var searches = 0
    model.searchProvider = { [weak model] query in
      searches += 1
      return [
        NativeUISearchRow(
          id: query, kind: "app",
          title:
            "\(query):\(model?.clips.count ?? 0):\(model?.snippets.count ?? 0):\(model?.apps.count ?? 0)"
        )
      ]
    }
    XCTAssertEqual(model.searchResults.first?.title, ":0:0:0")
    for n in 0..<300 {
      model.selectedID = "synthetic:\(n)"
      _ = model.selectedSearch
      _ = model.searchResults
    }
    model.busy = true
    model.notice = "synthetic notice"
    _ = model.searchResults
    XCTAssertEqual(searches, 1, "Hover and rendering must not repeat launcher ranking")
    model.query = "needle"
    XCTAssertEqual(model.searchResults.first?.id, "needle")
    XCTAssertEqual(searches, 2)
    model.clips = [NativeUIClip(id: "clip")]
    XCTAssertEqual(model.searchResults.first?.title, "needle:1:0:0")
    model.snippets = [NativeUIClip(id: "snippet", snippet: true)]
    XCTAssertEqual(model.searchResults.first?.title, "needle:1:1:0")
    model.apps = [NativeUIApp(id: "app", name: "Changed app")]
    XCTAssertEqual(model.searchResults.first?.title, "needle:1:1:1")
    XCTAssertEqual(searches, 5)
    model.clips = model.clips
    model.snippets = model.snippets
    model.apps = model.apps
    _ = model.searchResults
    XCTAssertEqual(searches, 5, "Identical projections do not invalidate search")
    model.searchRevision += 1
    _ = model.searchResults
    XCTAssertEqual(
      searches, 6, "Provider-side history, usage and clock changes invalidate cached rows")
    model.searchProvider = { _ in
      [NativeUISearchRow(id: "replacement", kind: "app", title: "Replaced provider")]
    }
    XCTAssertEqual(model.searchResults.first?.id, "replacement")
  }
  @MainActor func testCalculatorStatusCachesNilAndInvalidatesWithQueryAndClock() {
    let model = NativeUIModel()
    var parses = 0
    model.calculationStatusProvider = { query in
      parses += 1
      return query.isEmpty ? nil : query
    }
    for _ in 0..<100 { XCTAssertNil(model.calculationStatus) }
    XCTAssertEqual(parses, 1)
    model.query = "12 + 3"
    XCTAssertEqual(model.calculationStatus, "12 + 3")
    model.searchRevision += 1
    XCTAssertEqual(model.calculationStatus, "12 + 3")
    XCTAssertEqual(parses, 3)
  }
  @MainActor func testUnchangedMaintenanceDoesNotPublishButHistoryChangesDo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-native-quiet-refresh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    try platform.history.initialize()
    platform.refresh()
    var publications = 0
    let subscription = platform.model.objectWillChange.sink { publications += 1 }
    for _ in 0..<10 { platform.refresh() }
    XCTAssertEqual(publications, 0, "Idle maintenance must not redraw the scroll view")
    try platform.history.add(
      .text, content: "Synthetic refresh record", preview: "Synthetic refresh record")
    platform.refresh()
    XCTAssertGreaterThan(publications, 0)
    XCTAssertEqual(platform.model.clips.first?.content, "Synthetic refresh record")
    subscription.cancel()
    await platform.shutdown()
  }
}
