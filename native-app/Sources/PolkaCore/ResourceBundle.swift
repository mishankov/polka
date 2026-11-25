import Foundation

/// Resolves SwiftPM target resource bundles inside a packaged macOS `.app`
/// (`Contents/Resources/<name>.bundle`) before falling back to `Bundle.module`.
/// SwiftPM's `--build-system native` accessor checks only `Bundle.main.bundleURL`
/// and the compile-time `.build` path, so evaluating `Bundle.module` directly
/// inside a packaged `.app` crashes on machines without that build directory.
public enum PolkaResourceBundle {
  public static func packagedBundle(
    named bundleName: String, in resourcesURL: URL? = Bundle.main.resourceURL
  ) -> Bundle? {
    guard let resourcesURL else { return nil }
    return Bundle(url: resourcesURL.appendingPathComponent(bundleName + ".bundle"))
  }

  public static func resolve(
    named bundleName: String,
    in resourcesURL: URL? = Bundle.main.resourceURL,
    fallback: () -> Bundle
  ) -> Bundle {
    packagedBundle(named: bundleName, in: resourcesURL) ?? fallback()
  }
}
