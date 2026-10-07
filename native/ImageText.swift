import Foundation
import Vision
import ImageIO
import CoreImage

// A single request per process. PNG bytes travel over stdin and never touch disk.
// Revision and options are mirrored in IMAGE_TEXT_VERSION in the host.
var stage = "configure"
do {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    // Set this before language/model discovery as well as recognition. The
    // per-stage replacement API itself can fail while discovering devices on
    // virtual Macs without GPU/ANE, so retain Vision's CPU-only compatibility
    // switch for this background helper despite its macOS 14 deprecation.
    request.usesCPUOnly = true
    request.preferBackgroundProcessing = true
    stage = "languages"
    let supported = try request.supportedRecognitionLanguages()
    let languages = ["ru-RU", "en-US"].filter { supported.contains($0) }
    guard !languages.isEmpty else { throw NSError(domain: "ImageText", code: 1) }
    request.recognitionLanguages = languages
    // The configured languages already cover Russian/English and mixed lines.
    // Avoid a separate automatic-language model with different device support.
    request.automaticallyDetectsLanguage = false
    stage = "decode"
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 32 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, Double(width) * Double(height) <= 80_000_000 else {
        throw NSError(domain: "ImageText", code: 2)
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
        throw NSError(domain: "ImageText", code: 2)
    }
    stage = "recognize"
    // Request compute settings do not configure Core Image preprocessing.
    // Supply a software context so decoding/cropping does not require Metal.
    let context = CIContext(options: [.useSoftwareRenderer: true])
    try VNImageRequestHandler(cgImage: image, options: [.ciContext: context]).perform([request])
    stage = "encode"
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.utf8.count <= 1024 * 1024 else { throw NSError(domain: "ImageText", code: 3) }
    let output = try JSONSerialization.data(withJSONObject: ["text": text, "languages": languages])
    FileHandle.standardOutput.write(output)
} catch {
    // Only safe domains/codes, never descriptions that could contain image data.
    let failure = error as NSError
    let domain = failure.domain.range(of: "^[A-Za-z0-9_.-]{1,120}$", options: .regularExpression) != nil
        ? failure.domain : "Vision"
    var details: [String: Any] = ["domain": domain, "code": failure.code, "stage": stage]
    // Explicit CLI diagnostics are used only with the checked-in synthetic
    // fixture by the failing unit test. The application never passes this flag.
    if CommandLine.arguments.contains("--diagnostics") {
        details["description"] = failure.description
    }
    if let output = try? JSONSerialization.data(withJSONObject: ["error": details]) {
        FileHandle.standardOutput.write(output)
    }
    exit(1)
}
