import Foundation
import Vision
import ImageIO
import CoreImage
import CoreVideo
import CoreML

// Test-only diagnostics. Call with a checked-in synthetic PNG, never user data.
// This program is not packaged or invoked by the application.
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let source = CGImageSourceCreateWithData(data as CFData, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let software = CIContext(options: [.useSoftwareRenderer: true])

func handler(_ input: String) throws -> VNImageRequestHandler {
    switch input {
    case "data": return VNImageRequestHandler(data: data)
    case "software": return VNImageRequestHandler(cgImage: image, options: [.ciContext: software])
    case "pixel-buffer":
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess,
            let buffer else { throw NSError(domain: "DiagnosticBuffer", code: 1) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width,
            height: image.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { throw NSError(domain: "DiagnosticBuffer", code: 2) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return VNImageRequestHandler(cvPixelBuffer: buffer, options: [.ciContext: software])
    default: return VNImageRequestHandler(cgImage: image)
    }
}

let variants = [
    ("default-en", false, true, false, 3, false, false, "data"),
    ("cpu-data-en", true, true, false, 3, false, false, "data"),
    ("cpu-cg-en", true, true, false, 3, false, false, "cg"),
    ("cpu-software-en", true, true, false, 3, false, false, "software"),
    ("cpu-pixel-buffer-en", true, true, false, 3, false, false, "pixel-buffer"),
    ("cpu-no-correction-en", true, false, false, 3, false, false, "software"),
    ("cpu-revision2-en", true, true, false, 2, false, false, "software"),
    ("cpu-fast-en", true, true, false, 3, true, false, "software"),
    ("modern-cpu-en", false, true, false, 3, false, true, "software"),
    ("default-mixed", false, true, true, 3, false, false, "software"),
    ("cpu-mixed", true, true, true, 3, false, false, "software"),
]
for (name, cpu, correction, mixed, revision, fast, devices, input) in variants {
    var output: [String: Any] = ["variant": name]
    var phase = "configure"
    var completionError: Error?
    do {
        let request = VNRecognizeTextRequest { _, error in completionError = error }
        request.revision = revision
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesCPUOnly = cpu
        request.usesLanguageCorrection = correction
        request.recognitionLanguages = mixed ? ["ru-RU", "en-US"] : ["en-US"]
        request.automaticallyDetectsLanguage = false
        if devices {
            phase = "devices"
            for (stage, supported) in try request.supportedComputeStageDevices {
                if let cpu = supported.first(where: { if case .cpu = $0 { return true }; return false }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
        phase = "handler"
        let imageHandler = try handler(input)
        phase = "recognize"
        try imageHandler.perform([request])
        output["text"] = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    } catch {
        output["error"] = String(describing: error as NSError)
        output["phase"] = phase
    }
    if let completionError { output["completionError"] = String(describing: completionError as NSError) }
    let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    print(String(data: json, encoding: .utf8)!)
    fflush(stdout) // Preserve completed variants if a later one hits the timeout.
}

// Compare the current Swift API too, which can expose richer error details
// than the Objective-C bridge's generic nilError.
if #available(macOS 15.0, *) {
    for cpu in [false, true] {
        var output: [String: Any] = ["variant": cpu ? "swift-cpu-mixed" : "swift-default-mixed"]
        do {
            var request = RecognizeTextRequest(.revision3)
            request.recognitionLevel = .accurate
            request.recognitionLanguages = [Locale.Language(identifier: "ru-RU"), Locale.Language(identifier: "en-US")]
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = false
            if cpu {
                for (stage, devices) in request.supportedComputeStageDevices {
                    if let device = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                        request.setComputeDevice(device, for: stage)
                    }
                }
            }
            let results = try await request.perform(on: image)
            output["text"] = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch {
            output["error"] = String(reflecting: error)
        }
        let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(data: json, encoding: .utf8)!)
        fflush(stdout)
    }
}
