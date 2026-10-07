import Foundation
import Vision
import ImageIO
import CoreML

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
    // The configured languages already cover Russian/English and mixed lines.
    // Avoid a separate automatic-language model with different device support.
    request.automaticallyDetectsLanguage = false
    // Background indexing must also work on virtual Macs without Metal/ANE.
    // Select only CPU devices that Vision declares valid for each stage.
    for (stage, devices) in try request.supportedComputeStageDevices {
        if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
            request.setComputeDevice(cpu, for: stage)
        }
    }
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
    try VNImageRequestHandler(cgImage: image).perform([request])
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
    var details: [String: Any] = ["domain": domain, "code": failure.code]
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
