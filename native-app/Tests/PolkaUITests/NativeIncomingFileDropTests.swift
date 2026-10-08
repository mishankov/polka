import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import PolkaApp

private final class IncomingProviderGate: @unchecked Sendable {
  private let lock = NSLock()
  private var callback: ((Data?, Error?) -> Void)?
  var requested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return callback != nil
  }
  func provider() -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
    ) { completion in
      self.lock.lock()
      self.callback = completion
      self.lock.unlock()
      return Progress(totalUnitCount: 1)
    }
    return provider
  }
  func release(_ data: Data?) {
    lock.lock()
    let completion = callback
    callback = nil
    lock.unlock()
    completion?(data, nil)
  }
}

final class NativeIncomingFileDropTests: XCTestCase {
  @MainActor private func wait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return predicate()
  }
  @MainActor private func assertEventually(
    _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let result = await wait(predicate)
    XCTAssertTrue(result, file: file, line: line)
  }

  @MainActor func testDecodingKeepsCloseAvailableAndValidDropUsesPlatformAction() async {
    let model = NativeUIModel()
    let gate = IncomingProviderGate()
    model.present(destination: "apps")
    var received: [NativeUICommand] = []
    model.action = { received.append($0) }
    let provider = gate.provider()
    XCTAssertTrue(model.acceptIncomingFiles([provider]))
    XCTAssertTrue(model.incomingFileDropPending)
    XCTAssertFalse(model.busy, "An unresponsive provider must not disable Escape")
    XCTAssertFalse(model.acceptIncomingFiles([provider]), "Overlapping drops must not commit twice")
    await assertEventually { gate.requested }
    let url = URL(fileURLWithPath: "/synthetic/Синтетический файл.txt")
    gate.release(url.dataRepresentation)
    await assertEventually { !model.incomingFileDropPending }
    XCTAssertFalse(model.busy)
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first?.name, "shelf.files.add")
    XCTAssertEqual(received.first?.ids, [url.path])
  }

  @MainActor func testLateProviderCannotModifyReopenedShelfOrClearNewDrop() async {
    let model = NativeUIModel()
    let old = IncomingProviderGate()
    let current = IncomingProviderGate()
    model.present(destination: "files")
    let unexpected = expectation(description: "Cancelled drop must not invoke action")
    unexpected.isInverted = true
    model.action = { _ in unexpected.fulfill() }
    XCTAssertTrue(model.acceptIncomingFiles([old.provider()]))
    await assertEventually { old.requested }
    model.conceal()
    model.present(destination: "files")
    XCTAssertTrue(model.acceptIncomingFiles([current.provider()]))
    await assertEventually { current.requested }
    old.release(URL(fileURLWithPath: "/synthetic/cancelled.txt").dataRepresentation)
    await fulfillment(of: [unexpected], timeout: 0.1)
    XCTAssertTrue(model.incomingFileDropPending, "An older callback must not clear a newer drop")
    current.release(nil)
    await assertEventually { !model.incomingFileDropPending }
    XCTAssertEqual(model.error, "Перетащите локальные файлы из Finder.")
    XCTAssertFalse(model.busy)
  }

  @MainActor func testFailedCommitClearsBusyPendingAndPreservesExistingContext() async {
    let model = NativeUIModel()
    let gate = IncomingProviderGate()
    model.present(destination: "snippets")
    model.query = "draft context"
    model.action = { _ in throw NSError(domain: "Synthetic drop failure", code: 1) }
    XCTAssertTrue(model.acceptIncomingFiles([gate.provider()]))
    await assertEventually { gate.requested }
    gate.release(URL(fileURLWithPath: "/synthetic/failure.txt").dataRepresentation)
    await assertEventually { !model.incomingFileDropPending }
    XCTAssertFalse(model.busy)
    XCTAssertFalse(model.error.isEmpty)
    XCTAssertEqual(model.destination, "snippets")
    XCTAssertEqual(model.query, "draft context")
    model.busy = true
    XCTAssertFalse(model.acceptIncomingFiles([gate.provider()]))
  }
}
