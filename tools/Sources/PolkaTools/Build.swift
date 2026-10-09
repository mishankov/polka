import Foundation

public struct UpdateFixture {
  public var profile: URL
  public var receipt: URL
  public var password: String
  public var mode: String
  public var feed: URL?
  public init(
    profile: URL, receipt: URL, password: String, mode: String = "updates", feed: URL? = nil
  ) {
    self.profile = profile
    self.receipt = receipt
    self.password = password
    self.mode = mode
    self.feed = feed
  }
}
public struct BuildOptions {
  public var release: Bool
  public var official: Bool
  public var prebuilt: Bool
  public var identity: String
  public var bundlePath: URL?
  public var sourceMetadata: PolkaMetadata?
  public var updateFixture: UpdateFixture?
  public var developmentSigning: DevelopmentSigning?
  public var brokerDirectory: URL?
  public var brokerSource: URL?
  public init(
    release: Bool = false, official: Bool = false, prebuilt: Bool = false, identity: String = "-",
    bundlePath: URL? = nil, sourceMetadata: PolkaMetadata? = nil,
    updateFixture: UpdateFixture? = nil, developmentSigning: DevelopmentSigning? = nil
  ) {
    self.release = release
    self.official = official
    self.prebuilt = prebuilt
    self.identity = identity
    self.bundlePath = bundlePath
    self.sourceMetadata = sourceMetadata
    self.updateFixture = updateFixture
    self.developmentSigning = developmentSigning
  }
}
public struct NativeBuildMetadata {
  public var package: PolkaMetadata
  public var official: Bool
  public var appId: String
  public var productName: String
  public var release: BundleMetadata.Release?
  public var developmentSigningFingerprint: String?
}
public struct BuildResult {
  public var bundle: URL
  public var metadata: NativeBuildMetadata
}
public enum BuildTool {
  public struct Helper {
    public let source: String
    public let output: String
    public let frameworks: [String]
    public let flags: [String]
  }
  public static let helpers = [
    Helper(
      source: "native/MediaProbe.swift", output: "build/media-probe",
      frameworks: ["CoreAudio", "CoreMediaIO", "AVFoundation"], flags: []),
    Helper(
      source: "native/ClipboardProbe.swift", output: "build/clipboard-probe",
      frameworks: ["AppKit"], flags: []),
    Helper(
      source: "native/SyncDiscovery.swift", output: "build/sync-discovery", frameworks: [],
      flags: []),
    Helper(
      source: "native/FileShelfProbe.swift", output: "build/file-shelf-probe",
      frameworks: ["AppKit"], flags: []),
    Helper(
      source: "native/ImageText.swift", output: "build/image-text",
      frameworks: ["Vision", "ImageIO", "CoreImage"],
      flags: [
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker",
        "native/ImageTextInfo.plist",
      ]),
  ]
  public static func buildHelpers(context: ToolContext = ToolContext()) throws {
    try ToolFiles.directory(context.root.appendingPathComponent("build"))
    let jobs =
      Int(context.environment["POLKA_SWIFT_BUILD_JOBS"] ?? "")
      ?? ProcessInfo.processInfo.activeProcessorCount
    try Command.parallel(
      helpers.map { helper in
        {
          try Command.run(
            "/usr/bin/xcrun",
            ["swiftc", "-O", helper.source, "-o", helper.output] + helper.flags
              + helper.frameworks.flatMap { ["-framework", $0] },
            environment: SigningTool.publicEnvironment(context.environment), directory: context.root
          )
        }
      }, limit: jobs)
  }
  public static func products(configuration: String, context: ToolContext = ToolContext()) throws
    -> URL
  {
    let value = try Command.capture(
      "/usr/bin/xcrun",
      ["swift", "build"] + context.swiftBuildArguments
        + ["--package-path", "native-app", "-c", configuration, "--show-bin-path"],
      environment: SigningTool.publicEnvironment(context.environment), directory: context.root
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(fileURLWithPath: value)
  }
  public static func assertPrepared(
    configuration: String = "release", productsPath: URL? = nil, helperPaths: [URL]? = nil,
    context: ToolContext = ToolContext()
  ) throws {
    let products = try productsPath ?? self.products(configuration: configuration, context: context)
    let bundle = products.appendingPathComponent("PolkaNative_PolkaCore.bundle")
    let structuredResource = bundle.appendingPathComponent("Contents/Resources/emoji-data.json")
    let resource =
      ToolFiles.manager.fileExists(atPath: structuredResource.path)
      ? structuredResource : bundle.appendingPathComponent("emoji-data.json")
    let required =
      [
        products.appendingPathComponent("PolkaNative"),
        products.appendingPathComponent("Sparkle.framework/Sparkle"),
        resource,
      ] + (helperPaths ?? helpers.map { context.root.appendingPathComponent($0.output) })
    for path in required where !ToolFiles.manager.fileExists(atPath: path.path) {
      throw ToolError(
        "Missing prepared native output \(path.path). Run ./polka build first (\(configuration)).")
    }
  }
  public static func metadata(
    source: PolkaMetadata, environment: [String: String], official: Bool = false
  ) throws -> NativeBuildMetadata {
    let resolved = try ReleaseTool.resolved(source, environment: environment).metadata
    if official, environment["POLKA_SIGNING_KEYCHAIN"]?.isEmpty != false {
      throw ToolError("Official native builds require an isolated POLKA_SIGNING_KEYCHAIN.")
    }
    return NativeBuildMetadata(
      package: resolved, official: official,
      appId: official ? resolved.build.appId : resolved.build.appId + ".native-development",
      productName: official ? resolved.build.productName : resolved.build.productName + " Native",
      release: official
        ? try ReleaseTool.configuration(metadata: resolved, environment: environment).release : nil)
  }
  public static func infoPlist(_ metadata: NativeBuildMetadata, checkout: URL) -> String {
    let xml = ToolFiles.xml
    let pkg = metadata.package
    let updates: String
    if let release = metadata.release {
      updates = """
        <key>SUFeedURL</key><string>\(xml(release.feedUrl))</string>
        <key>SUPublicEDKey</key><string>\(xml(release.publicKey))</string>
        <key>SUEnableAutomaticChecks</key><true/>
        <key>SUAutomaticallyUpdate</key><false/>
        <key>SUAllowsAutomaticUpdates</key><false/>
        <key>SUEnableSystemProfiling</key><false/>
        <key>SUVerifyUpdateBeforeExtraction</key><true/>
        <key>SUScheduledCheckInterval</key><integer>21600</integer>
        """
    } else {
      updates =
        "<key>PolkaDevelopment</key><true/><key>PolkaCheckout</key><string>\(xml(checkout.path))</string>"
        + (metadata.developmentSigningFingerprint.map {
          "<key>PolkaDevelopmentSigningFingerprint</key><string>\(xml($0))</string>"
        } ?? "")
    }
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>\(xml(metadata.appId))</string>
      <key>CFBundleName</key><string>\(xml(metadata.productName))</string>
      <key>CFBundleDisplayName</key><string>\(xml(metadata.productName))</string>
      <key>CFBundleExecutable</key><string>PolkaNative</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>\(xml(pkg.version))</string>
      <key>CFBundleVersion</key><string>\(xml(pkg.version))</string>
      <key>CFBundleIconFile</key><string>Icon.icns</string>
      <key>CFBundleIconName</key><string>Icon</string>
      <key>LSMinimumSystemVersion</key><string>\(xml(pkg.build.mac.minimumSystemVersion))</string>
      <key>LSUIElement</key><true/>
      <key>NSHighResolutionCapable</key><true/>
      <key>NSLocalNetworkUsageDescription</key><string>Полка синхронизирует историю буфера обмена между связанными Mac в вашей локальной сети.</string>
      <key>NSBonjourServices</key><array><string>_polkaclip._tcp</string></array>
      \(updates)
      </dict></plist>
      """
  }
  public static func assertRelativeBundleLinks(_ bundle: URL) throws {
    func visit(_ directory: URL) throws {
      for path in try ToolFiles.manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      {
        guard let info = try ToolFiles.metadata(path) else { continue }
        if info.st_mode & 0o170000 == 0o120000 {
          let target = try ToolFiles.manager.destinationOfSymbolicLink(atPath: path.path)
          let resolved = path.deletingLastPathComponent().appendingPathComponent(target)
            .standardizedFileURL.path
          guard !target.hasPrefix("/"), resolved.hasPrefix(bundle.standardizedFileURL.path + "/")
          else {
            throw ToolError(
              "Non-relocatable bundle symlink: \(ToolFiles.relative(path, to: bundle))")
          }
        } else if info.st_mode & 0o170000 == 0o040000 {
          try visit(path)
        }
      }
    }
    try visit(bundle)
  }
  static func copyLicenses(resources: URL, context: ToolContext) throws {
    let destination = resources.appendingPathComponent("licenses")
    try ToolFiles.directory(destination.appendingPathComponent("Polka"))
    for (source, name) in [
      ("LICENSE", "LICENSE"), ("docs/unicode-license.txt", "unicode-license.txt"),
    ] {
      try ToolFiles.manager.copyItem(
        at: context.root.appendingPathComponent(source),
        to: destination.appendingPathComponent("Polka/" + name))
    }
    let resolved =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: context.root.appendingPathComponent("native-app/Package.resolved")))
      as! [String: Any]
    guard let pins = resolved["pins"] as? [[String: Any]] else {
      throw ToolError("Invalid dependency pins.")
    }
    let checkouts = context.root.appendingPathComponent("native-app/.build/checkouts")
    let names = try ToolFiles.manager.contentsOfDirectory(atPath: checkouts.path)
    for pin in pins {
      guard let identity = pin["identity"] as? String,
        let name = names.first(where: { $0.lowercased() == identity.lowercased() })
      else { throw ToolError("Missing licensing checkout.") }
      let source = checkouts.appendingPathComponent(name)
      let output = destination.appendingPathComponent(identity)
      let notices = try ToolFiles.manager.contentsOfDirectory(atPath: source.path).filter {
        ToolFiles.matches($0, #"(?i)^(LICENSE|NOTICE|COPYING|COPYRIGHT)(?:[._-].*)?$"#)
      }
      guard notices.contains(where: { ToolFiles.matches($0, #"(?i)^(LICENSE|COPYING)"#) }) else {
        throw ToolError("Dependency license is missing: \(identity).")
      }
      try ToolFiles.directory(output)
      for notice in notices {
        try ToolFiles.manager.copyItem(
          at: source.appendingPathComponent(notice), to: output.appendingPathComponent(notice))
      }
    }
    try ToolFiles.manager.copyItem(
      at: checkouts.appendingPathComponent("swift-nio/Sources/CNIOLLHTTP/LICENSE"),
      to: destination.appendingPathComponent("swift-nio/LICENSE.llhttp"))
    for (component, path) in [
      ("swift-crypto", "Sources/CCryptoBoringSSL/hash.txt"),
      ("swift-nio-ssl", "Sources/CNIOBoringSSL/hash.txt"),
    ] {
      let provenance = try String(
        contentsOf: checkouts.appendingPathComponent(component + "/" + path), encoding: .utf8)
      let expression = try NSRegularExpression(pattern: "at revision ([0-9a-f]{40})")
      guard
        let match = expression.firstMatch(
          in: provenance, range: NSRange(provenance.startIndex..., in: provenance)),
        let range = Range(match.range(at: 1), in: provenance)
      else { throw ToolError("Missing BoringSSL provenance: \(component).") }
      let revision = String(provenance[range])
      try ToolFiles.manager.copyItem(
        at: context.root.appendingPathComponent(
          "native-app/Licenses/boringssl-" + revision + ".txt"),
        to: destination.appendingPathComponent(component + "/LICENSE.boringssl.txt"))
      try ToolFiles.write(
        provenance
          + "License: https://raw.githubusercontent.com/google/boringssl/\(revision)/LICENSE\n",
        to: destination.appendingPathComponent(component + "/BORINGSSL-SOURCE.txt"), mode: 0o644)
    }
    try Files.writeJSON(pins, to: destination.appendingPathComponent("dependencies.json"))
  }
  static func compileIcon(resources: URL, metadata: PolkaMetadata, context: ToolContext) throws {
    let scratch = try ToolFiles.temporary("polka-native-icon-")
    defer { try? ToolFiles.remove(scratch) }
    let input = scratch.appendingPathComponent("Icon.icon")
    let output = scratch.appendingPathComponent("out")
    try ToolFiles.manager.copyItem(
      at: context.root.appendingPathComponent(metadata.build.mac.icon), to: input)
    try ToolFiles.directory(output)
    try Command.run(
      "/usr/bin/xcrun",
      [
        "actool", input.path, "--compile", output.path, "--output-format", "human-readable-text",
        "--output-partial-info-plist", output.appendingPathComponent("info.plist").path,
        "--app-icon", "Icon", "--include-all-app-icons", "--enable-on-demand-resources", "NO",
        "--development-region", "en", "--target-device", "mac", "--minimum-deployment-target",
        metadata.build.mac.minimumSystemVersion, "--platform", "macosx",
      ], environment: SigningTool.publicEnvironment(context.environment), directory: context.root)
    for file in ["Assets.car", "Icon.icns"] {
      try ToolFiles.manager.copyItem(
        at: output.appendingPathComponent(file), to: resources.appendingPathComponent(file))
    }
  }
  public static func build(
    options: BuildOptions = BuildOptions(), context: ToolContext = ToolContext()
  ) throws -> BuildResult {
    let source = try options.sourceMetadata ?? PolkaMetadata.load(root: context.root)
    var metadata = try self.metadata(
      source: source, environment: context.environment, official: options.official)
    if let signing = options.developmentSigning {
      guard !options.official else {
        throw ToolError("Development signing cannot sign official builds.")
      }
      metadata.developmentSigningFingerprint = try SigningTool.fingerprint([
        "POLKA_SIGNING_CERT_SHA1": signing.fingerprint
      ])
      guard
        options.identity == "-"
          || options.identity.uppercased() == metadata.developmentSigningFingerprint
      else { throw ToolError("Refusing to change the development signing identity.") }
    }
    if options.official, options.identity != "-",
      options.identity.uppercased() != (try SigningTool.fingerprint(context.environment))
    {
      throw ToolError("Refusing to rotate the pinned release signing identity.")
    }
    let configuration = options.release ? "release" : "debug"
    if options.prebuilt {
      try assertPrepared(configuration: configuration, context: context)
    } else {
      try Command.run(
        "/usr/bin/xcrun",
        ["swift", "build"] + context.swiftBuildArguments
          + ["--package-path", "native-app", "-c", configuration, "--product", "PolkaNative"],
        environment: SigningTool.publicEnvironment(context.environment), directory: context.root)
      try buildHelpers(context: context)
    }
    let products = try self.products(configuration: configuration, context: context)
    let bundle =
      options.bundlePath
      ?? context.root.appendingPathComponent(
        options.official
          ? "release/native/\(metadata.productName).app"
          : "release/\(options.release ? "native-build" : "native-dev")/\(metadata.productName).app"
      )
    guard bundle.pathExtension == "app" else {
      throw ToolError("Native bundle output must be an .app directory.")
    }
    try ToolFiles.remove(bundle)
    let contents = bundle.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    let frameworks = contents.appendingPathComponent("Frameworks")
    let binaries = contents.appendingPathComponent("MacOS")
    for directory in [resources, frameworks, binaries] {
      try ToolFiles.directory(directory, mode: 0o755)
    }
    let executable = binaries.appendingPathComponent("PolkaNative")
    try ToolFiles.manager.copyItem(
      at: products.appendingPathComponent("PolkaNative"), to: executable)
    for entry in try ToolFiles.manager.contentsOfDirectory(atPath: products.path)
    where entry.hasSuffix(".bundle") {
      try ToolFiles.manager.copyItem(
        at: products.appendingPathComponent(entry), to: resources.appendingPathComponent(entry))
    }
    try ToolFiles.manager.copyItem(
      at: products.appendingPathComponent("Sparkle.framework"),
      to: frameworks.appendingPathComponent("Sparkle.framework"))
    let load = try Command.capture(
      "/usr/bin/otool", ["-l", executable.path],
      environment: SigningTool.publicEnvironment(context.environment))
    let expression = try NSRegularExpression(
      pattern: #"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset \d+\)"#)
    let rpaths = expression.matches(in: load, range: NSRange(load.startIndex..., in: load))
      .compactMap { Range($0.range(at: 1), in: load).map { String(load[$0]) } }
    for path in rpaths where path.contains("/native-app/.build/") {
      _ = try Command.capture(
        "/usr/bin/install_name_tool", ["-delete_rpath", path, executable.path],
        environment: SigningTool.publicEnvironment(context.environment))
    }
    if !rpaths.contains("@executable_path/../Frameworks") {
      _ = try Command.capture(
        "/usr/bin/install_name_tool",
        ["-add_rpath", "@executable_path/../Frameworks", executable.path],
        environment: SigningTool.publicEnvironment(context.environment))
    }
    for helper in helpers {
      try ToolFiles.manager.copyItem(
        at: context.root.appendingPathComponent(helper.output),
        to: resources.appendingPathComponent(URL(fileURLWithPath: helper.output).lastPathComponent))
    }
    if let signing = options.developmentSigning {
      let broker = try DevelopmentTool.prepareBroker(
        signing, directory: options.brokerDirectory ?? DevelopmentTool.brokerDirectory,
        appId: metadata.appId, sourcePath: options.brokerSource, context: context)
      try ToolFiles.manager.copyItem(
        at: broker.path, to: resources.appendingPathComponent("polka-keychain-broker"))
    }
    for (source, name) in [
      ("native-app/Resources/polkaTemplate.png", "polkaTemplate.png"),
      ("docs/unicode-license.txt", "unicode-license.txt"),
    ] {
      try ToolFiles.manager.copyItem(
        at: context.root.appendingPathComponent(source), to: resources.appendingPathComponent(name))
    }
    try copyLicenses(resources: resources, context: context)
    try compileIcon(resources: resources, metadata: metadata.package, context: context)
    var plist = infoPlist(metadata, checkout: context.root)
    if let fixture = options.updateFixture {
      guard metadata.appId.hasPrefix("app.polka.native-update-test."), !fixture.password.isEmpty
      else { throw ToolError("Update bootstraps require a disposable update fixture identity.") }
      if let feed = fixture.feed {
        guard feed.scheme == "http",
          ["127.0.0.1", "localhost", "::1", "[::1]"].contains(feed.host ?? "")
        else { throw ToolError("Update fixture feeds must stay on localhost.") }
      }
      let content =
        "<key>PolkaUpdateFixture</key><dict><key>profile</key><string>\(ToolFiles.xml(fixture.profile.path))</string><key>receipt</key><string>\(ToolFiles.xml(fixture.receipt.path))</string><key>password</key><string>\(ToolFiles.xml(fixture.password))</string>"
        + (fixture.mode == "updates" ? "<key>mode</key><string>updates</string>" : "") + "</dict>"
        + (fixture.feed != nil
          ? "<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>"
          : "")
      plist = plist.replacingOccurrences(of: "</dict></plist>", with: content + "</dict></plist>")
      if let feed = fixture.feed, let original = metadata.release?.feedUrl {
        plist = plist.replacingOccurrences(
          of: "<key>SUFeedURL</key><string>\(ToolFiles.xml(original))</string>",
          with: "<key>SUFeedURL</key><string>\(ToolFiles.xml(feed.absoluteString))</string>")
      }
    }
    try ToolFiles.write(plist, to: contents.appendingPathComponent("Info.plist"), mode: 0o644)
    try assertRelativeBundleLinks(bundle)
    if options.official {
      try SigningTool.sign(
        bundle: bundle, appId: metadata.appId,
        entitlements: context.root.appendingPathComponent("build/entitlements.mac.plist"),
        environment: context.environment)
    } else {
      let identity = metadata.developmentSigningFingerprint ?? options.identity
      let extra =
        options.developmentSigning.map { ["--keychain", $0.keychain.path, "--timestamp=none"] }
        ?? []
      for helper in helpers {
        let name = URL(fileURLWithPath: helper.output).lastPathComponent
        let id =
          (options.developmentSigning != nil ? metadata.appId : metadata.package.build.appId) + "."
          + name
        _ = try SigningTool.codesign(
          ["--force", "--sign", identity] + extra + ["--identifier", id]
            + (options.developmentSigning != nil
              ? ["--requirements", "=designated => " + SigningTool.requirement(id, identity)] : [])
            + [resources.appendingPathComponent(name).path], environment: context.environment)
      }
      _ = try SigningTool.codesign(
        ["--force", "--sign", identity] + extra
          + (options.developmentSigning != nil
            ? [
              "--requirements",
              "=designated => " + SigningTool.requirement(metadata.appId, identity),
            ] : []) + [bundle.path], environment: context.environment)
      if options.developmentSigning != nil {
        _ = try SigningTool.verify(bundle: bundle, appId: metadata.appId, fingerprint: identity)
      }
    }
    _ = try SigningTool.codesign(
      ["--verify", "--deep", "--strict", bundle.path], environment: context.environment)
    return BuildResult(bundle: bundle, metadata: metadata)
  }
}
