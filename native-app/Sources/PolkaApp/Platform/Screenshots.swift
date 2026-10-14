import AppKit
import PolkaCore

@MainActor final class NativeScreenshots {
  let model: NativeUIModel
  let fixture: Bool
  let captureService = NativeScreenshotCapture()
  var captureImage: (() async throws -> CGImage?)?
  var copyImage: ((Data) throws -> Void)?
  var exportFile: ((Data, String) throws -> Void)?
  private(set) var editors: [String: NativeScreenshotEditor] = [:]
  private var stopped = false
  init(model: NativeUIModel, fixture: Bool) {
    self.model = model
    self.fixture = fixture
  }
  func capture() async throws {
    guard !model.screenshotCapturing, !stopped else { return }
    guard editors.count < 12 else {
      throw PolkaCoreError.invalid(
        localized("Close a screenshot window before capturing another."))
    }
    model.screenshotCapturing = true
    let visible = editors.values.filter { $0.window?.isVisible == true }
    for editor in visible { editor.hide() }
    defer { model.screenshotCapturing = false }
    do {
      let result: NativeScreenshotCaptureResult?
      if let captureImage {
        result = try await captureImage().map {
          NativeScreenshotCaptureResult(
            image: $0, area: CGRect(x: 0, y: 0, width: $0.width, height: $0.height))
        }
      } else if fixture {
        throw PolkaCoreError.invalid(
          localized("Screenshot capture is unavailable in this test profile"))
      } else {
        result = try await captureService.capture()
      }
      guard !stopped else { return }
      for editor in visible { editor.present() }
      if let result {
        try insert(
          result.image, area: result.area, screenFrame: result.screenFrame,
          desktopFrame: result.desktopFrame)
      }
    } catch {
      if !stopped { for editor in visible { editor.present() } }
      throw error
    }
  }
  @discardableResult func insert(
    _ image: CGImage, area: CGRect? = nil, screenFrame: CGRect? = nil, desktopFrame: CGRect? = nil
  )
    throws
    -> NativeScreenshotDocument
  {
    let bytes = editors.values.reduce(0.0) {
      $0 + Double($1.shot.fullSource.width) * Double($1.shot.fullSource.height) * 4
    }
    guard editors.count < 12, image.width > 0, image.height > 0,
      bytes + Double(image.width) * Double(image.height) * 4 <= 256 * 1024 * 1024
    else {
      throw PolkaCoreError.invalid(
        localized("Close a screenshot window before capturing another."))
    }
    let document = NativeScreenshotDocument(source: image, area: area)
    let editor = NativeScreenshotEditor(
      shot: document, screenFrame: screenFrame, desktopFrame: desktopFrame)
    editor.copyImage = copyImage
    editor.addToShelf = exportFile
    editor.onClose = { [weak self] in self?.editors.removeValue(forKey: document.id) }
    editors[document.id] = editor
    if let desktopFrame {
      for screen in NSScreen.screens where screen.frame != editor.window?.frame {
        let mirror = NativeScreenshotEditor(
          shot: document, screenFrame: screen.frame,
          desktopFrame: desktopFrame)
        mirror.overlayRoot = editor
        mirror.onClose = { [weak editor] in editor?.close() }
        editor.mirrors.append(mirror)
      }
      let liveImage: () async throws -> CGImage = { [weak self] in
        guard let self else {
          throw PolkaCoreError.invalid(localized("Could not render the screenshot"))
        }
        let visible = self.editors.values.filter { $0.window?.isVisible == true }
        for editor in visible { editor.hide() }
        defer {
          for editor in visible where self.editors[editor.shot.id] === editor { editor.present() }
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        let rect = NativeScreenshotCapture.captureRect(
          desktopFrame,
          desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
        guard let result = try await self.captureService.captureDesktop(rect),
          result.desktopFrame == desktopFrame
        else { throw PolkaCoreError.invalid(localized("Could not render the screenshot")) }
        return result.image
      }
      for item in editor.group {
        item.copyImage = copyImage
        item.addToShelf = exportFile
        item.liveImage = liveImage
      }
    }
    editor.present()
    return document
  }
  func refreshLanguage() {
    for editor in editors.values {
      editor.window?.title = editor.shot.title
      editor.shot.objectWillChange.send()
    }
  }
  func suspend() {
    captureService.finish(nil)
    for editor in Array(editors.values) { editor.close() }
    editors.removeAll()
  }
  func stop() {
    stopped = true
    suspend()
    editors.removeAll()
  }
}
