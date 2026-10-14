import AppKit
import PolkaCore
import XCTest

@testable import PolkaApp

final class NativeScreenshotTests: XCTestCase {
  @MainActor private func image() throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 100, height: 80,
        bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    return try XCTUnwrap(context.makeImage())
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
    let selection = NativeScreenshotRegionSelection(
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
      "screenshots.capture"
    ] {
      do {
        try await platform.handle(.init(command))
        XCTFail("allowed disabled action")
      } catch {}
    }
    await platform.shutdown()
  }
}
