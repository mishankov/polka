import AppKit
import Darwin
import PolkaCore

struct NativeClipboardItem {
  var types: [String]
  var text: String?
  var images: [String: Data]
  init(types: [String], text: String? = nil, images: [String: Data] = [:]) {
    self.types = types
    self.text = text
    self.images = images
  }
}
struct NativeClipboardSnapshot {
  var changeCount: Int
  var items: [NativeClipboardItem]
}

@MainActor final class NativeClipboardCapture {
  let history: ClipboardHistory
  let fixture: Bool
  private var capturedChange = -1
  private var fixtureText = ""
  private var fixtureTypes: [String] = []
  private var ocrBusy = false
  private var stopped = false
  private(set) var enabled = true
  func setEnabled(_ value: Bool) {
    guard enabled != value else { return }
    enabled = value
    cancel()
    // Do not capture the pasteboard contents left while the app was disabled.
    if !fixture { capturedChange = NSPasteboard.general.changeCount }
    if value { indexImages() }
  }
  private var generation = 0
  private var activeImage: (id: String, incarnation: Int)?
  private var ocrTask: Task<Void, Never>?
  private let recognize: (Data) async throws -> Data
  let ocrVersion: String
  private static let imageTypes = [
    "public.png", "image/png", "public.jpeg", "image/jpeg", "public.tiff", "image/tiff",
    "com.microsoft.bmp", "image/bmp", "org.webmproject.webp", "image/webp",
  ]
  // Native pasteboard APIs take UTIs rather than MIME-format aliases.
  private static let pasteboardImageTypes: [NSPasteboard.PasteboardType] = [
    .png, NSPasteboard.PasteboardType("public.jpeg"), .tiff,
    NSPasteboard.PasteboardType("com.microsoft.bmp"),
    NSPasteboard.PasteboardType("org.webmproject.webp"),
  ]
  init(history: ClipboardHistory, fixture: Bool, recognize: ((Data) async throws -> Data)? = nil) {
    self.history = history
    self.fixture = fixture
    self.recognize =
      recognize ?? { data in
        try await NativeCommand.run(
          NativeProfile.helper("image-text"), stdin: data, timeout: 60, limit: 8 * 1024 * 1024)
      }
    var name = utsname()
    uname(&name)
    let release = withUnsafePointer(to: &name.release) {
      $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
    ocrVersion = "vision-r3-accurate-ru-en-correction-cpu-software-image-bundle-v6-\(release)"
  }
  func capture() throws {
    guard !fixture, enabled, !stopped, history.storage.ready, !history.getPreferences().paused
    else {
      return
    }
    let board = NSPasteboard.general
    guard board.changeCount != capturedChange,
      let snapshot = Self.snapshot(from: board)
    else { return }
    try capture(snapshot: snapshot)
  }
  /// Reads only offered native representations. A private board exercises this
  /// same path in tests without accessing the user's general pasteboard.
  static func snapshot(from board: NSPasteboard) -> NativeClipboardSnapshot? {
    let count = board.changeCount
    let items = board.pasteboardItems ?? []
    // A sensitive representation on any item excludes the complete clipboard snapshot.
    if items.contains(where: { excludedClipboardType($0.types.map(\.rawValue)) }) {
      guard board.changeCount == count else { return nil }
      return NativeClipboardSnapshot(
        changeCount: count,
        items: items.map { NativeClipboardItem(types: $0.types.map(\.rawValue)) })
    }
    let snapshot = NativeClipboardSnapshot(
      changeCount: count,
      items: items.map { item in
        // MIME aliases remain supported by synthetic snapshots, but
        // cannot select a representation that native AppKit cannot read.
        let types = item.types.map(\.rawValue).filter {
          !imageTypes.contains($0) || !$0.contains("/")
        }
        var images: [String: Data] = [:]
        if let type = pasteboardImageTypes.first(where: item.types.contains),
          let data = item.data(forType: type)
        {
          images[type.rawValue] = data
        }
        var text: String?
        if item.types.contains(.string) { text = item.string(forType: .string) }
        for type in ["public.utf16-plain-text", "public.utf16-external-plain-text"] {
          let representation = NSPasteboard.PasteboardType(type)
          if text == nil, item.types.contains(representation),
            let data = item.data(forType: representation)
          {
            text = String(data: data, encoding: .utf16)
          }
        }
        let plain = NSPasteboard.PasteboardType("public.plain-text")
        if text == nil, item.types.contains(plain) {
          text = item.string(forType: plain)
        }
        return NativeClipboardItem(types: types, text: text, images: images)
      })
    guard board.changeCount == count else { return nil }
    return snapshot
  }
  /// Injection point for consistent synthetic pasteboard snapshots; no system clipboard access.
  func capture(snapshot: NativeClipboardSnapshot) throws {
    guard enabled, !stopped, history.storage.ready, !history.getPreferences().paused,
      snapshot.changeCount != capturedChange
    else { return }
    capturedChange = snapshot.changeCount
    guard !snapshot.items.contains(where: { excludedClipboardType($0.types) }) else { return }
    let epoch = generation
    for item in snapshot.items {
      if let type = Self.imageTypes.first(where: item.types.contains) {
        guard let bytes = item.images[type] else {
          throw PolkaCoreError.invalid(
            "Не удалось прочитать скопированное изображение. Попробуйте скопировать его ещё раз.")
        }
        guard bytes.count <= ClipboardLimits.maxImageBytes else {
          throw PolkaCoreError.invalid(
            "Изображение не сохранено: размер превышает 32 МБ. Скопируйте меньшую область.")
        }
        guard let image = NSBitmapImageRep(data: bytes), image.pixelsWide > 0, image.pixelsHigh > 0,
          let source = image.cgImage
        else {
          throw PolkaCoreError.invalid(
            "Не удалось прочитать скопированное изображение. Попробуйте скопировать его ещё раз.")
        }
        let png: Data
        if ["public.png", "image/png"].contains(type) {
          png = bytes
        } else {
          guard let converted = image.representation(using: .png, properties: [:]) else {
            throw PolkaCoreError.invalid(
              "Не удалось прочитать скопированное изображение. Попробуйте скопировать его ещё раз.")
          }
          png = converted
        }
        guard png.count <= ClipboardLimits.maxImageBytes else {
          throw PolkaCoreError.invalid(
            "Изображение не сохранено: размер PNG превышает 32 МБ. Скопируйте меньшую область.")
        }
        let scale = min(1, 240 / Double(image.pixelsWide), 100 / Double(image.pixelsHigh))
        let width = max(1, Int((Double(image.pixelsWide) * scale).rounded()))
        let height = max(1, Int((Double(image.pixelsHigh) * scale).rounded()))
        guard
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PolkaCoreError.invalid("Не удалось создать миниатюру изображения") }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage(),
          let preview = NSBitmapImageRep(cgImage: thumbnail).representation(
            using: .png, properties: [:])
        else { throw PolkaCoreError.invalid("Не удалось создать миниатюру изображения") }
        guard epoch == generation, enabled, !stopped, history.storage.ready,
          !history.getPreferences().paused
        else { return }
        try history.add(
          .image, content: png.base64EncodedString(),
          preview: "data:image/png;base64," + preview.base64EncodedString())
        return
      }
      if item.types.contains(where: {
        $0.range(
          of: "public\\.file-url|NSFilenamesPboardType",
          options: [.regularExpression, .caseInsensitive]) != nil
      }) {
        continue
      }
      if let text = item.text {
        guard text.utf8.count <= 1024 * 1024 else {
          throw PolkaCoreError.invalid("Текст не сохранён: размер превышает 1 МБ.")
        }
        guard epoch == generation, enabled, !stopped, history.storage.ready,
          !history.getPreferences().paused
        else { return }
        try history.add(
          .text, content: text, preview: String(decoding: text.utf16.prefix(400), as: UTF16.self))
        return
      }
    }
  }
  func write(text: String, concealed: Bool = false) {
    if fixture {
      fixtureText = text
      fixtureTypes =
        ["public.utf8-plain-text", "org.nspasteboard.AutoGeneratedType"]
        + (concealed ? ["org.nspasteboard.ConcealedType"] : [])
      return
    }
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
    board.setData(
      Data([1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
    if concealed {
      board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
    capturedChange = board.changeCount
  }
  func write(image: Data) {
    if fixture {
      fixtureTypes = ["public.png", "org.nspasteboard.AutoGeneratedType"]
      return
    }
    let board = NSPasteboard.general
    board.clearContents()
    board.setData(image, forType: .png)
    board.setData(
      Data([1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
    capturedChange = board.changeCount
  }
  var syntheticText: String { fixtureText }
  var syntheticTypes: [String] { fixtureTypes }
  func indexImages() {
    if let activeImage,
      !history.storage.ready
        || !history.imageTextImages().contains(where: {
          $0.id == activeImage.id && $0.incarnation == activeImage.incarnation
        })
    {
      cancel()
    }
    guard enabled, !stopped, !ocrBusy, history.storage.ready else { return }
    guard let image = history.imageTextImages().first(where: { $0.ocr?.version != ocrVersion }),
      let png = Data(base64Encoded: image.content)
    else { return }
    ocrBusy = true
    activeImage = (image.id, image.incarnation)
    let epoch = generation
    ocrTask = Task {
      defer {
        ocrBusy = false
        activeImage = nil
        ocrTask = nil
        if !stopped { indexImages() }
      }
      let result: ImageText
      do {
        let data = try await recognize(png)
        try Task.checkCancellation()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = object["text"] as? String, raw.utf16.count <= 1024 * 1024,
          let languages = object["languages"] as? [String], languages.count <= 20,
          languages.allSatisfy({ $0.utf16.count <= 40 })
        else { throw PolkaCoreError.invalid("Некорректный результат OCR") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        result = ImageText(
          version: ocrVersion, status: text.isEmpty ? .empty : .ready, text: text,
          languages: languages)
      } catch {
        guard !Task.isCancelled else { return }
        result = ImageText(version: ocrVersion, status: .failed, text: "", languages: [])
      }
      guard epoch == generation, enabled, !stopped, !Task.isCancelled else { return }
      try? history.saveImageText(image.id, incarnation: image.incarnation, result: result)
    }
  }
  func cancel() {
    generation += 1
    ocrTask?.cancel()
  }
  func stop() {
    stopped = true
    cancel()
  }
  /// Shutdown waits for cancellation to reap the OCR helper before the app exits or updates.
  func waitForStop() async { await ocrTask?.value }
}
