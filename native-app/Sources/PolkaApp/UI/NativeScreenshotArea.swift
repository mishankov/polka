import AppKit
import Combine
import PolkaCore
import SwiftUI

@MainActor final class NativeScreenshotArea: ObservableObject {
  let image: CGImage
  @Published var rect: CGRect
  var bounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }
  init(_ document: NativeScreenshotDocument) {
    image = document.fullSource
    rect = document.area
  }
  // Eight handles clockwise from the bottom-left; index 8 moves the whole area.
  func points(_ rect: CGRect) -> [CGPoint] {
    [
      CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
    ]
  }
  func move(_ original: CGRect, handle: Int, delta: CGPoint) {
    if handle == 8 {
      rect = original.offsetBy(
        dx: max(-original.minX, min(bounds.maxX - original.maxX, delta.x)),
        dy: max(-original.minY, min(bounds.maxY - original.maxY, delta.y)))
      return
    }
    var left = original.minX
    var right = original.maxX
    var bottom = original.minY
    var top = original.maxY
    if [0, 6, 7].contains(handle) { left = max(0, min(right - 2, left + delta.x)) }
    if [2, 3, 4].contains(handle) { right = min(bounds.maxX, max(left + 2, right + delta.x)) }
    if [0, 1, 2].contains(handle) { bottom = max(0, min(top - 2, bottom + delta.y)) }
    if [4, 5, 6].contains(handle) { top = min(bounds.maxY, max(bottom + 2, top + delta.y)) }
    rect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
  }
}
