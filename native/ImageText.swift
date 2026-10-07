import Foundation
import Vision
import ImageIO

// A single request per process. PNG bytes travel over stdin and never touch disk.
// Revision and options are mirrored in IMAGE_TEXT_VERSION in the host.
do {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let supported = try request.supportedRecognitionLanguages()
    let languages = ["ru-RU", "en-US"].filter { supported.contains($0) }
    guard !languages.isEmpty else { throw NSError(domain: "ImageText", code: 1) }
    request.recognitionLanguages = languages
    request.automaticallyDetectsLanguage = true
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 32 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, Double(width) * Double(height) <= 80_000_000 else {
        throw NSError(domain: "ImageText", code: 2)
    }
    try VNImageRequestHandler(data: data).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.utf8.count <= 1024 * 1024 else { throw NSError(domain: "ImageText", code: 3) }
    let output = try JSONSerialization.data(withJSONObject: ["text": text, "languages": languages])
    FileHandle.standardOutput.write(output)
} catch {
    // Do not expose recognized text, pixels, paths, or native diagnostics in logs.
    FileHandle.standardError.write(Data("Image text recognition failed\n".utf8))
    exit(1)
}
