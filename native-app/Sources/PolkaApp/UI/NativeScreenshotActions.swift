import PolkaCore

extension NativeUIModel {
  func captureScreenshot(copyImmediately: Bool = false) {
    perform(NativeUICommand(copyImmediately ? "screenshots.copy" : "screenshots.capture"))
  }
}
