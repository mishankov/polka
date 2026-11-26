import CSQLite
import Foundation
import XCTest

@testable import PolkaCore

final class ClipboardHistoryTests: XCTestCase {
  var roots: [URL] = []
  let codec = SyntheticEncryptionCodec(key: Data(repeating: 71, count: 32))
  override func tearDown() {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
  }
  func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PolkaCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }
  func history(clock: @escaping () -> Double = { 1_800_000_000_000 }) throws -> ClipboardHistory {
    let h = ClipboardHistory(
      path: try root().appendingPathComponent("history.enc"), codec: codec, now: clock)
    try h.initialize()
    return h
  }
  func exchange(_ a: ClipboardHistory, _ b: ClipboardHistory) throws {
    for id in try b.mergeManifest(a.manifest()) {
      if let clip = a.transfer(id) { try b.receive(clip, sourceDevice: "A") }
    }
    for id in try a.mergeManifest(b.manifest()) {
      if let clip = b.transfer(id) { try a.receive(clip, sourceDevice: "B") }
    }
  }
  func testRestartRetentionDedupAndEncryptedDisk() throws {
    var time = 1_800_000_000_000.0
    let path = try root().appendingPathComponent("history.enc")
    let h = ClipboardHistory(path: path, codec: codec, now: { time })
    try h.initialize()
    try h.add(.text, content: "secret fixture", preview: "secret fixture")
    let id = clipId(.text, "secret fixture")
    try h.pin(id, pinned: true)
    time += 1
    try h.add(.text, content: "secret fixture", preview: "secret fixture")
    try h.add(.text, content: "temporary", preview: "temporary")
    XCTAssertEqual(h.snapshot().clips.count, 2)
    XCTAssertTrue(h.find(id)!.pinned)
    XCTAssertNil(String(data: try Data(contentsOf: path), encoding: .utf8))
    time += 8 * 86_400_000
    try h.prune()
    let restarted = ClipboardHistory(path: path, codec: codec, now: { time })
    try restarted.initialize()
    XCTAssertEqual(restarted.snapshot().clips.map(\.id), [id])
    XCTAssertEqual(restarted.deviceId, h.deviceId)
  }
  func testEquivalentTextVariantsDeduplicateWhilePreservingMeaningfulDifferences() throws {
    var time = 1_800_000_000_000.0
    let path = try root().appendingPathComponent("history.enc")
    let h = ClipboardHistory(path: path, codec: codec, now: { time })
    try h.initialize()

    // Confirmed duplicate-looking emoji/space/variation-selector variants collapse into one entry,
    // retaining the latest original content, refreshing recency, and preserving pin state.
    try h.add(.text, content: "❌", preview: "❌")
    try h.pin(clipId(.text, "❌"), pinned: true)
    time += 60_000
    try h.add(.text, content: "❌ ", preview: "❌ ")
    time += 60_000
    try h.add(.text, content: "❌\u{FE0F} ", preview: "❌\u{FE0F} ")
    let crossClips = h.snapshot().clips
    XCTAssertEqual(crossClips.count, 1)
    XCTAssertEqual(crossClips[0].id, clipId(.text, "❌\u{FE0F} "))
    XCTAssertEqual(crossClips[0].content, "❌\u{FE0F} ")
    XCTAssertEqual(crossClips[0].createdAt, 1_800_000_120_000.0)
    XCTAssertTrue(crossClips[0].pinned)

    // Equivalent check mark, NFC/NFD, and CRLF/LF variants each leave one entry with latest bytes.
    time += 1000
    try h.add(.text, content: "✅", preview: "✅")
    time += 1000
    try h.add(.text, content: "✅\u{FE0F}", preview: "✅\u{FE0F}")
    time += 1000
    try h.add(.text, content: "✅ ", preview: "✅ ")

    time += 1000
    try h.add(.text, content: "caf\u{00E9}", preview: "caf\u{00E9}")
    time += 1000
    try h.add(.text, content: "cafe\u{0301}", preview: "cafe\u{0301}")

    time += 1000
    try h.add(.text, content: "line 1\r\nline 2", preview: "line 1\r\nline 2")
    time += 1000
    try h.add(.text, content: "line 1\nline 2", preview: "line 1\nline 2")

    XCTAssertEqual(h.snapshot().clips.count, 4)
    XCTAssertEqual(h.find(clipId(.text, "✅ "))?.content, "✅ ")
    XCTAssertTrue(
      try XCTUnwrap(h.find(clipId(.text, "cafe\u{0301}"))).content.utf8.elementsEqual(
        "cafe\u{0301}".utf8))
    XCTAssertEqual(h.find(clipId(.text, "line 1\nline 2"))?.content, "line 1\nline 2")

    // Meaningful distinctions remain separate.
    let distinct: [String] = [
      "  indented",
      "indented",
      " ❌",
      "❌\n",
      "echo hi",
      "echo hi\n",
      "col\t",
      "col",
      "a  b",
      "a b",
      "line1  \nline2",
      "line1\nline2",
      "first\u{2028}second ",
      "first\u{2028}second",
      "first\u{2029}second ",
      "first\u{2029}second",
      " ",
      "  ",
      "\u{2764}",
      "\u{2764}\u{FE0F}",
      "\u{2764}\u{FE0E}",
      "✅\u{FE0E}",
      "👍",
      "👍🏻",
      String(repeating: "a", count: 400) + "1",
      String(repeating: "a", count: 400) + "2",
      "Hello",
      "hello",
      "2",
      "²",
    ]
    let beforeCount = h.snapshot().clips.count
    for value in distinct {
      time += 1000
      try h.add(
        .text, content: value, preview: String(decoding: value.utf16.prefix(400), as: UTF16.self))
    }
    XCTAssertEqual(h.snapshot().clips.count, beforeCount + distinct.count)
    for value in distinct {
      XCTAssertEqual(h.find(clipId(.text, value))?.content, value)
    }

    // Snippets remain independent from clipboard history deduplication.
    let s1 = try h.createSnippet(content: "❌", name: "Cross 1")
    let s2 = try h.createSnippet(content: "❌ ", name: "Cross 2")
    XCTAssertNotEqual(s1, s2)
    XCTAssertEqual(h.snapshot().snippets.count, 2)
    XCTAssertEqual(h.find(s1)?.content, "❌")
    XCTAssertEqual(h.find(s2)?.content, "❌ ")
  }
  func testExistingDuplicateHistoryCompactsOnRestartWithoutResurrectingAcrossSync() throws {
    let time = 1_800_000_000_000.0
    let path = try root().appendingPathComponent("history.enc")
    let seed = ClipboardHistory(path: path, codec: codec, now: { time })
    try seed.initialize()
    try seed.add(.text, content: "❌", preview: "❌")
    let idOld = clipId(.text, "❌")
    let idNew = clipId(.text, "❌ ")
    let device = seed.deviceId
    // Simulate a pre-fix encrypted history file containing both equivalent variants on disk.
    var saved =
      try JSONSerialization.jsonObject(with: codec.decode(Data(contentsOf: path))) as! [String: Any]
    let stampOld: [String: Any] = ["counter": 1000, "device": device]
    let stampNew: [String: Any] = ["counter": 2000, "device": device]
    saved["clips"] = [
      [
        "id": idNew, "kind": "text", "content": "❌ ", "preview": "❌ ",
        "createdAt": 1_800_000_060_000.0, "pinned": false,
      ],
      [
        "id": idOld, "kind": "text", "content": "❌", "preview": "❌",
        "createdAt": 1_800_000_000_000.0, "pinned": true,
      ],
    ]
    saved["sync"] = [
      "device": device,
      "counter": 2000,
      "entries": [
        idOld: [
          "added": stampOld, "seen": stampOld, "pin": ["stamp": stampOld, "value": true],
        ],
        idNew: [
          "added": stampNew, "seen": stampNew, "pin": ["stamp": stampNew, "value": false],
        ],
      ],
    ]
    try codec.encode(JSONSerialization.data(withJSONObject: saved)).write(to: path)

    let migrated = ClipboardHistory(path: path, codec: codec, now: { time + 120_000 })
    try migrated.initialize()
    XCTAssertEqual(migrated.snapshot().clips.count, 1)
    let kept = try XCTUnwrap(migrated.snapshot().clips.first)
    XCTAssertEqual(kept.id, idNew)
    XCTAssertEqual(kept.content, "❌ ")
    XCTAssertTrue(kept.pinned)
    XCTAssertEqual(kept.createdAt, 1_800_000_060_000.0)
    // Old ID is tombstoned so a peer holding the old entry removes it instead of resurrecting.
    let manifest = try migrated.manifest()
    XCTAssertFalse(liveEntry(try XCTUnwrap(manifest.entries[idOld]), manifest.clear))
    XCTAssertTrue(liveEntry(try XCTUnwrap(manifest.entries[idNew]), manifest.clear))

    // Restarting again keeps the single compacted entry intact.
    let restarted = ClipboardHistory(path: path, codec: codec, now: { time + 180_000 })
    try restarted.initialize()
    XCTAssertEqual(restarted.snapshot().clips.map(\.id), [idNew])
    XCTAssertTrue(restarted.find(idNew)?.pinned == true)

    // Pre-sync legacy file without a sync section also compacts by createdAt and preserves pin.
    let legacyPath = try root().appendingPathComponent("legacy-history.enc")
    let legacySaved: [String: Any] = [
      "version": 1,
      "preferences": [
        "paused": false, "pasteOnSelect": true, "hoverEnabled": true, "retentionDays": 7,
        "accelerator": "CommandOrControl+Shift+V",
      ],
      "clips": [
        [
          "id": idOld, "kind": "text", "content": "❌", "preview": "❌",
          "createdAt": 1_800_000_000_000.0, "pinned": true,
        ],
        [
          "id": idNew, "kind": "text", "content": "❌ ", "preview": "❌ ",
          "createdAt": 1_800_000_060_000.0, "pinned": false,
        ],
      ],
    ]
    try codec.encode(JSONSerialization.data(withJSONObject: legacySaved)).write(to: legacyPath)
    let legacyMigrated = ClipboardHistory(path: legacyPath, codec: codec, now: { time + 120_000 })
    try legacyMigrated.initialize()
    XCTAssertEqual(legacyMigrated.snapshot().clips.map(\.id), [idNew])
    XCTAssertTrue(legacyMigrated.find(idNew)?.pinned == true)
  }
  func testEquivalentVariantsConvergeAcrossSyncPreservePinAndDoNotResurrect() throws {
    // Both sync directions (newer received second, and older received second) converge identically.
    for bSyncsFirst in [false, true] {
      var aTime = 1_800_000_000_000.0
      var bTime = 1_800_000_000_000.0
      let a = try history(clock: { aTime })
      let b = try history(clock: { bTime })
      try a.add(.text, content: "❌", preview: "❌")
      let idOld = clipId(.text, "❌")
      aTime += 500
      try a.pin(idOld, pinned: true)

      bTime += 60_000
      try b.add(.text, content: "❌\u{FE0F} ", preview: "❌\u{FE0F} ")
      let idNew = clipId(.text, "❌\u{FE0F} ")

      if bSyncsFirst {
        try exchange(b, a)
        try exchange(a, b)
      } else {
        try exchange(a, b)
        try exchange(b, a)
      }
      XCTAssertEqual(a.snapshot().clips.map(\.id), [idNew])
      XCTAssertEqual(b.snapshot().clips.map(\.id), [idNew])
      XCTAssertEqual(a.find(idNew)?.content, "❌\u{FE0F} ")
      XCTAssertEqual(b.find(idNew)?.content, "❌\u{FE0F} ")
      XCTAssertTrue(a.find(idNew)?.pinned == true)
      XCTAssertTrue(b.find(idNew)?.pinned == true)
      // Transfer preserves exact content-hash identity for older-peer wire validation.
      let transfer = try XCTUnwrap(a.transfer(idNew))
      XCTAssertEqual(transfer.clip.id, clipId(.text, transfer.clip.content))

      // Deleting the merged entry removes it everywhere without resurrecting the old variant.
      aTime += 10_000
      try a.remove(idNew)
      try exchange(a, b)
      XCTAssertTrue(a.snapshot().clips.isEmpty)
      XCTAssertTrue(b.snapshot().clips.isEmpty)
      // Re-exchanging manifests after deletion never resurrects either variant.
      try exchange(b, a)
      XCTAssertTrue(a.snapshot().clips.isEmpty)
      XCTAssertTrue(b.snapshot().clips.isEmpty)
    }
  }
  func testExactImageRecopyRefreshesRecencyAndPreservesPinAndCachedOCR() throws {
    var time = 1_800_000_000_000.0
    let h = try history(clock: { time })
    let content = Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString()
    try h.add(.image, content: content, preview: "data:image/png;base64,\(content)")
    let image = try XCTUnwrap(h.imageTextImages().first)
    try h.pin(image.id, pinned: true)
    let ocr = ImageText(version: "fixture", status: .ready, text: "Saved OCR", languages: ["en"])
    try h.saveImageText(image.id, incarnation: image.incarnation, result: ocr)

    time += 60_000
    try h.add(.image, content: content, preview: "data:image/png;base64,\(content)")
    let clips = h.snapshot().clips
    XCTAssertEqual(clips.count, 1)
    XCTAssertEqual(clips[0].id, image.id)
    XCTAssertEqual(clips[0].createdAt, 1_800_000_060_000.0)
    XCTAssertTrue(clips[0].pinned)
    XCTAssertEqual(clips[0].ocr, ocr)
  }
  func testDeleteOfMergedEntryTombstonesPriorEquivalentIDsAcrossOfflineRecopyAndRestart() throws {
    for bSyncsFirst in [false, true] {
      var aTime = 1_800_000_000_000.0
      var bTime = 1_800_000_000_000.0
      let aPath = try root().appendingPathComponent("a-history.enc")
      let bPath = try root().appendingPathComponent("b-history.enc")
      var a = ClipboardHistory(path: aPath, codec: codec, now: { aTime })
      let b = ClipboardHistory(path: bPath, codec: codec, now: { bTime })
      try a.initialize()
      try b.initialize()

      try a.add(.text, content: "X", preview: "X")
      try exchange(a, b)
      XCTAssertEqual(b.snapshot().clips.map(\.content), ["X"])

      // Offline: A copies equivalent "X ", restarts, B recopies "X", then A deletes "X ".
      aTime += 10_000
      try a.add(.text, content: "X ", preview: "X ")
      let aRestarted = ClipboardHistory(path: aPath, codec: codec, now: { aTime })
      try aRestarted.initialize()
      a = aRestarted

      bTime += 20_000
      try b.add(.text, content: "X", preview: "X")

      aTime += 30_000
      try a.remove(clipId(.text, "X "))

      if bSyncsFirst {
        try exchange(b, a)
        try exchange(a, b)
      } else {
        try exchange(a, b)
        try exchange(b, a)
      }
      XCTAssertTrue(a.snapshot().clips.isEmpty)
      XCTAssertTrue(b.snapshot().clips.isEmpty)

      // Copying "X" again after deletion reappears cleanly on both peers.
      bTime += 50_000
      try b.add(.text, content: "X", preview: "X")
      try exchange(b, a)
      XCTAssertEqual(a.snapshot().clips.map(\.content), ["X"])
      XCTAssertEqual(b.snapshot().clips.map(\.content), ["X"])
    }
  }
  func testOfflinePinOnSupersededVariantSurvivesManifestMergeInBothDirections() throws {
    for bSyncsFirst in [false, true] {
      for pinAfterReplacement in [true, false] {
        for recopyReplacement in [false, true] {
          var aTime = 1_800_000_000_000.0
          var bTime = 1_800_000_000_000.0
          let aPath = try root().appendingPathComponent("pin-a-history.enc")
          var a = ClipboardHistory(path: aPath, codec: codec, now: { aTime })
          try a.initialize()
          let b = try history(clock: { bTime })

          try a.add(.text, content: "X", preview: "X")
          try exchange(a, b)

          // Offline: A replaces "X" with "X " (optionally restarting and recopying "X ")
          // while B pins "X".
          aTime += 20_000
          try a.add(.text, content: "X ", preview: "X ")
          if recopyReplacement {
            let aRestarted = ClipboardHistory(path: aPath, codec: codec, now: { aTime })
            try aRestarted.initialize()
            a = aRestarted
            aTime += 5000
            try a.add(.text, content: "X ", preview: "X ")
          }
          bTime += pinAfterReplacement ? 30_000 : 10_000
          try b.pin(clipId(.text, "X"), pinned: true)

          if bSyncsFirst {
            try exchange(b, a)
            try exchange(a, b)
          } else {
            try exchange(a, b)
            try exchange(b, a)
          }
          let idNew = clipId(.text, "X ")
          XCTAssertEqual(a.snapshot().clips.map(\.id), [idNew])
          XCTAssertEqual(b.snapshot().clips.map(\.id), [idNew])
          XCTAssertTrue(a.find(idNew)?.pinned == true)
          XCTAssertTrue(b.find(idNew)?.pinned == true)

          // Explicit unpin after merge stays unpinned on further syncs.
          aTime += 40_000
          try a.pin(idNew, pinned: false)
          try exchange(a, b)
          try exchange(b, a)
          XCTAssertFalse(a.find(idNew)?.pinned == true)
          XCTAssertFalse(b.find(idNew)?.pinned == true)
        }
      }
    }

    // Explicitly deleting or clearing a pinned entry never pins a later equivalent copy.
    var time = 1_800_000_000_000.0
    let a = try history(clock: { time })
    let b = try history(clock: { time })
    try a.add(.text, content: "Y", preview: "Y")
    time += 1000
    try a.pin(clipId(.text, "Y"), pinned: true)
    try exchange(a, b)
    time += 1000
    try a.remove(clipId(.text, "Y"))
    try exchange(a, b)
    time += 1000
    try a.add(.text, content: "Y ", preview: "Y ")
    try exchange(a, b)
    XCTAssertFalse(a.find(clipId(.text, "Y "))?.pinned == true)
    XCTAssertFalse(b.find(clipId(.text, "Y "))?.pinned == true)

    time += 1000
    try a.pin(clipId(.text, "Y "), pinned: true)
    try exchange(a, b)
    time += 1000
    try a.clear()
    try exchange(a, b)
    time += 1000
    try a.add(.text, content: "Y", preview: "Y")
    try exchange(a, b)
    XCTAssertFalse(a.find(clipId(.text, "Y"))?.pinned == true)
    XCTAssertFalse(b.find(clipId(.text, "Y"))?.pinned == true)

    // Pin X, copy X , explicitly unpin X , copy X  , then sync an unrelated item:
    // the intervening explicit unpin must prevent the oldest variant's pin from returning.
    let c = try history(clock: { time })
    let d = try history(clock: { time })
    time += 1000
    try c.add(.text, content: "X", preview: "X")
    time += 1000
    try c.pin(clipId(.text, "X"), pinned: true)
    try exchange(c, d)
    time += 1000
    try c.add(.text, content: "X ", preview: "X ")
    time += 1000
    try c.pin(clipId(.text, "X "), pinned: false)
    time += 1000
    try c.add(.text, content: "X  ", preview: "X  ")
    time += 1000
    try d.add(.text, content: "unrelated", preview: "unrelated")
    try exchange(c, d)
    try exchange(d, c)
    let idThird = clipId(.text, "X  ")
    XCTAssertFalse(c.find(idThird)?.pinned == true)
    XCTAssertFalse(d.find(idThird)?.pinned == true)

    // Both start with X pinned; offline B unpins X, then A optionally recopies X before copying X :
    // the inherited pin keeps its original stamp and B's explicit unpin remains explicit across
    // recopies so B's newer unpin wins in both exchange directions.
    for recopyBeforeReplace in [false, true] {
      for bSyncsFirst in [false, true] {
        var aTime = 1_800_000_000_000.0
        var bTime = 1_800_000_000_000.0
        let peerA = try history(clock: { aTime })
        let peerB = try history(clock: { bTime })
        try peerA.add(.text, content: "X", preview: "X")
        aTime += 1000
        try peerA.pin(clipId(.text, "X"), pinned: true)
        try exchange(peerA, peerB)
        XCTAssertTrue(peerB.find(clipId(.text, "X"))?.pinned == true)

        bTime += 5000
        try peerB.pin(clipId(.text, "X"), pinned: false)
        if recopyBeforeReplace {
          aTime += 8000
          try peerA.add(.text, content: "X", preview: "X")
        }
        aTime += 10_000
        try peerA.add(.text, content: "X ", preview: "X ")

        if bSyncsFirst {
          try exchange(peerB, peerA)
          try exchange(peerA, peerB)
        } else {
          try exchange(peerA, peerB)
          try exchange(peerB, peerA)
        }
        let replacementID = clipId(.text, "X ")
        XCTAssertEqual(peerA.snapshot().clips.map(\.id), [replacementID])
        XCTAssertEqual(peerB.snapshot().clips.map(\.id), [replacementID])
        XCTAssertFalse(peerA.find(replacementID)?.pinned == true)
        XCTAssertFalse(peerB.find(replacementID)?.pinned == true)
      }
    }
  }
  func testRemoveThroughSupersededIDRemovesVisibleSurvivorFromSnapshotAndManifest() throws {
    var time = 1_800_000_000_000.0
    let h = try history(clock: { time })
    try h.add(.text, content: "Y", preview: "Y")
    let firstID = clipId(.text, "Y")
    time += 1000
    try h.add(.text, content: "Y ", preview: "Y ")
    let secondID = clipId(.text, "Y ")
    XCTAssertEqual(h.snapshot().clips.map(\.id), [secondID])

    time += 1000
    try h.remove(firstID)
    XCTAssertTrue(h.snapshot().clips.isEmpty)
    let manifest = try h.manifest()
    XCTAssertFalse(manifest.available.contains(secondID))
    XCTAssertFalse(liveEntry(try XCTUnwrap(manifest.entries[secondID]), manifest.clear))
  }
  func testStandaloneAndEditedSnippetIndependentFromHistoryAndClear() throws {
    let h = try history()
    var p = h.getPreferences()
    p.paused = true
    try h.setPreferences(p)
    let first = try h.createSnippet(content: "Address", name: " Home ")
    let second = try h.createSnippet(content: "Address", name: "Work")
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(h.snapshot().clips.count, 0)
    p.paused = false
    try h.setPreferences(p)
    try h.add(.text, content: "Address", preview: "Address")
    let sourceID = clipId(.text, "Address")
    let third = try h.edit(sourceID, content: "Edited", name: "New")
    XCTAssertEqual(h.find(sourceID)?.content, "Address")
    XCTAssertNotEqual(third, sourceID)
    XCTAssertThrowsError(
      try h.edit(first, content: "Draft", expected: SnippetExpected(content: "Old")))
    XCTAssertEqual(h.find(first)?.content, "Address")
    try h.clear()
    XCTAssertEqual(h.snapshot().clips.count, 0)
    XCTAssertEqual(h.snapshot().snippets.count, 3)
  }
  func testSnippetEditsAndQueriesPreserveJavaScriptLiteralUnicodeSemantics() throws {
    let device = UUID().uuidString.lowercased()
    XCTAssertNoThrow(try Stamp(counter: 9_007_199_252_740_991, device: device).validate())
    XCTAssertThrowsError(try Stamp(counter: 9_007_199_252_740_992, device: device).validate())
    let h = try history()
    let id = try h.createSnippet(content: "é cafe", name: "Unicode")
    XCTAssertThrowsError(
      try h.edit(
        id, content: "changed", expected: SnippetExpected(content: "e\u{301} cafe", name: "Unicode")
      ))
    try h.edit(id, content: "e\u{301} cafe", name: "Unicode")
    XCTAssertTrue(try XCTUnwrap(h.find(id)).content.utf8.elementsEqual("e\u{301} cafe".utf8))
    XCTAssertTrue(clipboardResults(h.snapshot().snippets, query: "é").isEmpty)
    XCTAssertEqual(clipboardResults(h.snapshot().snippets, query: "Unicode\u{FEFF}cafe").count, 1)
  }
  func testSnippetCapacityRejectsWithoutEvictionAndByteLimit() throws {
    let h = try history()
    for i in 0..<200 { try h.createSnippet(content: "fixture \(i)") }
    XCTAssertThrowsError(try h.createSnippet(content: "201st"))
    XCTAssertEqual(h.snapshot().snippets.count, 200)
    XCTAssertThrowsError(
      try h.edit(h.snapshot().snippets[0].id, content: String(repeating: "я", count: 600_000)))
    for i in 0..<205 { try h.add(.text, content: "clip \(i)", preview: "clip") }
    XCTAssertEqual(h.snapshot().clips.count, 200)
    XCTAssertEqual(h.snapshot().snippets.count, 200)
  }
  func testManifestSnippetEditsPinsDeletionAndClearConverge() throws {
    var aTime = 1_800_000_000_000.0
    var bTime = aTime
    let a = try history(clock: { aTime })
    let b = try history(clock: { bTime })
    try a.add(.text, content: "original", preview: "original")
    let snippet = try a.createSnippet(content: "one", name: "One")
    try exchange(a, b)
    aTime += 100
    try a.edit(snippet, content: "two", name: "Two")
    bTime += 200
    try b.pin(snippet, pinned: false)
    try exchange(a, b)
    XCTAssertEqual(a.find(snippet)?.content, b.find(snippet)?.content)
    XCTAssertEqual(a.find(snippet)?.name, b.find(snippet)?.name)
    XCTAssertEqual(a.find(snippet)?.pinned, b.find(snippet)?.pinned)
    XCTAssertEqual(b.find(snippet)?.content, "two")
    XCTAssertEqual(b.find(snippet)?.pinned, false)
    try a.clear()
    try exchange(a, b)
    XCTAssertTrue(b.snapshot().clips.isEmpty)
    XCTAssertEqual(b.snapshot().snippets.count, 1)
    XCTAssertFalse(try a.manifest(snippets: false).entries.keys.contains(snippet))
    try b.remove(snippet)
    try exchange(a, b)
    XCTAssertNil(a.find(snippet))
  }
  func testRetentionDoesNotResurrectButRemotePinRetrieves() throws {
    var aTime = 1_800_000_000_000.0
    var bTime = aTime
    let a = try history(clock: { aTime })
    let b = try history(clock: { bTime })
    try a.add(.text, content: "retained remotely", preview: "retained remotely")
    try exchange(a, b)
    let id = clipId(.text, "retained remotely")
    bTime += 8 * 86_400_000
    try b.prune()
    try exchange(a, b)
    XCTAssertNil(b.find(id))
    aTime += 100
    try a.pin(id, pinned: true)
    try exchange(a, b)
    XCTAssertEqual(b.find(id)?.pinned, true)
  }
  func testOCRLateResultCannotApplyToNewIncarnationAndNeverTransfers() throws {
    let h = try history()
    let content = Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString()
    try h.add(.image, content: content, preview: "data:image/png;base64,\(content)")
    let image = h.imageTextImages()[0]
    let text = ImageText(version: "fixture", status: .ready, text: "OCR fixture", languages: ["en"])
    try h.remove(image.id)
    try h.add(.image, content: content, preview: "data:image/png;base64,\(content)")
    try h.saveImageText(image.id, incarnation: image.incarnation, result: text)
    XCTAssertNil(h.find(image.id)?.ocr)
    try h.saveImageText(image.id, incarnation: h.imageTextImages()[0].incarnation, result: text)
    XCTAssertEqual(h.find(image.id)?.ocr?.text, "OCR fixture")
    XCTAssertNil(h.transfer(image.id)?.clip.ocr)
    XCTAssertEqual(clipboardResults(h.snapshot().clips, query: "fixture").count, 1)
  }
  func testCorruptFileNeverOverwrittenAndFailureClosesMutations() throws {
    let path = try root().appendingPathComponent("history.enc")
    let original = Data("corrupt encrypted fixture".utf8)
    try original.write(to: path)
    let h = ClipboardHistory(path: path, codec: codec)
    XCTAssertThrowsError(try h.initialize())
    XCTAssertEqual(h.storage.state().diagnostic?.stage, "decrypt")
    XCTAssertTrue(h.getPreferences().paused)
    XCTAssertThrowsError(try h.createSnippet(content: "must not persist"))
    XCTAssertEqual(try Data(contentsOf: path), original)
  }
  func testWriteFailurePreservesCommittedSnapshotAndClosesStore() throws {
    let path = try root().appendingPathComponent("history.enc")
    let h = ClipboardHistory(path: path, codec: codec)
    try h.initialize()
    try h.add(.text, content: "committed", preview: "committed")
    try FileManager.default.createDirectory(
      at: path.appendingPathExtension("tmp"), withIntermediateDirectories: true)
    XCTAssertThrowsError(try h.add(.text, content: "uncommitted", preview: "uncommitted"))
    XCTAssertEqual(h.snapshot().clips.map(\.content), ["committed"])
    XCTAssertEqual(h.storage.state().diagnostic?.stage, "write")
    XCTAssertThrowsError(try h.clear())
  }
  func testLegacyMixedCollectionMigratesWithStableMetadata() throws {
    let path = try root().appendingPathComponent("history.enc")
    let h = ClipboardHistory(path: path, codec: codec)
    try h.initialize()
    let id = try h.createSnippet(content: "legacy", name: "Legacy")
    try h.pin(id, pinned: false)
    var saved =
      try JSONSerialization.jsonObject(with: codec.decode(Data(contentsOf: path))) as! [String: Any]
    saved["clips"] = saved["snippets"]
    saved.removeValue(forKey: "snippets")
    var preferences = saved["preferences"] as! [String: Any]
    preferences.removeValue(forKey: "pasteOnSelect")
    saved["preferences"] = preferences
    try codec.encode(JSONSerialization.data(withJSONObject: saved)).write(to: path)
    let migrated = ClipboardHistory(path: path, codec: codec)
    try migrated.initialize()
    XCTAssertEqual(migrated.snapshot().clips.count, 0)
    XCTAssertEqual(migrated.snapshot().snippets.map(\.id), [id])
    XCTAssertFalse(migrated.find(id)!.pinned)
    XCTAssertTrue(migrated.getPreferences().pasteOnSelect)
    XCTAssertEqual(try migrated.manifest().entries[id]?.added, try h.manifest().entries[id]?.added)
  }
  func testSensitiveFormatsAndImagePriority() {
    XCTAssertTrue(excludedClipboardType(["org.nspasteboard.ConcealedType"]))
    XCTAssertTrue(excludedClipboardType(["com.agilebits.onepassword"]))
    XCTAssertTrue(excludedClipboardType(["org.nspasteboard.AutoGeneratedType"]))
    XCTAssertEqual(clipboardContentType(["public.file-url", "text/plain"]), "public.file-url")
    XCTAssertEqual(
      clipboardContentType(["public.file-url", "text/plain", "image/png"]), "image/png")
  }
  func testNativeV10KnownAnswerAndRejectUnknownEnvelope() throws {
    let safe = NativeKeychainCodec(password: { Data("synthetic password".utf8) })
    let plaintext = Data("{\"synthetic\":true}".utf8)
    let encrypted = try safe.encode(plaintext)
    XCTAssertEqual(
      encrypted.base64EncodedString(), "djEwJaPd3yw8w3RDXqGvgnlyb+hxG346d2cU1NsQutlCzws=")
    XCTAssertEqual(try safe.decode(encrypted), plaintext)
    XCTAssertThrowsError(try safe.decode(Data("plaintext".utf8)))
  }
  func testSerializedConcurrentCaptureAndClearAndStrictRemoteContent() throws {
    let h = try history()
    let errors = NSLock()
    var failures: [Error] = []
    DispatchQueue.concurrentPerform(iterations: 250) { i in
      do {
        if i % 17 == 0 { try h.clear() }
        try h.add(.text, content: "Concurrent \(i)", preview: "Concurrent")
      } catch {
        errors.lock()
        failures.append(error)
        errors.unlock()
      }
    }
    XCTAssertTrue(failures.isEmpty)
    XCTAssertLessThanOrEqual(h.snapshot().clips.count, 200)
    let local = try history()
    let remote = try history()
    try remote.add(.text, content: "trusted", preview: "trusted")
    let id = clipId(.text, "trusted")
    _ = try local.mergeManifest(remote.manifest())
    var forged = try XCTUnwrap(remote.transfer(id))
    forged.clip.content = "forged"
    XCTAssertThrowsError(try local.receive(forged, sourceDevice: "Synthetic peer"))
    XCTAssertNil(local.find(id))
    try local.receive(XCTUnwrap(remote.transfer(id)), sourceDevice: "Synthetic peer")
    XCTAssertEqual(local.find(id)?.content, "trusted")
  }
  func testStrictLegacySchemaRejectsNullWithoutReplacingEncryptedBytes() throws {
    let path = try root().appendingPathComponent("history.enc")
    let state: [String: Any] = [
      "version": 1,
      "preferences": [
        "paused": false, "pasteOnSelect": NSNull(), "hoverEnabled": true, "retentionDays": 7,
        "accelerator": "CommandOrControl+Shift+V",
      ], "clips": [],
    ]
    let encrypted = try codec.encode(JSONSerialization.data(withJSONObject: state))
    try encrypted.write(to: path)
    let h = ClipboardHistory(path: path, codec: codec)
    XCTAssertThrowsError(try h.initialize())
    XCTAssertEqual(h.storage.state().diagnostic?.stage, "parse")
    XCTAssertEqual(try Data(contentsOf: path), encrypted)
    XCTAssertFalse(validDeviceID("00000000-0000-4000-c000-000000000000"))
    XCTAssertTrue(validDeviceID("00000000-0000-4000-a000-000000000000"))
  }
  func testLegacyEmojiPreviewWithSplitSurrogateMigratesWithoutLosingContent() throws {
    let h = try history()
    let content = String(repeating: "x", count: 399) + "😀"
    try h.add(.text, content: content, preview: "SyntheticPreview")
    let path = URL(fileURLWithPath: h.storage.state().path)
    let json = String(decoding: try codec.decode(Data(contentsOf: path)), as: UTF8.self)
    let legacy = json.replacingOccurrences(
      of: "\"preview\":\"SyntheticPreview\"", with: "\"preview\":\"\\ud83d\"")
    XCTAssertNotEqual(json, legacy)
    try codec.encode(Data(legacy.utf8)).write(to: path)
    let migrated = ClipboardHistory(path: path, codec: codec, now: { 1_800_000_000_000 })
    try migrated.initialize()
    let clip = try XCTUnwrap(migrated.find(clipId(.text, content)))
    XCTAssertEqual(clip.content, content)
    XCTAssertEqual(clip.preview, "�")
    XCTAssertEqual(try decodeClipboardJSON(String.self, from: Data("\"\\ud83d\\ude00\"".utf8)), "😀")
    XCTAssertEqual(
      try decodeClipboardJSON(String.self, from: Data("\"\\\\ud83d\"".utf8)), "\\ud83d")
    XCTAssertThrowsError(try decodeClipboardJSON(String.self, from: Data("{ malformed".utf8)))
  }
  func testSettingsPreservesLegacyTablesAndRejectsSecrets() throws {
    let profile = try root()
    var db: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open(profile.appendingPathComponent("workspace.sqlite").path, &db), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        db, "CREATE TABLE legacy(value TEXT); INSERT INTO legacy VALUES('untouched');", nil, nil,
        nil), SQLITE_OK)
    sqlite3_close(db)
    let settings = try SettingsStore(root: profile)
    try settings.set(key: "launcherUsage", value: ["fixture": ["count": 3]])
    XCTAssertNotNil(try settings.get(key: "launcherUsage"))
    XCTAssertNil(try settings.get(key: "missing"))
    XCTAssertThrowsError(try settings.set(key: "apiKey", value: "secret"))
    settings.close()
    XCTAssertThrowsError(try settings.all())
    XCTAssertEqual(
      sqlite3_open(profile.appendingPathComponent("workspace.sqlite").path, &db), SQLITE_OK)
    var statement: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT value FROM legacy", -1, &statement, nil)
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "untouched")
    sqlite3_finalize(statement)
    sqlite3_close(db)
  }
}
