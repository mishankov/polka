import AppKit
import CryptoKit
import PolkaCore

@MainActor final class InstalledApps {
  private struct Entry {
    var path: String
    var bundleID: String?
    var app: NativeLauncherApp
    var signature: String
  }
  private var entries: [String: Entry] = [:]
  private var refreshing = false
  private(set) var apps: [NativeLauncherApp] = []
  static func validate(_ path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    guard url.resolvingSymlinksInPath().path == path,
      let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        as? [String: Any],
      info["CFBundlePackageType"] as? String == "APPL"
    else { throw PolkaCoreError.invalid("Это не пользовательское приложение") }
    let background = String(describing: info["LSBackgroundOnly"] ?? "").lowercased()
    guard !["1", "true", "yes"].contains(background),
      let executable = info["CFBundleExecutable"] as? String,
      !executable.isEmpty, ![".", ".."].contains(executable), !executable.contains("/")
    else { throw PolkaCoreError.invalid("Исполняемый файл приложения не найден") }
    let target = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
      .path
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target, isDirectory: &directory),
      !directory.boolValue, FileManager.default.isExecutableFile(atPath: target)
    else { throw PolkaCoreError.invalid("Исполняемый файл приложения не найден") }
    return info
  }
  static func displayName(
    at url: URL, info: [String: Any], preferredLanguages: [String]
  ) -> String {
    func name(in values: [String: Any]?) -> String? {
      for key in ["CFBundleDisplayName", "CFBundleName"] {
        if let value = (values?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
        {
          return value
        }
      }
      return nil
    }
    if let bundle = Bundle(url: url), let resource = bundle.resourceURL {
      let table =
        NSDictionary(contentsOf: resource.appendingPathComponent("InfoPlist.loctable"))
        as? [String: [String: Any]] ?? [:]
      // Other bundles' preferredLocalizations/localizedInfoDictionary can inherit
      // Polka's language. Resolve the installed app against the user's preferences
      // explicitly, including apps whose translations only exist in a loctable.
      let development = bundle.developmentLocalization ?? "en"
      let localizations = Set(
        bundle.localizations + [development] + table.keys.filter { name(in: table[$0]) != nil }
      )
      .subtracting(["Base", "none"])
      for language in Bundle.preferredLocalizations(
        from: [development] + localizations.subtracting([development]).sorted(),
        forPreferences: preferredLanguages)
      {
        if let localized = name(in: table[language]) { return localized }
        let strings = resource.appendingPathComponent(language + ".lproj/InfoPlist.strings")
        if let localized = name(in: NSDictionary(contentsOf: strings) as? [String: Any]) {
          return localized
        }
      }
    }
    return name(in: info) ?? url.deletingPathExtension().lastPathComponent
  }
  func refresh(
    roots suppliedRoots: [String]? = nil, extraPaths: [String]? = nil,
    preferredLanguages: [String] = Locale.preferredLanguages
  ) async throws {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    var extra =
      extraPaths ?? (suppliedRoots == nil ? ["/System/Library/CoreServices/Finder.app"] : [])
    if extraPaths == nil, suppliedRoots == nil,
      let data = try? await NativeCommand.run(
        URL(fileURLWithPath: "/usr/bin/mdfind"),
        arguments: ["-0", "kMDItemContentType == \"com.apple.application-bundle\""], timeout: 4,
        limit: 4 * 1024 * 1024)
    {
      extra += String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init).filter
      {
        !$0.hasPrefix("/Volumes/") && !$0.contains("/Library/")
          && !$0.split(separator: "/").contains(where: { $0.hasPrefix(".") })
      }
    }
    let paths = await Task.detached(priority: .utility) { () -> [String] in
      let roots =
        suppliedRoots ?? [
          "/Applications", NSHomeDirectory() + "/Applications", "/System/Applications",
          "/System/Library/CoreServices/Applications",
        ]
      var visited = Set<String>()
      var found = Set<String>()
      func visit(_ path: String, depth: Int) {
        guard depth <= 8, visited.count < 10_000, path.hasPrefix("/"),
          !path.lowercased().contains(".app/")
        else { return }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard visited.insert(url.path).inserted,
          let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
          values.isDirectory == true
        else { return }
        if url.pathExtension.lowercased() == "app" {
          found.insert(url.path)
          return
        }
        for entry
          in (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        { visit(entry.path, depth: depth + 1) }
      }
      for root in roots + extra { visit(root, depth: 0) }
      return Array(found)
    }.value
    var next: [String: Entry] = [:]
    var sliceStarted = ProcessInfo.processInfo.systemUptime
    for path in paths {
      // Icon rendering stays on AppKit's actor. Yield a short catalog slice so
      // discovery cannot monopolize scrolling/keyboard input at startup.
      if ProcessInfo.processInfo.systemUptime - sliceStarted >= 0.008 {
        try await Task.sleep(nanoseconds: 1_000_000)
        sliceStarted = ProcessInfo.processInfo.systemUptime
      }
      try Task.checkCancellation()
      let url = URL(fileURLWithPath: path)
      guard
        let attributes = try? FileManager.default.attributesOfItem(
          atPath: url.appendingPathComponent("Contents/Info.plist").path)
      else { continue }
      let signature = "\(attributes[.modificationDate] ?? ""):\(attributes[.size] ?? "")"
      let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        .prefix(32)
      let id = "mac:\(hash)"
      guard let info = try? Self.validate(path) else { continue }
      let name = Self.displayName(at: url, info: info, preferredLanguages: preferredLanguages)
      let icon =
        entries[id]?.signature == signature ? entries[id]!.app.icon : Self.iconDataURL(path)
      let terms = [
        url.deletingPathExtension().lastPathComponent, info["CFBundleDisplayName"] as? String,
        info["CFBundleName"] as? String, info["CFBundleIdentifier"] as? String,
      ].compactMap { $0 }
      next[id] = Entry(
        path: path, bundleID: info["CFBundleIdentifier"] as? String,
        app: NativeLauncherApp(
          id: id, name: name, icon: icon,
          description: "macOS · \(url.deletingLastPathComponent().path)", searchTerms: terms),
        signature: signature)
    }
    entries = next
    apps = next.values.map(\.app).sorted { $0.id < $1.id }
  }
  static func iconDataURL(_ path: String) -> String {
    let source = NSWorkspace.shared.icon(forFile: path)
    let icon = NSImage(size: NSSize(width: 32, height: 32))
    icon.lockFocus()
    source.draw(
      in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
    icon.unlockFocus()
    guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return "" }
    return "data:image/png;base64," + png.base64EncodedString()
  }
  func open(_ id: String) async throws {
    guard let entry = entries[id] else {
      throw PolkaCoreError.invalid(
        "Приложение не найдено. Откройте быстрый запуск снова, чтобы обновить список.")
    }
    let info = try Self.validate(entry.path)
    guard entry.bundleID == nil || info["CFBundleIdentifier"] as? String == entry.bundleID else {
      throw PolkaCoreError.invalid("Приложение изменилось")
    }
    _ = try await NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: entry.path), configuration: NSWorkspace.OpenConfiguration())
  }
}
