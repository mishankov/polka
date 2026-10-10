import Foundation

/// Catalog IDs, rather than translated names or positions, survive upgrades.
/// Missing IDs are enabled, including apps added by a later version.
public struct BuiltinAppAvailability: Equatable, Sendable {
  public static let settingsKey = "builtinApps.enabled"
  public var overrides: [String: Bool]
  public init(overrides: [String: Bool] = [:]) { self.overrides = overrides }
  public func isEnabled(_ id: String) -> Bool { overrides[id] ?? true }
  public func allows(destination: String) -> Bool {
    if ["apps", "settings", "about", "toggle"].contains(destination) { return true }
    return isEnabled("builtin:" + destination)
  }
  public func catalog(_ apps: [NativeLauncherApp]) -> [NativeLauncherApp] {
    apps.filter { $0.kind != .builtin || isEnabled($0.id) }
  }
}
