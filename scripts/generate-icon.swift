import AppKit

// Run: swift scripts/generate-icon.swift
// The app icon is image-generated; this script only builds the menu bar glyph.
let output = URL(fileURLWithPath: "native-app/Resources", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for scale in 1...3 {
  let pixels = 18 * scale
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  )!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let transform = NSAffineTransform()
  transform.scale(by: CGFloat(scale))
  transform.concat()
  NSColor.black.setFill()
  // Two objects and one shelf, separated enough to survive at 1x.
  NSBezierPath(
    roundedRect: NSRect(x: 3, y: 6, width: 5, height: 9),
    xRadius: 1.25, yRadius: 1.25
  ).fill()
  NSBezierPath(
    roundedRect: NSRect(x: 10, y: 6, width: 5, height: 5),
    xRadius: 1.25, yRadius: 1.25
  ).fill()
  NSBezierPath(
    roundedRect: NSRect(x: 1, y: 2, width: 16, height: 2),
    xRadius: 1, yRadius: 1
  ).fill()
  NSGraphicsContext.restoreGraphicsState()
  bitmap.size = NSSize(width: 18, height: 18)
  let suffix = scale == 1 ? "" : "@\(scale)x"
  let name = "polkaTemplate\(suffix).png"
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: output.appendingPathComponent(name))
  print("Wrote \(name) (\(pixels)×\(pixels))")
}
