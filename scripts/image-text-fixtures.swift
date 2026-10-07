import AppKit

// Reproducible synthetic screenshot fixtures; no screen capture or clipboard access.
let folder = CommandLine.arguments[1]
let fixtures = [
    "english": "Project Aurora\nLaunch checklist\nDelivery confirmed October 2026",
    "russian": "Проект Север\nПроверка готовности\nДоставка подтверждена октябрь 2026",
    "mixed": "Project Aurora / Проект Север\nDelivery confirmed / Доставка подтверждена\nInvoice 2048 / Счёт 2048",
    "empty": "",
    "failure": "Retry recognition fixture\nTemporary Vision failure"
]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for (name, text) in fixtures {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 700,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1400, height: 700).fill()
    (text as NSString).draw(in: NSRect(x: 60, y: 100, width: 1280, height: 500), withAttributes: [
        .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black
    ])
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
}
