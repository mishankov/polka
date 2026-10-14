import AppKit
import Combine
import PolkaCore

struct NativeScreenshotStyle: Equatable {
  var arrowColor = NSColor.systemRed
  var arrowWidth: CGFloat = 3
  var rectangleColor = NSColor.systemRed
  var rectangleWidth: CGFloat = 3
  var rectangleFilled = false
  var textColor = NSColor.white
  var textBackground = NSColor.black
  var textSize: CGFloat = 18
}

struct NativeScreenshotMark: Equatable {
  enum Kind: String { case arrow, text, rectangle }
  var id = UUID().uuidString
  var kind: Kind
  var start: CGPoint
  var end: CGPoint
  var text = ""
  var style = NativeScreenshotStyle()
}

/// Source pixels and editable marks stay in memory. Every external destination
/// receives the same flattened bitmap, in annotation order.
@MainActor final class NativeScreenshotDocument: ObservableObject, Identifiable {
  let id = UUID().uuidString
  let createdAt = Date()
  let fullSource: CGImage
  private(set) var source: CGImage
  @Published private(set) var area: CGRect
  @Published var areaPreview: CGRect?
  @Published private(set) var marks: [NativeScreenshotMark] = []
  @Published var tool = NativeScreenshotMark.Kind.arrow
  @Published var label = ""
  @Published var textAnchor: CGPoint?
  @Published var style = NativeScreenshotStyle()
  @Published var message = ""
  @Published var busy = false
  private struct Change {
    var index: Int
    var before: NativeScreenshotMark?
    var after: NativeScreenshotMark?
    var oldArea: CGRect? = nil
    var newArea: CGRect? = nil
  }
  private var history: [Change] = []
  private var undone: [Change] = []
  @Published private(set) var editingTextID: String?
  private var draftID = UUID().uuidString
  private var styleBeforeEditing: NativeScreenshotStyle?

  @Published var objectDraft: NativeScreenshotMark?
  var editingKind: NativeScreenshotMark.Kind {
    textAnchor != nil ? .text : objectDraft?.kind ?? tool
  }
  var pendingObject: NativeScreenshotMark? {
    guard var mark = objectDraft else { return nil }
    if mark.kind == .text {
      let top = Self.textBounds(mark).maxY
      mark.style.textColor = style.textColor
      mark.style.textBackground = style.textBackground
      mark.style.textSize = style.textSize
      mark.start.y = top - Self.attributedText(mark.text, style: mark.style).size().height
      mark.end = CGPoint(x: mark.start.x, y: top)
    }
    if mark.kind == .arrow {
      mark.style.arrowColor = style.arrowColor
      mark.style.arrowWidth = style.arrowWidth
    }
    if mark.kind == .rectangle {
      mark.style.rectangleColor = style.rectangleColor
      mark.style.rectangleWidth = style.rectangleWidth
      mark.style.rectangleFilled = style.rectangleFilled
    }
    return mark
  }
  func selectObject(_ mark: NativeScreenshotMark) {
    guard !busy else { return }
    finishObject()
    objectDraft = mark
    if mark.kind == .rectangle {
      style.rectangleColor = mark.style.rectangleColor
      style.rectangleWidth = mark.style.rectangleWidth
      style.rectangleFilled = mark.style.rectangleFilled
    }
    if mark.kind == .text {
      style.textColor = mark.style.textColor
      style.textBackground = mark.style.textBackground
      style.textSize = mark.style.textSize
    }
    if mark.kind == .arrow {
      style.arrowColor = mark.style.arrowColor
      style.arrowWidth = mark.style.arrowWidth
    }
  }
  func finishObject() {
    guard !busy, let mark = pendingObject else { return }
    replace(mark)
    objectDraft = nil
  }
  func replace(_ mark: NativeScreenshotMark) {
    guard !busy, let index = marks.firstIndex(where: { $0.id == mark.id }), marks[index] != mark,
      [mark.start.x, mark.start.y, mark.end.x, mark.end.y].allSatisfy(\.isFinite)
    else { return }
    record(Change(index: index, before: marks[index], after: mark))
  }
  func deleteObject() {
    guard !busy, let id = objectDraft?.id,
      let index = marks.firstIndex(where: { $0.id == id })
    else { return }
    objectDraft = nil
    record(Change(index: index, before: marks[index], after: nil))
  }
  static func distance(_ point: CGPoint, to start: CGPoint, _ end: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = dx * dx + dy * dy
    let t =
      length > 0
      ? max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length)) : 0
    return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
  }
  func object(at point: CGPoint, tolerance: CGFloat) -> NativeScreenshotMark? {
    let pending = pendingObject
    let visible = marks.map { $0.id == pending?.id ? pending! : $0 }
    return visible.reversed().first { mark in
      switch mark.kind {
      case .text: return Self.textBounds(mark).contains(point)
      case .rectangle:
        let bounds = Self.rect(mark.start, mark.end)
        let hit = tolerance + mark.style.rectangleWidth / 2
        guard bounds.insetBy(dx: -hit, dy: -hit).contains(point) else { return false }
        return mark.style.rectangleFilled || bounds.width <= hit * 2 || bounds.height <= hit * 2
          || !bounds.insetBy(dx: hit, dy: hit).contains(point)
      case .arrow:
        let hit = tolerance + mark.style.arrowWidth / 2
        if Self.distance(point, to: mark.start, mark.end) <= hit { return true }
        let angle = atan2(mark.end.y - mark.start.y, mark.end.x - mark.start.x)
        let head = max(14, mark.style.arrowWidth * 4)
        return [-CGFloat.pi / 6, CGFloat.pi / 6].contains { offset in
          let wing = CGPoint(
            x: mark.end.x - head * cos(angle + offset), y: mark.end.y - head * sin(angle + offset))
          return Self.distance(point, to: wing, mark.end) <= hit
        }
      }
    }
  }
  private var cachedImage: CGImage?
  var canUndo: Bool { !history.isEmpty }
  var canRedo: Bool { !undone.isEmpty }
  var size: CGSize { CGSize(width: source.width, height: source.height) }
  var title: String {
    localized("Screenshot {0}", createdAt.formatted(date: .omitted, time: .standard))
  }
  init(source: CGImage, area: CGRect? = nil) {
    self.fullSource = source
    self.source = source
    self.area = CGRect(x: 0, y: 0, width: source.width, height: source.height)
    if let area { setArea(area) }
    let width = max(3, min(CGFloat(source.width), CGFloat(source.height)) / 200)
    style.arrowWidth = min(32, width)
    style.textSize = min(160, max(18, width * 6))
  }
  var fullBounds: CGRect { CGRect(x: 0, y: 0, width: fullSource.width, height: fullSource.height) }
  func adjustArea(_ next: CGRect) {
    guard !busy else { return }
    commitText()
    finishObject()
    let next = next.integral.intersection(fullBounds)
    guard next.width >= 2, next.height >= 2, next != area else { return }
    record(Change(index: 0, before: nil, after: nil, oldArea: area, newArea: next))
  }
  private func setArea(_ next: CGRect) {
    let next = next.integral.intersection(fullBounds)
    guard next.width >= 2, next.height >= 2,
      let image = fullSource.cropping(
        to: CGRect(
          x: next.minX, y: fullBounds.height - next.maxY,
          width: next.width, height: next.height))
    else { return }
    let delta = CGPoint(x: area.minX - next.minX, y: area.minY - next.minY)
    marks = marks.map { mark in
      var moved = mark
      moved.start.x += delta.x
      moved.start.y += delta.y
      moved.end.x += delta.x
      moved.end.y += delta.y
      return moved
    }
    area = next
    source = image
    cachedImage = nil
  }
  func mark(start: CGPoint, end: CGPoint) -> NativeScreenshotMark {
    NativeScreenshotMark(
      kind: tool, start: start, end: end, text: String(label.prefix(2000)), style: style)
  }
  var pendingText: NativeScreenshotMark? {
    guard let anchor = textAnchor, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    let text = label
    let height = Self.attributedText(text, style: style).size().height
    var textStyle = marks.first { $0.id == editingTextID }?.style ?? style
    textStyle.textColor = style.textColor
    textStyle.textBackground = style.textBackground
    textStyle.textSize = style.textSize
    return NativeScreenshotMark(
      id: editingTextID ?? draftID, kind: .text, start: CGPoint(x: anchor.x, y: anchor.y - height),
      end: anchor,
      text: text, style: textStyle)
  }
  static func textBounds(_ mark: NativeScreenshotMark) -> CGRect {
    CGRect(origin: mark.start, size: attributedText(mark.text, style: mark.style).size())
  }
  func text(at point: CGPoint) -> NativeScreenshotMark? {
    marks.reversed().first { $0.kind == .text && Self.textBounds($0).contains(point) }
  }
  func beginText(at point: CGPoint) {
    guard !busy else { return }
    commitText()
    styleBeforeEditing = style
    draftID = UUID().uuidString
    if let mark = text(at: point) {
      editingTextID = mark.id
      label = mark.text
      textAnchor = CGPoint(x: mark.start.x, y: Self.textBounds(mark).maxY)
      style.textColor = mark.style.textColor
      style.textBackground = mark.style.textBackground
      style.textSize = mark.style.textSize
    } else {
      label = ""
      textAnchor = point
    }
    cachedImage = nil
  }
  func commitText() {
    guard !busy else { return }
    if let id = editingTextID, let index = marks.firstIndex(where: { $0.id == id }) {
      let replacement = pendingText
      if replacement != marks[index] {
        record(Change(index: index, before: marks[index], after: replacement))
      }
    } else if let mark = pendingText {
      add(mark)
    }
    endText()
  }
  func cancelText() {
    guard !busy else { return }
    if let previous = styleBeforeEditing { style = previous }
    endText()
  }
  private func endText() {
    cachedImage = nil
    editingTextID = nil
    textAnchor = nil
    label = ""
    styleBeforeEditing = nil
  }
  static func attributedText(_ text: String, style: NativeScreenshotStyle) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: max(8, min(160, style.textSize)), weight: .semibold),
        .foregroundColor: style.textColor,
      ])
  }
  func add(_ mark: NativeScreenshotMark) {
    guard !busy, [mark.start.x, mark.start.y, mark.end.x, mark.end.y].allSatisfy(\.isFinite),
      marks.count < 500
    else { return }
    if mark.kind == .text && mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return
    }
    record(Change(index: marks.count, before: nil, after: mark))
  }
  private func record(_ change: Change) {
    apply(change, forward: true)
    history.append(change)
    undone.removeAll()
    message = ""
  }
  private func apply(_ change: Change, forward: Bool) {
    cachedImage = nil
    if let next = forward ? change.newArea : change.oldArea {
      setArea(next)
      return
    }
    let previous = forward ? change.before : change.after
    let next = forward ? change.after : change.before
    if previous != nil { marks.remove(at: change.index) }
    if let next { marks.insert(next, at: change.index) }
  }
  func undo() {
    finishObject()
    guard !busy, textAnchor == nil, let change = history.popLast() else { return }
    apply(change, forward: false)
    undone.append(change)
  }
  func redo() {
    finishObject()
    guard !busy, textAnchor == nil, let change = undone.popLast() else { return }
    apply(change, forward: true)
    history.append(change)
  }
  func rendered(includingDraft: Bool = false) throws -> CGImage {
    let pending = includingDraft ? pendingText : nil
    let shape = pendingObject
    let visibleMarks = marks.map { $0.id == shape?.id ? shape! : $0 }
    if shape == nil, editingTextID == nil, pending == nil, let cachedImage { return cachedImage }
    guard
      let context = CGContext(
        data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw PolkaCoreError.invalid(localized("Could not render the screenshot")) }
    context.draw(source, in: CGRect(origin: .zero, size: size))
    for mark in visibleMarks {
      if mark.id == editingTextID {
        if let pending { Self.draw(pending, in: context, size: size) }
      } else {
        Self.draw(mark, in: context, size: size)
      }
    }
    if editingTextID == nil, let pending { Self.draw(pending, in: context, size: size) }
    guard let image = context.makeImage() else {
      throw PolkaCoreError.invalid(localized("Could not render the screenshot"))
    }
    if shape == nil, editingTextID == nil, pending == nil { cachedImage = image }
    return image
  }
  func png() throws -> Data {
    guard
      let data = NSBitmapImageRep(cgImage: try rendered(includingDraft: true)).representation(
        using: .png, properties: [:])
    else {
      throw PolkaCoreError.invalid(localized("Could not render the screenshot"))
    }
    return data
  }
  static func rect(_ start: CGPoint, _ end: CGPoint) -> CGRect {
    CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y))
  }
  static func draw(_ mark: NativeScreenshotMark, in context: CGContext, size: CGSize) {
    context.saveGState()
    defer { context.restoreGState() }
    let width = max(1, min(32, mark.style.arrowWidth))
    switch mark.kind {
    case .rectangle:
      let bounds = rect(mark.start, mark.end)
      context.setStrokeColor(mark.style.rectangleColor.cgColor)
      context.setFillColor(mark.style.rectangleColor.cgColor)
      context.setLineWidth(max(1, min(32, mark.style.rectangleWidth)))
      if mark.style.rectangleFilled { context.fill(bounds) }
      context.stroke(bounds)
    case .arrow:
      let angle = atan2(mark.end.y - mark.start.y, mark.end.x - mark.start.x)
      let head = max(14, width * 4)
      context.setStrokeColor(mark.style.arrowColor.cgColor)
      context.setLineWidth(width)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.move(to: mark.start)
      context.addLine(to: mark.end)
      context.move(
        to: CGPoint(
          x: mark.end.x - head * cos(angle - .pi / 6), y: mark.end.y - head * sin(angle - .pi / 6)))
      context.addLine(to: mark.end)
      context.addLine(
        to: CGPoint(
          x: mark.end.x - head * cos(angle + .pi / 6), y: mark.end.y - head * sin(angle + .pi / 6)))
      context.strokePath()
    case .text:
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      let text = attributedText(mark.text, style: mark.style)
      context.setFillColor(mark.style.textBackground.cgColor)
      context.fill(CGRect(origin: mark.start, size: text.size()))
      text.draw(at: mark.start)
      NSGraphicsContext.restoreGraphicsState()
    }
  }
}
