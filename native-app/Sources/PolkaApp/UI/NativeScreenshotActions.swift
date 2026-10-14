import PolkaCore

extension NativeUIModel {
  func captureScreenshot() { perform(NativeUICommand("screenshots.capture")) }
}
