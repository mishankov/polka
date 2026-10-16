import AppKit
import PolkaCore

/// Called by the mandatory desktop preview phase with its isolated profile and
/// injected pasteboard. Keys still travel through the real AppKit event loop.
@MainActor func nativeClipboardFilterSmoke(
  application: NativeApplication, model: NativeUIModel, platform: NativePlatform,
  post: (UInt16, NSEvent.ModifierFlags, String) -> Void,
  wait: (() -> Bool) async -> Bool,
  screenshot: (String) async -> Void,
  hasControl: (String) -> Bool,
  click: (String) -> Void
) async -> [String] {
  var failures: [String] = []
  let marker = "polka-filter-fixture"
  let exactLink = " https://example.com/\(marker)/e\u{301}?emoji=👩🏽‍💻\r\n"
  let structuredText = "{\"\(marker)\": true}\r\n"
  let plain = "\(marker) in ordinary prose"
  let contents = [exactLink, structuredText, plain]
  do {
    for content in contents {
      try platform.history.add(.text, content: content, preview: content)
    }
  } catch { return ["cannot prepare filter fixtures: \(error)"] }
  platform.refresh()
  await application.show("clipboard")
  model.query = marker
  let linkID = clipId(.text, exactLink)
  let structuredTextID = clipId(.text, structuredText)
  let plainID = clipId(.text, plain)
  let original = platform.history.snapshot()
  for (index, ids) in [
    (0, [plainID, structuredTextID, linkID]), (1, [plainID, structuredTextID, linkID]),
    (2, []), (3, [linkID]), (4, []),
  ] {
    let keys: [UInt16] = [18, 19, 20, 21, 23]
    post(keys[index], [.command, .control], String(index + 1))
    if !(await wait({ model.clipboardFilter == ClipboardFilter.allCases[index] })) {
      failures.append("posted filter shortcut \(index + 1) did not select type")
    }
    if Set(model.clipResults.map(\.id)) != Set(ids) || model.query != marker {
      failures.append("filter \(index + 1) did not compose with search")
    }
    if !hasControl("clipboard-filter-" + ClipboardFilter.allCases[index].rawValue) {
      failures.append("filter \(index + 1) has no accessible control")
    }
  }
  await screenshot("clipboard-filter-empty")
  if !hasControl("clipboard-filter-reset") {
    failures.append("empty filter has no reset action")
  }
  click("clipboard-filter-reset")
  if !(await wait({ model.clipboardFilter == .all })) || model.query != marker {
    failures.append("reset button lost the search query")
  }
  post(21, [.command, .control], "4")
  if !(await wait({ model.clipboardFilter == .links && model.clipResults.count == 1 })) {
    failures.append("link filter did not exclude hidden records")
  }
  await screenshot("clipboard-filter-links")
  post(36, .command, "\r")
  if !(await wait({ model.previewID == linkID })) {
    failures.append("Command Enter previewed a hidden record")
  }
  post(53, [], "")
  if !(await wait({ model.previewID == nil })) || model.query != marker
    || model.clipboardFilter != .links
  {
    failures.append("preview back lost filter context")
  }
  application.hide()
  await application.show(nil)
  if model.clipboardFilter != .links || model.query != marker {
    failures.append("brief close/reopen lost filter context")
  }
  platform.capture.write(text: "Synthetic filtered copy sentinel")
  post(36, .shift, "\r")
  if !(await wait({
    !model.commandPending && Data(platform.capture.syntheticText.utf8) == Data(exactLink.utf8)
  })) {
    failures.append("filtered Shift Enter did not copy exact original bytes")
  }
  if !model.visible { await application.show(nil) }
  platform.capture.write(text: "Synthetic filtered select sentinel")
  post(18, .command, "1")
  if !(await wait({
    !model.commandPending && !model.visible
      && Data(platform.capture.syntheticText.utf8) == Data(exactLink.utf8)
  })) {
    failures.append("filtered Command1 selected hidden or changed text")
  }
  if platform.history.snapshot() != original {
    failures.append("filtering/copying modified saved history")
  }
  await application.show("clipboard")
  if model.clipboardFilter != .all || !model.query.isEmpty {
    failures.append("explicit clipboard opening retained a stale filter")
  }
  return failures
}
