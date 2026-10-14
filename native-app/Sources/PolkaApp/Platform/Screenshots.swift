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
    for editor in visible { editor.window?.orderOut(nil) }
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
      if let result { try insert(result.image, area: result.area, screenFrame: result.screenFrame) }
    } catch {
      if !stopped { for editor in visible { editor.present() } }
      throw error
    }
  }
  @discardableResult func insert(_ image: CGImage, area: CGRect? = nil, screenFrame: CGRect? = nil)
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
    let editor = NativeScreenshotEditor(shot: document, screenFrame: screenFrame)
    editor.copyImage = copyImage
    editor.addToShelf = exportFile
    editor.onClose = { [weak self] in self?.editors.removeValue(forKey: document.id) }
    editors[document.id] = editor
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
