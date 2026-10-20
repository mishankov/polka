import AppKit
import PolkaCore

@MainActor func nativeClipboardLazyFilesSmoke(
  application: NativeApplication, model: NativeUIModel, platform: NativePlatform,
  post: (UInt16, NSEvent.ModifierFlags, String) -> Void,
  wait: (() -> Bool) async -> Bool, screenshot: (String) async -> Void
) async -> [String] {
  var failures: [String] = []
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let originalAction = model.action
  defer {
    model.action = originalAction
    try? FileManager.default.removeItem(at: root)
  }
  do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceHistory = ClipboardHistory(
      path: root.appendingPathComponent("source.enc"),
      codec: SyntheticEncryptionCodec(key: Data(repeating: 1, count: 32)))
    try sourceHistory.initialize()
    let pdf = root.appendingPathComponent("polka-lazy-fixture Отчёт.pdf")
    let data = Data("%PDF synthetic lazy clipboard file".utf8)
    try data.write(to: pdf)
    let refs = try ClipboardFiles(urls: [pdf])
    try sourceHistory.add(.files, content: refs.content, preview: refs.preview)
    let clip = sourceHistory.snapshot().clips[0]
    let source = clip.fileSource!
    _ = try platform.history.mergeManifest(sourceHistory.manifest(files: true))
    try platform.history.receive(
      sourceHistory.transfer(clip.id, files: true)!, sourceDevice: "Synthetic Source Mac")
    platform.refresh()
    await application.show("clipboard")
    model.query = "polka-lazy-fixture"
    post(22, [.command, .control], "6")
    if !(await wait({ model.clipResults.count == 1 && model.selectedClip?.content.isEmpty == true }))
    {
      return ["remote file metadata was not searchable in file history"]
    }
    post(36, .command, "\r")
    if !(await wait({ model.previewID == clip.id })) {
      failures.append("remote file preview did not open from Command Enter")
    }
    await screenshot("clipboard-files-remote-preview")
    post(53, [], "")
    _ = await wait { model.previewID == nil }
    let original = platform.history.snapshot()
    platform.capture.write(text: "Synthetic lazy download sentinel")

    // Hold an injected download so real AppKit events can exercise progress and
    // cancellation, independent of network speed. TLS/data transfer has its own
    // two-peer platform test; the clipboard remains synthetic in this fixture.
    model.action = { command in
      if command.name == "clipboardHistory.copy", command.strings["id"] == clip.id {
        model.fileDownloadProgress = 0.25
        defer { model.fileDownloadProgress = nil }
        try await Task.sleep(nanoseconds: 30_000_000_000)
      } else {
        try await originalAction?(command)
      }
    }
    post(36, .shift, "\r")
    if !(await wait({ model.fileDownloadProgress == 0.25 && model.commandPending })) {
      failures.append("remote file loading did not show progress")
    }
    await screenshot("clipboard-files-download")
    post(53, [], "")
    if !(await wait({ !model.commandPending && model.fileDownloadProgress == nil })) {
      failures.append("Escape did not cancel pending file download")
    }
    if !model.visible || !model.error.isEmpty
      || platform.capture.syntheticText != "Synthetic lazy download sentinel"
    {
      failures.append("download cancellation changed clipboard, history visibility or error state")
    }
    model.action = originalAction

    // A cache populated by a completed download must work with sync disabled.
    try platform.sync.fileCache.save(ClipboardFileBundle(source: source, contents: [data]))
    platform.refresh()
    post(36, .shift, "\r")
    if !(await wait({
      !model.commandPending
        && platform.capture.syntheticFileURLs.first?.lastPathComponent == pdf.lastPathComponent
    })) {
      failures.append("Shift Enter did not prepare the cached remote file")
    }
    if let url = platform.capture.syntheticFileURLs.first, try Data(contentsOf: url) != data {
      failures.append("cached remote file bytes changed during clipboard preparation")
    }
    await application.show("clipboard")
    model.query = "polka-lazy-fixture"
    post(36, [], "\r")
    if !(await wait({
      !model.commandPending && !model.visible && platform.capture.syntheticFileURLs.count == 1
    })) {
      failures.append("Enter did not select cached remote files for paste")
    }
    if platform.history.snapshot() != original {
      failures.append("remote file paste modified clipboard history metadata")
    }
    try platform.history.remove(clip.id)
    platform.sync.fileCache.discard(source)
    platform.refresh()
  } catch { failures.append("lazy file desktop fixture failed: \(error)") }
  return failures
}
