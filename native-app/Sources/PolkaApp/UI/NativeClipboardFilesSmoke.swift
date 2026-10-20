import AppKit
import PolkaCore

/// Real AppKit keyboard flow, isolated profile and synthetic clipboard only.
@MainActor func nativeClipboardFilesSmoke(
  application: NativeApplication, model: NativeUIModel, platform: NativePlatform,
  post: (UInt16, NSEvent.ModifierFlags, String) -> Void,
  wait: (() -> Bool) async -> Bool, screenshot: (String) async -> Void
) async -> [String] {
  var failures: [String] = []
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let pdf = root.appendingPathComponent("polka-files-fixture Отчёт 3 MB.pdf")
  let folder = root.appendingPathComponent("polka-files-fixture Folder", isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 32, count: 3 * 1024 * 1024).write(to: pdf)
    try platform.capture.capture(
      snapshot: NativeClipboardSnapshot(
        changeCount: 1_000_000,
        items: [pdf, folder].map { NativeClipboardItem(types: ["public.file-url"], fileURLs: [$0]) }
      ))
  } catch { return ["cannot prepare file history fixtures: \(error)"] }
  platform.refresh()
  await application.show("clipboard")
  model.query = "polka-files-fixture"
  post(22, [.command, .control], "6")
  if !(await wait({ model.clipboardFilter == .files && model.clipResults.count == 1 })) {
    return ["file filter keyboard shortcut did not show captured group"]
  }
  let original = platform.history.snapshot()
  let id = model.selectedClip?.id
  await screenshot("clipboard-files-history")
  post(36, .command, "\r")
  if !(await wait({ model.previewID == id && model.preview?.kind == "files" })) {
    failures.append("Command Enter did not preview file names and paths")
  }
  await screenshot("clipboard-files-preview")
  post(53, [], "")
  if !(await wait({ model.previewID == nil })) {
    failures.append("Escape did not return to file history")
  }
  platform.capture.write(text: "Synthetic file copy sentinel")
  post(36, .shift, "\r")
  if !(await wait({ !model.commandPending && platform.capture.syntheticFileURLs == [pdf, folder] }))
  {
    failures.append("Shift Enter did not copy the entire native file group")
  }
  await application.show("clipboard")
  model.query = "polka-files-fixture"
  platform.capture.write(text: "Synthetic file select sentinel")
  post(36, [], "\r")
  if !(await wait({
    !model.commandPending && !model.visible && platform.capture.syntheticFileURLs == [pdf, folder]
  })) {
    failures.append("Enter did not select the entire file group for paste")
  }
  do { try FileManager.default.removeItem(at: pdf) } catch {
    failures.append("cannot remove synthetic file: \(error)")
  }
  platform.capture.write(text: "Preserve clipboard when original is missing")
  await application.show("clipboard")
  model.query = "polka-files-fixture"
  post(36, .shift, "\r")
  if !(await wait({ !model.commandPending && model.error.contains(pdf.lastPathComponent) })) {
    failures.append("missing original did not produce a recoverable error")
  }
  if !model.visible
    || platform.capture.syntheticText != "Preserve clipboard when original is missing"
  {
    failures.append("missing original changed clipboard or closed history")
  }
  await screenshot("clipboard-files-unavailable")
  if platform.history.snapshot() != original {
    failures.append("file preview, copy or failure modified saved history")
  }
  model.error = ""
  if let id { try? platform.history.remove(id) }
  platform.refresh()
  return failures
}
