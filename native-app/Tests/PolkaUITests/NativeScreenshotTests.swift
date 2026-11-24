import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeScreenshotTests: XCTestCase {
  @MainActor private func image(width: Int = 100, height: Int = 80) throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try XCTUnwrap(context.makeImage())
  }
  @MainActor func testLiveOverlayUsesDesktopCoordinatesAndFreshExportPixels() async throws {
    let shot = NativeScreenshotDocument(source: try image())
    let desktop = CGRect(x: -800, y: 0, width: 1800, height: 800)
    let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let editor = NativeScreenshotEditor(shot: shot, screenFrame: display, desktopFrame: desktop)
    defer { editor.close() }
    XCTAssertFalse(try XCTUnwrap(editor.window).isOpaque)
    XCTAssertEqual(editor.fullImageRect(in: display), desktop)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 100, height: 80,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.blue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    let fresh = try XCTUnwrap(context.makeImage())
    editor.liveImage = { fresh }
    var result: Data?
    editor.preparePNG { result = $0 }
    XCTAssertTrue(shot.busy)
    for _ in 0..<100 where result == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    let exported = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(result)))
    XCTAssertGreaterThan(try XCTUnwrap(exported.colorAt(x: 50, y: 40)).blueComponent, 0.95)
    XCTAssertLessThan(try XCTUnwrap(exported.colorAt(x: 50, y: 40)).redComponent, 0.05)
    XCTAssertFalse(shot.busy)
  }
  @MainActor func testRectangleHasFourIndependentlyResizableCorners() throws {
    let shot = NativeScreenshotDocument(source: try image())
    let canvas = NativeScreenshotCanvas()
    canvas.document = shot
    let rectangle = NativeScreenshotMark(
      kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 70, y: 60))
    XCTAssertEqual(canvas.objectHandles(rectangle).count, 4)
    let upperLeft = canvas.moveObject(rectangle, by: CGPoint(x: -5, y: 10), handle: 3)
    XCTAssertEqual(upperLeft.start, CGPoint(x: 15, y: 20))
    XCTAssertEqual(upperLeft.end, CGPoint(x: 70, y: 70))
    let lowerRight = canvas.moveObject(rectangle, by: CGPoint(x: 10, y: -5), handle: 4)
    XCTAssertEqual(lowerRight.start, CGPoint(x: 20, y: 15))
    XCTAssertEqual(lowerRight.end, CGPoint(x: 80, y: 60))
    shot.add(rectangle)
    shot.selectObject(rectangle)
    shot.objectDraft = upperLeft
    shot.finishObject()
    shot.undo()
    XCTAssertEqual(shot.marks, [rectangle])
    shot.redo()
    XCTAssertEqual(shot.marks, [upperLeft])
  }
  @MainActor func testBackspaceDeletesEveryObjectAndEscapeDiscards() throws {
    let captures = NativeScreenshots(model: NativeUIModel(), fixture: true)
    let shot = try captures.insert(image())
    let editor = try XCTUnwrap(captures.editors[shot.id])
    for kind in [NativeScreenshotMark.Kind.arrow, .text, .rectangle] {
      let mark = NativeScreenshotMark(
        kind: kind, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 60), text: "Editable")
      shot.add(mark)
      shot.selectObject(mark)
      XCTAssertFalse(
        editor.handleKeyboard(.init(code: 51, characters: "", modifiers: [], composing: true)))
      XCTAssertFalse(
        editor.handleKeyboard(.init(code: 51, characters: "", modifiers: [], editing: true)))
      XCTAssertTrue(
        editor.handleKeyboard(.init(code: 51, characters: "", modifiers: [], repeatKey: true)))
      XCTAssertEqual(shot.marks.count, 1)
      XCTAssertTrue(editor.handleKeyboard(.init(code: 51, characters: "", modifiers: [])))
      XCTAssertTrue(shot.marks.isEmpty)
      shot.undo()
      XCTAssertEqual(shot.marks, [mark])
      shot.selectObject(mark)
      editor.deleteObject()
      XCTAssertTrue(shot.marks.isEmpty)
    }
    XCTAssertTrue(
      editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [], repeatKey: true)))
    XCTAssertNotNil(captures.editors[shot.id])
    shot.busy = true
    XCTAssertTrue(editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [])))
    XCTAssertNotNil(captures.editors[shot.id])
    shot.busy = false
    XCTAssertTrue(editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [])))
    XCTAssertTrue(captures.editors.isEmpty)
  }
  @MainActor func testEscapeCommitsAndDeselectsBeforeDiscarding() throws {
    let captures = NativeScreenshots(model: NativeUIModel(), fixture: true)
    let shot = try captures.insert(image())
    let editor = try XCTUnwrap(captures.editors[shot.id])
    for kind in [NativeScreenshotMark.Kind.arrow, .rectangle, .text] {
      let mark = NativeScreenshotMark(
        kind: kind, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 60), text: "Text")
      shot.add(mark)
      shot.selectObject(mark)
      shot.objectDraft?.start.x = 15
      XCTAssertFalse(
        editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [], composing: true)))
      XCTAssertTrue(
        editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [], repeatKey: true)))
      XCTAssertNotNil(shot.objectDraft)
      shot.busy = true
      XCTAssertTrue(editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [])))
      XCTAssertNotNil(shot.objectDraft)
      shot.busy = false
      XCTAssertTrue(editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [])))
      XCTAssertNil(shot.objectDraft)
      XCTAssertEqual(shot.marks.last?.start.x, 15)
      XCTAssertNotNil(captures.editors[shot.id])
    }
    XCTAssertTrue(editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [])))
    XCTAssertTrue(captures.editors.isEmpty)
  }
  func testToolbarSwitchesBeforeMenuBarAndNotchClipping() {
    let screen = CGSize(width: 1000, height: 700)
    let toolbar = CGSize(width: 440, height: 70)
    let nearTop = CGRect(x: 200, y: 100, width: 600, height: 400)
    let protected = NativeScreenshotToolbarLayout.frame(
      selection: nearTop, screen: screen,
      toolbar: toolbar, above: true, topInset: 38)
    XCTAssertGreaterThan(protected.minY, nearTop.minY)
    XCTAssertGreaterThanOrEqual(protected.minY, 46)
    let enoughRoom = CGRect(x: 200, y: 130, width: 600, height: 400)
    let outside = NativeScreenshotToolbarLayout.frame(
      selection: enoughRoom, screen: screen,
      toolbar: toolbar, above: true, topInset: 38)
    XCTAssertLessThan(outside.maxY, enoughRoom.minY)
    XCTAssertGreaterThanOrEqual(outside.minY, 46)
  }
  func testCompactToolbarsFitOutsideAndFallBackInsideIndependently() {
    let screen = CGSize(width: 1000, height: 700)
    let size = CGSize(width: 480, height: 76)
    let middle = CGRect(x: 300, y: 200, width: 400, height: 300)
    let top = NativeScreenshotToolbarLayout.frame(
      selection: middle, screen: screen, toolbar: size, above: true)
    let bottom = NativeScreenshotToolbarLayout.frame(
      selection: middle, screen: screen, toolbar: size, above: false)
    XCTAssertLessThan(top.maxY, middle.minY)
    XCTAssertGreaterThan(bottom.minY, middle.maxY)
    let edge = CGRect(x: 10, y: 12, width: 980, height: 675)
    let insideTop = NativeScreenshotToolbarLayout.frame(
      selection: edge, screen: screen, toolbar: size, above: true)
    let insideBottom = NativeScreenshotToolbarLayout.frame(
      selection: edge, screen: screen, toolbar: size, above: false)
    XCTAssertTrue(edge.contains(insideTop))
    XCTAssertTrue(edge.contains(insideBottom))
    let nearTop = CGRect(x: 0, y: 10, width: 250, height: 300)
    let mixedTop = NativeScreenshotToolbarLayout.frame(
      selection: nearTop, screen: screen, toolbar: size, above: true)
    let mixedBottom = NativeScreenshotToolbarLayout.frame(
      selection: nearTop, screen: screen, toolbar: size, above: false)
    XCTAssertGreaterThan(mixedTop.minY, nearTop.minY)
    XCTAssertGreaterThan(mixedBottom.minY, nearTop.maxY)
    XCTAssertGreaterThanOrEqual(mixedTop.minX, 8)
  }
  func testCompactToolbarsStackWithoutOverlappingForShortEdgeSelections() {
    let screen = CGSize(width: 1000, height: 700)
    let tools = CGSize(width: 510, height: 76)
    let actions = CGSize(width: 470, height: 40)
    let nearTop = CGRect(x: 200, y: 40, width: 400, height: 20)
    let below = NativeScreenshotToolbarLayout.frames(
      selection: nearTop, screen: screen, tools: tools, actions: actions, topInset: 24)
    XCTAssertGreaterThan(below.tools.minY, nearTop.maxY)
    XCTAssertGreaterThan(below.actions.minY, below.tools.maxY)
    XCTAssertLessThan(below.actions.maxY, screen.height)

    let nearBottom = CGRect(x: 200, y: 665, width: 400, height: 20)
    let above = NativeScreenshotToolbarLayout.frames(
      selection: nearBottom, screen: screen, tools: tools, actions: actions, topInset: 24)
    XCTAssertGreaterThan(above.tools.minY, 24)
    XCTAssertGreaterThan(above.actions.minY, above.tools.maxY)
    XCTAssertLessThan(above.actions.maxY, nearBottom.minY)
  }
  @MainActor func testAreaCanShrinkExpandAndUndoWithoutLosingAnnotations() throws {
    let shot = NativeScreenshotDocument(
      source: try image(), area: CGRect(x: 20, y: 10, width: 50, height: 40))
    XCTAssertEqual(shot.size, CGSize(width: 50, height: 40))
    let mark = NativeScreenshotMark(
      kind: .arrow, start: CGPoint(x: 5, y: 5), end: CGPoint(x: 30, y: 30))
    shot.add(mark)
    let original = try shot.png()
    shot.adjustArea(shot.fullBounds)
    XCTAssertEqual(shot.size, CGSize(width: 100, height: 80))
    XCTAssertEqual(shot.marks[0].start, CGPoint(x: 25, y: 15))
    XCTAssertEqual(shot.marks[0].id, mark.id)
    shot.adjustArea(CGRect(x: 60, y: 50, width: 20, height: 20))
    XCTAssertEqual(shot.marks.count, 1)
    let png = try XCTUnwrap(NSBitmapImageRep(data: shot.png()))
    XCTAssertEqual(png.pixelsWide, 20)
    XCTAssertEqual(png.pixelsHigh, 20)
    shot.undo()
    shot.undo()
    XCTAssertEqual(shot.marks[0], mark)
    XCTAssertEqual(try shot.png(), original)
    shot.undo()
    XCTAssertTrue(shot.marks.isEmpty)
    shot.redo()
    shot.redo()
    XCTAssertEqual(shot.area, shot.fullBounds)
    XCTAssertEqual(shot.marks[0].start, CGPoint(x: 25, y: 15))
    let area = NativeScreenshotArea(shot)
    area.rect = CGRect(x: 20, y: 20, width: 40, height: 30)
    area.move(area.rect, handle: 4, delta: CGPoint(x: 1000, y: 1000))
    XCTAssertEqual(area.rect, CGRect(x: 20, y: 20, width: 80, height: 60))
    area.move(area.rect, handle: 0, delta: CGPoint(x: 1000, y: 1000))
    XCTAssertEqual(area.rect.size, CGSize(width: 2, height: 2))
  }
  @MainActor func testRectangleOutlineFillHitTestingAndUndo() throws {
    let shot = NativeScreenshotDocument(source: try image())
    shot.tool = .rectangle
    shot.style.rectangleColor = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
    shot.style.rectangleWidth = 6
    let mark = shot.mark(start: CGPoint(x: 20, y: 20), end: CGPoint(x: 60, y: 60))
    shot.add(mark)
    let outline = try shot.png()
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: outline))
    XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 40, y: 40)).redComponent, 0.95)
    XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 20, y: 40)).redComponent, 0.05)
    XCTAssertNil(shot.object(at: CGPoint(x: 40, y: 40), tolerance: 2))
    XCTAssertEqual(shot.object(at: CGPoint(x: 20, y: 40), tolerance: 2)?.id, mark.id)
    shot.selectObject(mark)
    shot.style.rectangleFilled = true
    shot.style.rectangleWidth = 10
    XCTAssertEqual(shot.object(at: CGPoint(x: 40, y: 40), tolerance: 2)?.id, mark.id)
    let filled = try shot.png()
    let filledBitmap = try XCTUnwrap(NSBitmapImageRep(data: filled))
    XCTAssertLessThan(try XCTUnwrap(filledBitmap.colorAt(x: 40, y: 40)).redComponent, 0.05)
    shot.finishObject()
    XCTAssertEqual(shot.marks[0].id, mark.id)
    XCTAssertTrue(shot.marks[0].style.rectangleFilled)
    shot.undo()
    XCTAssertEqual(try shot.png(), outline)
    shot.redo()
    XCTAssertEqual(try shot.png(), filled)
    shot.add(.init(kind: .arrow, start: CGPoint(x: 0, y: 40), end: CGPoint(x: 90, y: 40)))
    let layered = try XCTUnwrap(NSBitmapImageRep(data: shot.png()))
    XCTAssertGreaterThan(try XCTUnwrap(layered.colorAt(x: 40, y: 40)).redComponent, 0.5)
  }
  @MainActor func testAnnotationStylesAreCapturedAndRenderedIndependently() throws {
    let shot = NativeScreenshotDocument(source: try image())
    shot.style.arrowColor = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
    shot.style.arrowWidth = 10
    let arrow = shot.mark(start: CGPoint(x: 10, y: 40), end: CGPoint(x: 90, y: 40))
    shot.add(arrow)
    let png = try shot.png()
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
    let inside = try XCTUnwrap(bitmap.colorAt(x: 40, y: 43)?.usingColorSpace(.deviceRGB))
    XCTAssertEqual(inside.blueComponent, 1, accuracy: 0.01)
    // PNG color-space conversion can shift saturated channels slightly.
    XCTAssertLessThan(inside.redComponent, 0.05)
    let outside = try XCTUnwrap(bitmap.colorAt(x: 40, y: 48)?.usingColorSpace(.deviceRGB))
    XCTAssertEqual(outside.redComponent, 1, accuracy: 0.01)
    shot.style.arrowColor = .green
    shot.style.arrowWidth = 2
    XCTAssertEqual(try shot.png(), png)
    shot.undo()
    shot.redo()
    XCTAssertEqual(shot.marks.first, arrow)
    XCTAssertEqual(try shot.png(), png)

    shot.tool = .text
    shot.label = "Hi"
    shot.style.textColor = .yellow
    shot.style.textBackground = .blue
    shot.style.textSize = 30
    let text = shot.mark(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 10, y: 10))
    shot.add(text)
    let styled = try shot.png()
    shot.style.textSize = 12
    shot.style.textColor = .red
    shot.style.textBackground = .clear
    XCTAssertEqual(try shot.png(), styled)
    shot.undo()
    XCTAssertEqual(try shot.png(), png)
    shot.add(shot.mark(start: text.start, end: text.end))
    XCTAssertNotEqual(try shot.png(), styled)
    XCTAssertEqual(text.style.textSize, 30)
    XCTAssertEqual(text.style.textColor, .yellow)
    XCTAssertEqual(text.style.textBackground, .blue)
    for variant in 0..<3 {
      shot.undo()
      var changed = text
      switch variant {
      case 0: changed.style.textColor = .red
      case 1: changed.style.textBackground = .clear
      default: changed.style.textSize = 12
      }
      shot.add(changed)
      XCTAssertNotEqual(try shot.png(), styled, "Text style property \(variant) was ignored")
    }
  }
  func testNumericFieldsValidateCommittedInput() {
    XCTAssertEqual(NativeScreenshotNumberField.committedValue("12", previous: 3, range: 1...32), 12)
    XCTAssertEqual(
      NativeScreenshotNumberField.committedValue("999", previous: 3, range: 1...32), 32)
    XCTAssertEqual(
      NativeScreenshotNumberField.committedValue("-4", previous: 18, range: 8...160), 8)
    for invalid in ["", "abc", "NaN", "inf"] {
      XCTAssertEqual(
        NativeScreenshotNumberField.committedValue(invalid, previous: 18, range: 8...160), 18)
    }
  }
  @MainActor func testScreenshotStyleDefaultsAreFixedAcrossImageSizes() throws {
    for source in [try image(), try image(width: 1920, height: 1080)] {
      let style = NativeScreenshotDocument(source: source).style
      XCTAssertEqual(style.arrowWidth, 3)
      XCTAssertEqual(style.rectangleWidth, 3)
      XCTAssertEqual(style.lineWidth, 3)
      XCTAssertEqual(style.textSize, 18)
    }
  }
  @MainActor func testScreenshotStylePreferencesMergeToolbarChangesAndSurviveReopening() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try image()
    let settings = try SettingsStore(root: root)
    let preferences = NativeScreenshotStylePreferences(settings: settings)
    let first = NativeScreenshotDocument(source: source, stylePreferences: preferences)
    let second = NativeScreenshotDocument(source: source, stylePreferences: preferences)
    let ink = NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
    let background = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
    first.changeStyle(ink, for: \.arrowColor)
    first.changeStyle(9, for: \.arrowWidth)
    second.changeStyle(ink, for: \.rectangleColor)
    second.changeStyle(7, for: \.rectangleWidth)
    second.changeStyle(true, for: \.rectangleFilled)
    second.changeStyle(ink, for: \.lineColor)
    second.changeStyle(5, for: \.lineWidth)
    second.changeStyle(ink, for: \.textColor)
    second.changeStyle(background, for: \.textBackground)
    second.changeStyle(27, for: \.textSize)

    let oldArrow = NativeScreenshotMark(
      kind: .arrow, start: CGPoint(x: 5, y: 5), end: CGPoint(x: 35, y: 35))
    first.add(oldArrow)
    first.selectObject(oldArrow)
    XCTAssertEqual(first.style.arrowWidth, oldArrow.style.arrowWidth)
    first.finishObject()
    XCTAssertEqual(first.marks.first, oldArrow)

    settings.close()
    let reopened = try SettingsStore(root: root)
    let saved = NativeScreenshotStylePreferences(settings: reopened)
    let next = NativeScreenshotDocument(source: source, stylePreferences: saved)
    XCTAssertEqual(next.style.arrowWidth, 9)
    XCTAssertEqual(next.style.rectangleWidth, 7)
    XCTAssertEqual(next.style.lineWidth, 5)
    XCTAssertTrue(next.style.rectangleFilled)
    XCTAssertEqual(next.style.textSize, 27)
    XCTAssertEqual(next.style.arrowColor, ink)
    XCTAssertEqual(next.style.rectangleColor, ink)
    XCTAssertEqual(next.style.lineColor, ink)
    XCTAssertEqual(next.style.textColor, ink)
    XCTAssertEqual(next.style.textBackground.alphaComponent, 0.4, accuracy: 0.001)
    XCTAssertEqual(next.style.textBackground.blueComponent, 0.3, accuracy: 0.001)
  }
  @MainActor func testLineAnnotationRendersAndSelectsOnlyItsStroke() throws {
    let shot = NativeScreenshotDocument(source: try image())
    shot.tool = .line
    shot.changeStyle(.black, for: \.lineColor)
    shot.changeStyle(4, for: \.lineWidth)
    let line = shot.mark(start: CGPoint(x: 10, y: 40), end: CGPoint(x: 80, y: 40))
    shot.add(line)
    XCTAssertEqual(shot.object(at: CGPoint(x: 45, y: 40), tolerance: 1)?.id, line.id)
    XCTAssertNil(shot.object(at: CGPoint(x: 70, y: 46), tolerance: 1))
    let pixels = NSBitmapImageRep(cgImage: try shot.rendered())
    let onLine = try XCTUnwrap(pixels.colorAt(x: 45, y: 40)?.usingColorSpace(.sRGB))
    let besideEnd = try XCTUnwrap(pixels.colorAt(x: 70, y: 46)?.usingColorSpace(.sRGB))
    XCTAssertLessThan(onLine.redComponent, 0.1)
    XCTAssertGreaterThan(besideEnd.redComponent, 0.9)
  }
  @MainActor func testScreenshotDrawingSnapsLinesAndArrowsToNearest15Degrees() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let start = CGPoint(x: 50, y: 50)
    for kind in [NativeScreenshotMark.Kind.line, .arrow] {
      XCTAssertEqual(
        NativeScreenshotDocument.snappedEnd(
          from: start, to: CGPoint(x: 10, y: 54), kind: kind, in: bounds),
        CGPoint(x: 10, y: 50))
      XCTAssertEqual(
        NativeScreenshotDocument.snappedEnd(
          from: start, to: CGPoint(x: 54, y: 10), kind: kind, in: bounds),
        CGPoint(x: 50, y: 10))

      let radius: CGFloat = 30
      for degrees in stride(from: 0, to: 360, by: 15) {
        let angle = CGFloat(degrees) * .pi / 180
        for offset: CGFloat in [-7, 7] {
          let deviation = offset * .pi / 180
          let pointer = CGPoint(
            x: start.x + radius * cos(angle + deviation),
            y: start.y + radius * sin(angle + deviation))
          let snapped = NativeScreenshotDocument.snappedEnd(
            from: start, to: pointer, kind: kind, in: bounds)
          let projectedRadius = radius * cos(deviation)
          XCTAssertEqual(snapped.x, start.x + projectedRadius * cos(angle), accuracy: 0.000001)
          XCTAssertEqual(snapped.y, start.y + projectedRadius * sin(angle), accuracy: 0.000001)
        }
      }

      let rightEdge = NativeScreenshotDocument.snappedEnd(
        from: CGPoint(x: 90, y: 55), to: CGPoint(x: 100, y: 75), kind: kind, in: bounds)
      XCTAssertEqual(rightEdge.x, 100, accuracy: 0.000001)
      XCTAssertEqual(rightEdge.y, 55 + 10 * sqrt(3), accuracy: 0.000001)

      let topEdge = NativeScreenshotDocument.snappedEnd(
        from: CGPoint(x: 50, y: 95), to: CGPoint(x: 70, y: 100), kind: kind, in: bounds)
      XCTAssertEqual(topEdge.x, 50 + 5 * (2 + sqrt(3)), accuracy: 0.000001)
      XCTAssertEqual(topEdge.y, 100, accuracy: 0.000001)

      XCTAssertEqual(
        NativeScreenshotDocument.snappedEnd(
          from: start, to: start, kind: kind, in: bounds),
        start)
    }
  }
  @MainActor func testScreenshotDrawingSnapsRectanglesToSquaresWithinCapture() {
    let bounds = CGRect(x: 10, y: 10, width: 100, height: 80)
    let start = CGPoint(x: 40, y: 50)
    XCTAssertEqual(
      NativeScreenshotDocument.snappedEnd(
        from: start, to: CGPoint(x: 62, y: 38), kind: .rectangle, in: bounds),
      CGPoint(x: 62, y: 28))
    XCTAssertEqual(
      NativeScreenshotDocument.snappedEnd(
        from: start, to: CGPoint(x: 20, y: 85), kind: .rectangle, in: bounds),
      CGPoint(x: 10, y: 80))
    XCTAssertEqual(
      NativeScreenshotDocument.snappedEnd(
        from: CGPoint(x: 40, y: 90), to: CGPoint(x: 70, y: 90), kind: .rectangle, in: bounds),
      CGPoint(x: 70, y: 60))
    XCTAssertEqual(
      NativeScreenshotDocument.snappedEnd(from: start, to: start, kind: .rectangle, in: bounds),
      start)
  }
  @MainActor func testScreenshotEditingSnapsExistingShapeHandles() throws {
    func shift(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
      return try XCTUnwrap(
        NSEvent.keyEvent(
          with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
          isARepeat: false, keyCode: 56))
    }
    for kind in [NativeScreenshotMark.Kind.line, .arrow, .rectangle] {
      let shot = NativeScreenshotDocument(source: try image())
      let canvas = NativeScreenshotCanvas(frame: CGRect(x: 0, y: 0, width: 232, height: 192))
      canvas.document = shot
      func mouse(
        _ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []
      ) throws -> NSEvent {
        let image = canvas.imageRect
        return try XCTUnwrap(
          NSEvent.mouseEvent(
            with: type,
            location: CGPoint(x: image.minX + point.x * 2, y: image.minY + point.y * 2),
            modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
      }
      let mark = NativeScreenshotMark(
        kind: kind, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 60, y: 40))
      shot.add(mark)
      shot.selectObject(mark)
      let dragged = CGPoint(x: 72, y: 32)
      let angle = CGFloat.pi / 12
      let direction = CGPoint(x: cos(angle), y: sin(angle))
      let projectedLength =
        (dragged.x - mark.start.x) * direction.x
        + (dragged.y - mark.start.y) * direction.y
      let snapped =
        kind == .rectangle
        ? CGPoint(x: 72, y: 72)
        : CGPoint(
          x: mark.start.x + projectedLength * direction.x,
          y: mark.start.y + projectedLength * direction.y)
      canvas.mouseDown(with: try mouse(.leftMouseDown, at: mark.end, modifiers: .shift))
      canvas.mouseUp(with: try mouse(.leftMouseUp, at: mark.end, modifiers: .shift))
      XCTAssertEqual(shot.marks, [mark])
      canvas.mouseDown(with: try mouse(.leftMouseDown, at: mark.end))
      canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: dragged))
      XCTAssertEqual(shot.pendingObject?.end, dragged)
      canvas.flagsChanged(with: try shift(.shift))
      let pendingEnd = try XCTUnwrap(shot.pendingObject?.end)
      XCTAssertEqual(pendingEnd.x, snapped.x, accuracy: 0.000001)
      XCTAssertEqual(pendingEnd.y, snapped.y, accuracy: 0.000001)
      canvas.flagsChanged(with: try shift([]))
      XCTAssertEqual(shot.pendingObject?.end, dragged)
      canvas.mouseUp(with: try mouse(.leftMouseUp, at: dragged, modifiers: .shift))

      XCTAssertEqual(shot.marks.count, 1)
      XCTAssertEqual(shot.marks.first?.id, mark.id)
      XCTAssertEqual(shot.marks.first?.start, mark.start)
      let savedEnd = try XCTUnwrap(shot.marks.first?.end)
      XCTAssertEqual(savedEnd.x, snapped.x, accuracy: 0.000001)
      XCTAssertEqual(savedEnd.y, snapped.y, accuracy: 0.000001)
      shot.undo()
      XCTAssertEqual(shot.marks, [mark])
    }
  }
  @MainActor func testScreenshotEditingSnapsAllRectangleCornersAroundTheOppositeCorner() throws {
    let shot = NativeScreenshotDocument(source: try image())
    let canvas = NativeScreenshotCanvas()
    canvas.document = shot
    let rectangle = NativeScreenshotMark(
      kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 60, y: 40))
    let corners = Dictionary(uniqueKeysWithValues: canvas.objectHandles(rectangle))
    for (handle, opposite) in [(0, 1), (1, 0), (3, 4), (4, 3)] {
      let edited = canvas.moveObject(
        rectangle, by: CGPoint(x: 5, y: 8), handle: handle, snapping: true)
      let bounds = NativeScreenshotDocument.rect(edited.start, edited.end)
      let updated = Dictionary(uniqueKeysWithValues: canvas.objectHandles(edited))
      XCTAssertEqual(bounds.width, bounds.height)
      XCTAssertEqual(updated[opposite], corners[opposite])
    }
  }
  @MainActor func testScreenshotEditingSnapsWithAnchorOutsideCrop() throws {
    let shot = NativeScreenshotDocument(source: try image(width: 160, height: 100))
    let canvas = NativeScreenshotCanvas()
    canvas.document = shot
    for kind in [NativeScreenshotMark.Kind.line, .arrow] {
      shot.add(
        NativeScreenshotMark(
          kind: kind, start: CGPoint(x: 20, y: 40), end: CGPoint(x: 100, y: 46)))
    }
    shot.adjustArea(CGRect(x: 60, y: 0, width: 100, height: 100))
    for mark in shot.marks {
      let snapped = canvas.moveObject(mark, by: CGPoint(x: -39, y: 0), handle: 1, snapping: true)
      XCTAssertEqual(snapped.id, mark.id)
      XCTAssertEqual(snapped.start, CGPoint(x: -40, y: 40))
      XCTAssertEqual(snapped.end.x, 0, accuracy: 0.000001)
      XCTAssertEqual(snapped.end.y, 40 + 40 * tan(CGFloat.pi / 12), accuracy: 0.000001)
    }
  }
  @MainActor func testScreenshotEditingUsesNearestAngleThatIntersectsCrop() throws {
    let shot = NativeScreenshotDocument(source: try image(width: 160, height: 110))
    let canvas = NativeScreenshotCanvas()
    canvas.document = shot
    for kind in [NativeScreenshotMark.Kind.line, .arrow] {
      shot.add(
        NativeScreenshotMark(
          kind: kind, start: CGPoint(x: 20, y: 8), end: CGPoint(x: 100, y: 18)))
    }
    shot.adjustArea(CGRect(x: 60, y: 10, width: 100, height: 100))
    for mark in shot.marks {
      let snapped = canvas.moveObject(mark, by: CGPoint(x: 10, y: 0), handle: 1, snapping: true)
      let dx = snapped.end.x - snapped.start.x
      let dy = snapped.end.y - snapped.start.y
      XCTAssertEqual(snapped.start, CGPoint(x: -40, y: -2))
      XCTAssertTrue(CGRect(origin: .zero, size: shot.size).contains(snapped.end))
      XCTAssertEqual(atan2(dy, dx), CGFloat.pi / 12, accuracy: 0.000001)

      var diagonal = mark
      diagonal.start = CGPoint(x: 500, y: -500)
      diagonal.end = CGPoint(x: 9, y: 10)
      let corner = canvas.moveObject(diagonal, by: CGPoint(x: 1, y: 0), handle: 1, snapping: true)
      XCTAssertEqual(corner.end.x, 0, accuracy: 0.000001)
      XCTAssertEqual(corner.end.y, 0, accuracy: 0.000001)
    }
  }
  @MainActor func testTextObjectMovementAndSelectedStylingRemainUndoable() throws {
    let shot = NativeScreenshotDocument(source: try image())
    let canvas = NativeScreenshotCanvas(frame: NSRect(x: 0, y: 0, width: 232, height: 192))
    canvas.document = shot
    shot.beginText(at: CGPoint(x: 10, y: 70))
    shot.label = "Move"
    shot.commitText()
    let original = try XCTUnwrap(shot.marks.first)
    shot.tool = .rectangle
    shot.selectObject(original)
    XCTAssertNil(shot.textAnchor)
    shot.objectDraft = canvas.moveObject(original, by: CGPoint(x: 15, y: -10), handle: 2)
    shot.finishObject()
    XCTAssertEqual(shot.marks[0].id, original.id)
    XCTAssertEqual(shot.marks[0].start.x, original.start.x + 15)
    XCTAssertEqual(shot.marks[0].end.y, original.end.y - 10)
    shot.undo()
    XCTAssertEqual(shot.marks[0], original)
    shot.redo()
    let moved = shot.marks[0]
    shot.selectObject(moved)
    shot.style.textSize = 30
    shot.style.textColor = .red
    let pending = try XCTUnwrap(shot.pendingObject)
    XCTAssertEqual(pending.end, moved.end)
    XCTAssertEqual(pending.style.textSize, 30)
    XCTAssertEqual(
      shot.object(at: CGPoint(x: pending.start.x + 2, y: pending.start.y + 2), tolerance: 4)?.id,
      original.id)
    shot.finishObject()
    shot.undo()
    XCTAssertEqual(shot.marks[0], moved)
  }
  @MainActor func testEscapeAndOutsideClickFinishTextWithoutCreatingAnotherBlock() throws {
    _ = NSApplication.shared
    let shot = NativeScreenshotDocument(source: try image())
    let editor = NativeScreenshotEditor(shot: shot)
    let canvas = NativeScreenshotCanvas(frame: NSRect(x: 0, y: 0, width: 232, height: 192))
    canvas.document = shot
    editor.canvas = canvas
    shot.tool = .text
    canvas.beginText(at: CGPoint(x: 10, y: 70))
    canvas.textEditor?.string = "Keep"
    canvas.textDidChange(Notification(name: NSText.didChangeNotification))
    XCTAssertTrue(editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [])))
    XCTAssertEqual(shot.marks.last?.text, "Keep")
    XCTAssertNil(canvas.textEditor)
    canvas.beginText(at: CGPoint(x: 12, y: 60))
    canvas.textEditor?.string = "Changed"
    canvas.textDidChange(Notification(name: NSText.didChangeNotification))
    let outside = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: CGPoint(x: 200, y: 20), modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    canvas.mouseDown(with: outside)
    XCTAssertNil(canvas.textEditor)
    XCTAssertNil(shot.textAnchor)
    XCTAssertEqual(shot.marks.count, 1)
    XCTAssertEqual(shot.marks.last?.text, "Changed")
    canvas.beginText(at: CGPoint(x: 12, y: 60))
    canvas.textEditor?.string = ""
    canvas.textDidChange(Notification(name: NSText.didChangeNotification))
    XCTAssertTrue(editor.handleKeyboard(.init(code: 53, characters: "", modifiers: [])))
    XCTAssertTrue(shot.marks.isEmpty)
    shot.undo()
    XCTAssertEqual(shot.marks.last?.text, "Changed")
    editor.close()
  }
  @MainActor func testArrowAndRectangleObjectEditsKeepIdentityAndUndoGeometryAndStyle() throws {
    let shot = NativeScreenshotDocument(source: try image())
    let canvas = NativeScreenshotCanvas(frame: NSRect(x: 0, y: 0, width: 232, height: 192))
    canvas.document = shot
    let arrow = NativeScreenshotMark(
      kind: .arrow, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 80, y: 60))
    shot.add(arrow)
    let original = try shot.png()
    shot.tool = .text
    XCTAssertEqual(shot.object(at: CGPoint(x: 45, y: 35), tolerance: 4)?.id, arrow.id)
    shot.selectObject(arrow)
    shot.style.arrowColor = .green
    shot.style.arrowWidth = 12
    shot.objectDraft = canvas.moveObject(arrow, by: CGPoint(x: 10, y: 5), handle: 0)
    let edited = try shot.png()
    shot.finishObject()
    XCTAssertEqual(shot.marks.count, 1)
    XCTAssertEqual(shot.marks[0].id, arrow.id)
    XCTAssertEqual(shot.marks[0].start, CGPoint(x: 20, y: 15))
    XCTAssertEqual(shot.marks[0].end, arrow.end)
    XCTAssertEqual(shot.marks[0].style.arrowWidth, 12)
    XCTAssertEqual(shot.marks[0].style.arrowColor, .green)
    XCTAssertEqual(try shot.png(), edited)
    XCTAssertNotEqual(edited, original)
    shot.undo()
    XCTAssertEqual(shot.marks[0], arrow)
    XCTAssertEqual(try shot.png(), original)
    shot.redo()
    XCTAssertEqual(try shot.png(), edited)
    let moved = canvas.moveObject(arrow, by: CGPoint(x: 500, y: -500), handle: 2)
    XCTAssertEqual(moved.end.x - moved.start.x, arrow.end.x - arrow.start.x)
    XCTAssertEqual(moved.start.y, 0)
    XCTAssertEqual(moved.end.x, shot.size.width)
    let rectangle = NativeScreenshotMark(
      kind: .rectangle, start: CGPoint(x: 30, y: 20), end: CGPoint(x: 60, y: 50))
    shot.add(rectangle)
    XCTAssertEqual(shot.object(at: CGPoint(x: 30, y: 35), tolerance: 4)?.id, rectangle.id)
    shot.selectObject(rectangle)
    shot.objectDraft = canvas.moveObject(rectangle, by: CGPoint(x: 5, y: 10), handle: 1)
    shot.finishObject()
    XCTAssertEqual(shot.marks.last?.end, CGPoint(x: 65, y: 60))
    shot.selectObject(try XCTUnwrap(shot.marks.last))
    shot.deleteObject()
    XCTAssertEqual(shot.marks.count, 1)
    shot.undo()
    XCTAssertEqual(shot.marks.last?.id, rectangle.id)
  }
  @MainActor func testPlacedTextCanBeEditedCanceledDeletedAndUndoneWithoutReordering() throws {
    let shot = NativeScreenshotDocument(source: try image())
    shot.tool = .text
    shot.beginText(at: CGPoint(x: 10, y: 70))
    shot.label = "One"
    shot.commitText()
    let original = try XCTUnwrap(shot.marks.first)
    shot.add(.init(kind: .arrow, start: .zero, end: CGPoint(x: 8, y: 8)))
    let before = try shot.png()
    shot.beginText(at: CGPoint(x: 12, y: 60))
    XCTAssertEqual(shot.editingTextID, original.id)
    XCTAssertEqual(shot.label, "One")
    shot.label = "Changed"
    shot.style.textSize = 24
    shot.style.textColor = .blue
    shot.style.textBackground = .clear
    let preview = try shot.png()
    shot.commitText()
    XCTAssertEqual(shot.marks.count, 2)
    XCTAssertEqual(shot.marks[0].id, original.id)
    XCTAssertEqual(shot.marks[1].kind, .arrow)
    XCTAssertEqual(try shot.png(), preview)
    XCTAssertNotEqual(preview, before)
    shot.undo()
    XCTAssertEqual(shot.marks[0], original)
    XCTAssertEqual(try shot.png(), before)
    shot.redo()
    XCTAssertEqual(try shot.png(), preview)
    shot.beginText(at: CGPoint(x: 12, y: 60))
    XCTAssertEqual(shot.style.textSize, 24)
    XCTAssertEqual(shot.style.textColor, .blue)
    XCTAssertEqual(shot.style.textBackground, .clear)
    shot.label = "Cancel this edit"
    shot.style.textBackground = .red
    shot.cancelText()
    XCTAssertEqual(try shot.png(), preview)
    shot.beginText(at: CGPoint(x: 12, y: 60))
    shot.commitText()  // Merely opening and finishing must not add an undo entry.
    shot.undo()
    XCTAssertEqual(try shot.png(), before)
    shot.redo()
    shot.beginText(at: CGPoint(x: 12, y: 60))
    shot.label = ""
    shot.commitText()
    XCTAssertEqual(shot.marks.count, 1)
    XCTAssertEqual(shot.marks.first?.kind, .arrow)
    shot.undo()
    XCTAssertEqual(try shot.png(), preview)
    shot.redo()
    XCTAssertEqual(shot.marks.count, 1)
  }
  @MainActor func testTextHitTestingFindsTopmostBlockAndDoesNotDuplicateIt() throws {
    let shot = NativeScreenshotDocument(source: try image())
    let first = NativeScreenshotMark(
      kind: .text, start: CGPoint(x: 10, y: 10),
      end: CGPoint(x: 10, y: 30), text: "First")
    let second = NativeScreenshotMark(kind: .text, start: first.start, end: first.end, text: "Top")
    shot.add(first)
    shot.add(second)
    XCTAssertEqual(shot.text(at: CGPoint(x: 15, y: 15))?.id, second.id)
    XCTAssertNil(shot.text(at: CGPoint(x: 99, y: 79)))
    shot.beginText(at: CGPoint(x: 15, y: 15))
    shot.label = "Edited"
    shot.commitText()
    XCTAssertEqual(shot.marks.count, 2)
    XCTAssertEqual(shot.marks.first, first)
    XCTAssertEqual(shot.marks.last?.id, second.id)
  }
  @MainActor func testInlineTextDraftExportCommitCancelAndUndo() throws {
    let shot = NativeScreenshotDocument(source: try image())
    shot.tool = .text
    let empty = try shot.png()
    shot.beginText(at: CGPoint(x: 10, y: 70))
    shot.label = "Hello\nПривет"
    let draft = try shot.png()
    let pixels = try XCTUnwrap(NSBitmapImageRep(data: draft))
    let outside = try XCTUnwrap(pixels.colorAt(x: 99, y: 20)?.usingColorSpace(.deviceRGB))
    XCTAssertEqual(
      outside.redComponent, 1, accuracy: 0.01,
      "Multiline text background must not fill the rest of the image")
    XCTAssertNotEqual(draft, empty)
    XCTAssertTrue(shot.marks.isEmpty)
    XCTAssertLessThan(try XCTUnwrap(shot.pendingText).start.y, 70)
    shot.commitText()
    XCTAssertNil(shot.textAnchor)
    XCTAssertEqual(shot.marks.last?.text, "Hello\nПривет")
    XCTAssertEqual(try shot.png(), draft)
    shot.undo()
    XCTAssertEqual(try shot.png(), empty)
    shot.redo()
    XCTAssertEqual(try shot.png(), draft)
    shot.beginText(at: CGPoint(x: 20, y: 50))
    shot.label = "Discard"
    shot.cancelText()
    XCTAssertEqual(try shot.png(), draft)
    shot.beginText(at: CGPoint(x: 30, y: 40))
    shot.commitText()
    XCTAssertEqual(shot.marks.count, 1)
  }
  @MainActor func testInlineCanvasRespectsCompositionAndClosePreservesText() throws {
    _ = NSApplication.shared
    let shot = NativeScreenshotDocument(source: try image())
    let editor = NativeScreenshotEditor(shot: shot)
    let canvas = NativeScreenshotCanvas(frame: NSRect(x: 0, y: 0, width: 232, height: 192))
    canvas.document = shot
    editor.canvas = canvas
    shot.tool = .text
    canvas.beginText(at: CGPoint(x: 10, y: 60))
    let input = try XCTUnwrap(canvas.textEditor)
    input.setMarkedText(
      "日本", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertFalse(editor.finishText())
    XCTAssertNotNil(canvas.textEditor)
    input.unmarkText()
    input.string = "Saved on close"
    canvas.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
    XCTAssertTrue(editor.windowShouldClose(try XCTUnwrap(editor.window)))
    XCTAssertEqual(shot.marks.last?.text, "Saved on close")
    XCTAssertNil(canvas.textEditor)
    canvas.beginText(at: CGPoint(x: 20, y: 40))
    canvas.textEditor?.string = "Canceled"
    canvas.textDidChange(
      Notification(name: NSText.didChangeNotification, object: canvas.textEditor))
    canvas.cancelText()
    XCTAssertEqual(shot.marks.count, 1)
    XCTAssertNil(shot.textAnchor)
    editor.close()
  }
  @MainActor func testNewEditClearsRedoAndEmptyTextDoesNotCreateMark() throws {
    let shot = NativeScreenshotDocument(source: try image())
    shot.add(.init(kind: .text, start: .zero, end: .zero, text: "  \n "))
    XCTAssertFalse(shot.canUndo)
    shot.add(.init(kind: .text, start: .zero, end: .zero, text: "Пример"))
    shot.undo()
    XCTAssertTrue(shot.canRedo)
    shot.add(.init(kind: .arrow, start: .zero, end: CGPoint(x: 50, y: 50)))
    XCTAssertFalse(shot.canRedo)
    shot.busy = true
    shot.undo()
    shot.add(.init(kind: .text, start: .zero, end: .zero, text: "blocked"))
    XCTAssertEqual(shot.marks.count, 1)
  }
  @MainActor func testEditorShortcutsRespectIMERepeatBusyAndTextEditing() throws {
    _ = NSApplication.shared
    let shot = NativeScreenshotDocument(source: try image())
    let editor = NativeScreenshotEditor(shot: shot)
    var copied: Data?
    editor.copyImage = { copied = $0 }
    let copy = NativeKeyInput(code: 8, characters: "с", modifiers: .command)
    var composing = copy
    composing.composing = true
    XCTAssertFalse(editor.handleKeyboard(composing))
    var editing = copy
    editing.editing = true
    XCTAssertFalse(editor.handleKeyboard(editing))
    var repeated = copy
    repeated.repeatKey = true
    XCTAssertTrue(editor.handleKeyboard(repeated))
    shot.busy = true
    XCTAssertTrue(editor.handleKeyboard(copy))
    XCTAssertNil(copied)
    shot.busy = false
    XCTAssertTrue(editor.handleKeyboard(copy))
    XCTAssertEqual(copied, try shot.png())
    XCTAssertTrue(editor.handleKeyboard(.init(code: 20, characters: "3", modifiers: .command)))
    XCTAssertEqual(shot.tool, .rectangle)
    shot.add(.init(kind: .arrow, start: .zero, end: CGPoint(x: 50, y: 50)))
    XCTAssertTrue(editor.windowShouldClose(try XCTUnwrap(editor.window)))
    XCTAssertEqual(shot.marks.count, 1)
    XCTAssertTrue(editor.handleKeyboard(.init(code: 6, characters: "я", modifiers: .command)))
    XCTAssertEqual(shot.marks.count, 0)
    XCTAssertTrue(
      editor.handleKeyboard(.init(code: 6, characters: "Я", modifiers: [.command, .shift])))
    XCTAssertEqual(shot.marks.count, 1)
    editor.close()
  }
  @MainActor func testCanvasCoordinatesAndCaptureRectAcrossDisplays() throws {
    let canvas = NativeScreenshotCanvas(frame: NSRect(x: 0, y: 0, width: 232, height: 192))
    canvas.document = NativeScreenshotDocument(source: try image())
    XCTAssertEqual(canvas.imageRect, CGRect(x: 16, y: 16, width: 200, height: 160))
    XCTAssertEqual(canvas.imagePoint(CGPoint(x: 116, y: 96)), CGPoint(x: 50, y: 40))
    XCTAssertEqual(canvas.imagePoint(CGPoint(x: -100, y: 1000)), CGPoint(x: 0, y: 80))
    XCTAssertEqual(
      NativeScreenshotCapture.captureRect(
        CGRect(x: -800, y: 1200, width: 300, height: 200), desktopTop: 1080),
      CGRect(x: -800, y: -320, width: 300, height: 200))
  }
  @MainActor func testMixedScaleCompositionAlignsPixelsAndCropAcrossDisplaySeam() throws {
    func solid(_ color: NSColor, width: Int, height: Int) throws -> CGImage {
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(color.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      return try XCTUnwrap(context.makeImage())
    }
    let layout = try XCTUnwrap(
      NativeScreenshotCaptureLayout(
        selection: CGRect(x: 20, y: -20, width: 60, height: 40),
        displays: [
          .init(frame: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 2),
          .init(frame: CGRect(x: -20, y: 80, width: 160, height: 90), scale: 1),
        ], desktopTop: 80))
    let image = try layout.composite([
      solid(.red, width: 200, height: 160), solid(.blue, width: 160, height: 90),
    ])
    XCTAssertEqual(image.width, 320)
    XCTAssertEqual(image.height, 340)
    let pixels = NSBitmapImageRep(cgImage: image)
    XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: 300, y: 160)).blueComponent, 0.95)
    XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: 200, y: 320)).redComponent, 0.95)
    XCTAssertEqual(try XCTUnwrap(pixels.colorAt(x: 300, y: 300)).alphaComponent, 0)
    let shot = NativeScreenshotDocument(
      source: image,
      area: layout.pixelArea(imageSize: CGSize(width: image.width, height: image.height)))
    XCTAssertEqual(shot.source.width, 120)
    XCTAssertEqual(shot.source.height, 80)
    let crop = NSBitmapImageRep(cgImage: shot.source)
    XCTAssertGreaterThan(try XCTUnwrap(crop.colorAt(x: 60, y: 10)).blueComponent, 0.95)
    XCTAssertGreaterThan(try XCTUnwrap(crop.colorAt(x: 60, y: 70)).redComponent, 0.95)
    XCTAssertThrowsError(try layout.composite([]))
  }
  func testCaptureSpansMixedScaleDisplaysWithNegativeOrigins() throws {
    let layout = try XCTUnwrap(
      NativeScreenshotCaptureLayout(
        selection: CGRect(x: -200, y: 100, width: 500, height: 400),
        displays: [
          .init(frame: CGRect(x: -1280, y: 0, width: 1280, height: 1024), scale: 1),
          .init(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2),
        ], desktopTop: 1080))
    XCTAssertEqual(layout.captureFrame, CGRect(x: -1280, y: 0, width: 3200, height: 1080))
    XCTAssertEqual(layout.scale, 2)
    XCTAssertEqual(
      layout.pixelArea(imageSize: CGSize(width: 6400, height: 2160)),
      CGRect(x: 2160, y: 1160, width: 1000, height: 800))
    XCTAssertEqual(layout.editorFrame, CGRect(x: 0, y: 0, width: 1920, height: 1080))
  }
  func testCaptureSpansVerticallyArrangedDisplaysAndKeepsSingleDisplayBounds() throws {
    let displays: [NativeScreenshotDisplay] = [
      .init(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1),
      .init(frame: CGRect(x: -200, y: 1080, width: 1440, height: 900), scale: 2),
    ]
    let layout = try XCTUnwrap(
      NativeScreenshotCaptureLayout(
        selection: CGRect(x: 100, y: -100, width: 400, height: 300),
        displays: displays, desktopTop: 1080))
    XCTAssertEqual(layout.captureFrame, CGRect(x: -200, y: -900, width: 2120, height: 1980))
    XCTAssertEqual(
      layout.pixelArea(imageSize: CGSize(width: 4240, height: 3960)),
      CGRect(x: 600, y: 1760, width: 800, height: 600))
    let single = try XCTUnwrap(
      NativeScreenshotCaptureLayout(
        selection: CGRect(x: 10, y: 0, width: 200, height: 200),
        displays: displays, desktopTop: 1080))
    XCTAssertEqual(single.captureFrame, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    XCTAssertEqual(single.scale, 1)
    XCTAssertNil(
      NativeScreenshotCaptureLayout(
        selection: CGRect(x: -500, y: 500, width: 100, height: 100),
        displays: displays, desktopTop: 1080))
  }
  @MainActor func testSharedSelectionCrossesDisplayEdgesInBothDirections() {
    let selection = NativeScreenshotSelection(
      bounds: CGRect(x: -800, y: -600, width: 1800, height: 1600))
    var updates = 0
    selection.changed = { updates += 1 }
    selection.begin(CGPoint(x: -200, y: 200))
    selection.update(CGPoint(x: 500, y: 800))
    XCTAssertEqual(selection.rect, CGRect(x: -200, y: 200, width: 700, height: 600))
    selection.begin(CGPoint(x: 500, y: 800))
    selection.update(CGPoint(x: -200, y: 200))
    XCTAssertEqual(selection.rect, CGRect(x: -200, y: 200, width: 700, height: 600))
    selection.update(CGPoint(x: -1000, y: -900))
    XCTAssertEqual(selection.rect, CGRect(x: -800, y: -600, width: 1300, height: 1400))
    selection.clear()
    XCTAssertNil(selection.rect)
    XCTAssertEqual(updates, 6)
  }
  @MainActor func testCaptureCloseDiscardsWithoutExportAndCancelCreatesNothing() async throws {
    let model = NativeUIModel()
    let captures = NativeScreenshots(model: model, fixture: true)
    var copied = false
    var exported = false
    captures.copyImage = { _ in copied = true }
    captures.exportFile = { _, _ in exported = true }
    weak var released: NativeScreenshotDocument?
    try autoreleasepool {
      let document = try captures.insert(image())
      released = document
      let editor = try XCTUnwrap(captures.editors[document.id])
      editor.window?.performClose(nil)
      XCTAssertTrue(captures.editors.isEmpty)
    }
    XCTAssertNil(released)
    XCTAssertFalse(copied)
    XCTAssertFalse(exported)
    captures.captureImage = { nil }
    try await captures.capture()
    XCTAssertTrue(captures.editors.isEmpty)
    XCTAssertFalse(model.screenshotCapturing)
  }
  @MainActor func testScreenshotCopyRecordsHistoryAndFailuresKeepCaptureOpen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    try platform.history.initialize()
    let shot = try platform.screenshots.insert(image())
    let editor = try XCTUnwrap(platform.screenshots.editors[shot.id])
    editor.copyImage = { _ in throw PolkaCoreError.invalid("Synthetic copy failure") }
    editor.copyScreenshot()
    XCTAssertNotNil(platform.screenshots.editors[shot.id])
    XCTAssertEqual(shot.message, "Synthetic copy failure")
    editor.addToShelf = { _, _ in throw PolkaCoreError.invalid("Synthetic shelf failure") }
    editor.shelf()
    XCTAssertNotNil(platform.screenshots.editors[shot.id])
    XCTAssertEqual(shot.message, "Synthetic shelf failure")
    editor.copyImage = platform.screenshots.copyImage
    editor.copyScreenshot()
    XCTAssertTrue(platform.screenshots.editors.isEmpty)
    XCTAssertTrue(platform.capture.syntheticTypes.contains("public.png"))
    XCTAssertTrue(
      platform.history.snapshot().clips.contains {
        $0.kind == .image && $0.content == (try? shot.png().base64EncodedString())
      })
    var preferences = platform.history.getPreferences()
    preferences.paused = true
    try platform.history.setPreferences(preferences)
    let count = platform.history.snapshot().clips.count
    try platform.capture.writeScreenshot(shot.png())
    XCTAssertEqual(platform.history.snapshot().clips.count, count)
    await platform.shutdown()
  }
  @MainActor func testCaptureFailureIsVisible() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    try platform.history.initialize()
    platform.show = { destination, _ in platform.model.present(destination: destination ?? "apps") }
    platform.screenshots.captureImage = { throw PolkaCoreError.invalid("Synthetic capture denied") }
    try await platform.handle(.init("screenshots.capture"))
    XCTAssertEqual(platform.model.destination, "apps")
    XCTAssertEqual(platform.model.error, "Synthetic capture denied")
    XCTAssertFalse(platform.model.screenshotCapturing)
    XCTAssertTrue(platform.screenshots.editors.isEmpty)
    platform.show = nil
    await platform.shutdown()
  }
  @MainActor func testDirectCopyWritesPNGAndHistoryWithoutOpeningEditor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    try platform.history.initialize()
    let source = try image()
    platform.screenshots.captureImage = { source }
    let revision = platform.capture.clipboardRevision
    try await platform.handle(.init("screenshots.copy"))
    XCTAssertTrue(platform.screenshots.editors.isEmpty)
    XCTAssertFalse(platform.model.screenshotCapturing)
    XCTAssertEqual(platform.capture.clipboardRevision, revision + 1)
    XCTAssertTrue(platform.capture.syntheticTypes.contains("public.png"))
    let clip = try XCTUnwrap(platform.history.snapshot().clips.first { $0.kind == .image })
    let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(Data(base64Encoded: clip.content))))
    XCTAssertEqual(png.pixelsWide, 100)
    XCTAssertEqual(png.pixelsHigh, 80)
    XCTAssertEqual(try XCTUnwrap(png.colorAt(x: 50, y: 40)).redComponent, 1, accuracy: 0.01)
    platform.screenshots.captureImage = { nil }
    try await platform.handle(.init("screenshots.copy"))
    XCTAssertEqual(platform.capture.clipboardRevision, revision + 1)
    await platform.shutdown()
  }
  @MainActor func testDirectCopyPreservesDraftsAndRestoresEditorsAfterFailure() async throws {
    let model = NativeUIModel()
    let captures = NativeScreenshots(model: model, fixture: true)
    defer { captures.stop() }
    let source = try image()
    let draft = try captures.insert(source)
    let mark = NativeScreenshotMark(
      kind: .text, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 80, y: 40), text: "Draft")
    draft.add(mark)
    draft.selectObject(mark)
    let editor = try XCTUnwrap(captures.editors[draft.id])
    var copied = 0
    captures.captureImage = {
      XCTAssertFalse(editor.window?.isVisible == true)
      XCTAssertTrue(model.screenshotCapturing)
      // A second invocation while selecting must do nothing.
      try await captures.capture(copyImmediately: true)
      return source
    }
    captures.copyImage = { _ in copied += 1 }
    draft.busy = true
    try await captures.capture(copyImmediately: true)
    XCTAssertEqual(copied, 0)
    XCTAssertFalse(model.screenshotCapturing)
    draft.busy = false
    try await captures.capture(copyImmediately: true)
    XCTAssertEqual(copied, 1)
    XCTAssertEqual(captures.editors.count, 1)
    XCTAssertTrue(editor.window?.isVisible == true)
    XCTAssertEqual(draft.marks, [mark])
    XCTAssertEqual(draft.objectDraft?.id, mark.id)
    captures.copyImage = { _ in throw PolkaCoreError.invalid("Synthetic copy failure") }
    do {
      try await captures.capture(copyImmediately: true)
      XCTFail("copy failure was swallowed")
    } catch { XCTAssertEqual(error.localizedDescription, "Synthetic copy failure") }
    XCTAssertFalse(model.screenshotCapturing)
    XCTAssertTrue(editor.window?.isVisible == true)
    XCTAssertEqual(draft.marks, [mark])
    XCTAssertEqual(draft.objectDraft?.id, mark.id)
    captures.captureImage = { throw PolkaCoreError.invalid("Synthetic capture failure") }
    do {
      try await captures.capture(copyImmediately: true)
      XCTFail("capture failure was swallowed")
    } catch { XCTAssertEqual(error.localizedDescription, "Synthetic capture failure") }
    XCTAssertTrue(editor.window?.isVisible == true)
    XCTAssertFalse(model.screenshotCapturing)
  }
  @MainActor func testDirectCopyShortcutConflictsPersistAndDisableIndependently() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    await platform.initialize()
    await platform.waitForInitialization()
    let copyDefault = "CommandOrControl+Control+Shift+Alt+4"
    XCTAssertEqual(platform.model.settings.screenshotCopyShortcut, copyDefault)
    XCTAssertTrue(platform.model.settings.screenshotCopyShortcutError.isEmpty)
    for occupied in [
      "CommandOrControl+Shift+Space", "CommandOrControl+Shift+V",
      "CommandOrControl+Shift+Alt+4",
    ] {
      do {
        try await platform.handle(
          .init("screenshots.copyShortcut", strings: ["accelerator": occupied]))
        XCTFail("accepted occupied shortcut")
      } catch {}
      XCTAssertEqual(platform.model.settings.screenshotCopyShortcut, copyDefault)
      XCTAssertEqual(
        try platform.settings.get(key: "screenshotCopyShortcut") as? String, copyDefault)
      XCTAssertFalse(platform.model.settings.screenshotCopyShortcutError.isEmpty)
    }
    for command in ["launcher.setShortcut", "clipboardHistory.shortcut", "screenshots.shortcut"] {
      do {
        try await platform.handle(.init(command, strings: ["accelerator": copyDefault]))
        XCTFail("allowed another action to take the copy shortcut")
      } catch {}
    }
    let custom = "CommandOrControl+Shift+Alt+5"
    try await platform.handle(.init("screenshots.copyShortcut", strings: ["accelerator": custom]))
    XCTAssertEqual(platform.model.settings.screenshotCopyShortcut, custom)
    XCTAssertTrue(platform.model.settings.screenshotCopyShortcutError.isEmpty)
    try await platform.handle(.init("screenshots.shortcut", strings: ["accelerator": ""]))
    XCTAssertEqual(platform.model.settings.screenshotCopyShortcut, custom)
    try await platform.handle(.init("screenshots.copyShortcut", strings: ["accelerator": ""]))
    XCTAssertEqual(platform.model.settings.screenshotCopyShortcut, "")
    try await platform.handle(.init("screenshots.copyShortcut", strings: ["accelerator": custom]))
    await platform.shutdown()
    let restored = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    XCTAssertEqual(restored.model.settings.screenshotCopyShortcut, custom)
    XCTAssertEqual(restored.model.settings.screenshotShortcut, "")
    await restored.shutdown()
  }
  @MainActor func testExistingShortcutWinsOverNewDefaultAtStartup() async throws {
    for action in ["launcher", "clipboard"] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      if action == "launcher" {
        let settings = try SettingsStore(root: root)
        try settings.set(key: "launcherShortcut", value: "CommandOrControl+Shift+Alt+4")
        settings.close()
      }
      let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
      try platform.history.initialize()
      if action == "clipboard" {
        var preferences = platform.history.getPreferences()
        preferences.accelerator = "CommandOrControl+Shift+Alt+4"
        try platform.history.setPreferences(preferences)
      }
      await platform.initialize()
      await platform.waitForInitialization()
      XCTAssertTrue(platform.model.settings.launcherShortcutError.isEmpty)
      XCTAssertTrue(platform.model.settings.clipboardShortcutError.isEmpty)
      XCTAssertFalse(platform.model.settings.screenshotShortcutError.isEmpty)
      await platform.shutdown()
    }
  }
  @MainActor func testScreenshotShortcutConflictsAndDisabledCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try NativePlatform(model: NativeUIModel(), root: root, fixture: true)
    try platform.history.initialize()
    for shortcut in ["CommandOrControl+Shift+Space", "CommandOrControl+Shift+V"] {
      do {
        try await platform.handle(.init("screenshots.shortcut", strings: ["accelerator": shortcut]))
        XCTFail("accepted occupied shortcut")
      } catch {}
    }
    XCTAssertEqual(platform.model.settings.screenshotShortcut, "CommandOrControl+Shift+Alt+4")
    try await platform.handle(
      .init(
        "builtinApps.setEnabled", strings: ["id": "builtin:screenshots"], bools: ["enabled": false])
    )
    for command in [
      "screenshots.capture", "screenshots.copy",
    ] {
      do {
        try await platform.handle(.init(command))
        XCTFail("allowed disabled action")
      } catch {}
    }
    await platform.shutdown()
  }
}
