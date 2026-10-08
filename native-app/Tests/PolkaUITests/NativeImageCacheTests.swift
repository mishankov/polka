import AppKit
import XCTest

@testable import PolkaApp

final class NativeImageCacheTests: XCTestCase {
  @MainActor private func png(width: Int, height: Int, blue: Bool = false) throws -> Data {
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
    let bytes = try XCTUnwrap(bitmap.bitmapData)
    for pixel in 0..<(width * height) {
      bytes[pixel * 4] = blue ? 0 : 255
      bytes[pixel * 4 + 1] = 0
      bytes[pixel * 4 + 2] = blue ? 255 : 0
      bytes[pixel * 4 + 3] = 255
    }
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }
  private func dataURL(_ data: Data) -> String {
    "data:image/png;base64," + data.base64EncodedString()
  }

  @MainActor func testRepeatedImmutableIconReusesDecodedImageAndChangedBytesRefresh() throws {
    let cache = NativeImageCache()
    let originalURL = dataURL(try png(width: 16, height: 16))
    let first = try XCTUnwrap(cache.image(originalURL))
    for _ in 0..<100 { XCTAssertTrue(cache.image(originalURL) === first) }
    XCTAssertEqual(cache.decodeCount, 1)
    let changed = try XCTUnwrap(cache.image(dataURL(try png(width: 20, height: 20, blue: true))))
    XCTAssertFalse(changed === first)
    XCTAssertEqual(changed.size.width, 20)
    XCTAssertEqual(cache.decodeCount, 2)
    XCTAssertTrue(cache.image(originalURL) === first)
  }

  @MainActor func testLeastRecentlyUsedEntryEvictedAtCountBound() throws {
    let cache = NativeImageCache(maximumEntries: 2)
    let urls = try (8...10).map { dataURL(try png(width: $0, height: $0)) }
    let first = try XCTUnwrap(cache.image(urls[0]))
    let second = try XCTUnwrap(cache.image(urls[1]))
    XCTAssertTrue(cache.image(urls[0]) === first)
    _ = cache.image(urls[2])
    XCTAssertEqual(cache.count, 2)
    XCTAssertTrue(cache.image(urls[0]) === first)
    XCTAssertFalse(cache.image(urls[1]) === second)
    XCTAssertEqual(cache.decodeCount, 4)
    XCTAssertLessThanOrEqual(cache.count, cache.maximumEntries)
    XCTAssertLessThanOrEqual(cache.retainedBytes, cache.maximumBytes)
  }

  @MainActor func testByteBudgetEvictsAndLargeHistoryImagesAreNeverRetained() throws {
    let firstURL = dataURL(try png(width: 16, height: 16))
    let sizing = NativeImageCache()
    _ = sizing.image(firstURL)
    let firstCost = sizing.retainedBytes
    let secondURL = dataURL(try png(width: 16, height: 16, blue: true))
    XCTAssertNotEqual(firstURL, secondURL)
    _ = sizing.image(secondURL)
    let cache = NativeImageCache(maximumBytes: max(firstCost, sizing.retainedBytes - firstCost))
    let first = try XCTUnwrap(cache.image(firstURL))
    _ = cache.image(secondURL)
    XCTAssertLessThanOrEqual(cache.retainedBytes, cache.maximumBytes)
    XCTAssertEqual(cache.count, 1)
    XCTAssertFalse(cache.image(firstURL) === first)
    let thumbnailOnly = NativeImageCache(maximumEntryBytes: 4096)
    let largeURL = dataURL(try png(width: 64, height: 64))
    let large = try XCTUnwrap(thumbnailOnly.image(largeURL))
    XCTAssertFalse(thumbnailOnly.image(largeURL) === large)
    XCTAssertEqual(thumbnailOnly.count, 0)
    XCTAssertEqual(thumbnailOnly.retainedBytes, 0)
    let shortURLsOnly = NativeImageCache(maximumDataURLBytes: 8)
    XCTAssertNotNil(shortURLsOnly.image(firstURL))
    XCTAssertEqual(shortURLsOnly.count, 0)
  }

  @MainActor func testInvalidImmutableImageDecodeIsMemoized() {
    let cache = NativeImageCache()
    let invalid = dataURL(Data("not a PNG".utf8))
    for _ in 0..<50 { XCTAssertNil(cache.image(invalid)) }
    XCTAssertEqual(cache.decodeCount, 1)
    XCTAssertEqual(cache.count, 1)
  }

  @MainActor func testFilePathsAndFileURLsObserveReplacementInsteadOfReturningCachedImage() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "polka-native-image-cache-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file) }
    try png(width: 8, height: 8).write(to: file)
    let first = try XCTUnwrap(nativeImage(file.path))
    XCTAssertEqual(first.size.width, 8)
    try png(width: 20, height: 20, blue: true).write(to: file)
    let replaced = try XCTUnwrap(nativeImage(file.path))
    let replacedURL = try XCTUnwrap(nativeImage(file.absoluteString))
    XCTAssertFalse(replaced === first)
    XCTAssertEqual(replaced.size.width, 20)
    XCTAssertEqual(replacedURL.size.width, 20)
    XCTAssertFalse(replacedURL === replaced)
    XCTAssertNil(NativeImageCache.shared.image(file.absoluteString))
  }
}
