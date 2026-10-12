import Foundation

public struct PackageOptions {
  public var official: Bool
  public var prebuilt: Bool
  public var directoryOnly: Bool
  public var debug: Bool
  public var desktop: Bool
  public init(
    official: Bool = false, prebuilt: Bool = false, directoryOnly: Bool = false,
    debug: Bool = false, desktop: Bool = false
  ) {
    self.official = official
    self.prebuilt = prebuilt
    self.directoryOnly = directoryOnly
    self.debug = debug
    self.desktop = desktop
  }
  public var buildOptions: BuildOptions {
    BuildOptions(release: !debug, official: official, prebuilt: prebuilt)
  }
  public func validate() throws {
    if directoryOnly && desktop {
      throw ToolError("Desktop verification requires a relocated ZIP; remove directory-only mode.")
    }
  }
}
public struct PackageResult {
  public var build: BuildResult
  public var output: URL
  public var artifacts: [URL]
}
public enum PackageTool {
  /// DiskImages can briefly return EBUSY on hosted macOS. Retry only that
  /// creation failure; invalid inputs and failed verification remain fatal.
  static func createDiskImage(
    stage: URL, image: URL, volumeName: String, environment: [String: String],
    execute: (String, [String], [String: String]) throws -> Command.Result = {
      try Command.execute($0, $1, environment: $2)
    },
    wait: (TimeInterval, [String: String]) throws -> Void = {
      try Command.run("/bin/sleep", [String($0)], environment: $1)
    }
  ) throws {
    var verified = false
    defer { if !verified { try? ToolFiles.remove(image) } }
    var environment = environment
    environment["LC_ALL"] = "C"
    func run(_ arguments: [String]) throws -> Command.Result {
      let result = try execute("/usr/bin/hdiutil", arguments, environment)
      FileHandle.standardOutput.write(result.stdout)
      FileHandle.standardError.write(result.stderr)
      return result
    }
    for attempt in 1...3 {
      try ToolFiles.remove(image)
      let result = try run([
        "create", "-ov", "-volname", volumeName, "-srcfolder", stage.path,
        "-format", "UDZO", image.path,
      ])
      if result.status == 0 { break }
      guard attempt < 3, result.error.contains("create failed - Resource busy") else {
        throw ToolError("DMG creation failed (\(result.status)).", exitCode: result.status)
      }
      try ToolFiles.remove(image)
      let delay = TimeInterval(attempt * 2)
      FileHandle.standardError.write(
        Data("DMG creation is busy; retrying in \(Int(delay))s (attempt \(attempt + 1)/3).\n".utf8))
      try wait(delay, environment)
    }
    let result = try run(["verify", image.path])
    guard result.status == 0 else {
      throw ToolError("DMG verification failed (\(result.status)).", exitCode: result.status)
    }
    verified = true
  }

  public static func package(
    options: PackageOptions = PackageOptions(), context: ToolContext = ToolContext()
  ) throws -> PackageResult {
    try options.validate()
    guard DevelopmentTool.architecture == "arm64" else {
      throw ToolError("Build native packages on an Apple silicon Mac.")
    }
    if options.official && !options.directoryOnly
      && context.environment["SPARKLE_PRIVATE_KEY"]?.isEmpty != false
    {
      throw ToolError("SPARKLE_PRIVATE_KEY is required to sign the native update ZIP.")
    }
    func work(_ environment: [String: String]) throws -> PackageResult {
      let publicContext = ToolContext(
        root: context.root, environment: SigningTool.publicEnvironment(environment))
      let built = try BuildTool.build(options: options.buildOptions, context: publicContext)
      let output = context.root.appendingPathComponent(
        options.official ? "release" : "release/native-dev")
      if options.directoryOnly { return PackageResult(build: built, output: output, artifacts: []) }
      var metadata = built.metadata.package
      let names = try ReleaseMetadata.artifactNames(metadata: metadata)
      guard let zip = names.first(where: { $0.hasSuffix(".zip") }),
        let dmg = names.first(where: { $0.hasSuffix(".dmg") })
      else { throw ToolError("Missing native archive names.") }
      let archive = output.appendingPathComponent(zip)
      let image = output.appendingPathComponent(dmg)
      try ToolFiles.directory(output)
      try ToolFiles.remove(archive)
      try Command.run(
        "/usr/bin/ditto",
        ["-c", "-k", "--sequesterRsrc", "--keepParent", built.bundle.path, archive.path],
        environment: publicContext.environment)
      func createImage() throws {
        let stage = try ToolFiles.temporary("polka-native-dmg-")
        defer { try? ToolFiles.remove(stage) }
        try ToolFiles.manager.copyItem(
          at: built.bundle, to: stage.appendingPathComponent(built.metadata.productName + ".app"))
        try ToolFiles.manager.createSymbolicLink(
          at: stage.appendingPathComponent("Applications"),
          withDestinationURL: URL(fileURLWithPath: "/Applications"))
        try createDiskImage(
          stage: stage, image: image, volumeName: built.metadata.productName,
          environment: publicContext.environment)
        try ToolFiles.remove(stage)
      }
      func verifyArchive() throws {
        let relocated = try ToolFiles.temporary("polka-native-zip-")
        defer { try? ToolFiles.remove(relocated) }
        try Command.run(
          "/usr/bin/ditto", ["-x", "-k", archive.path, relocated.path],
          environment: publicContext.environment)
        let app = relocated.appendingPathComponent(built.metadata.productName + ".app")
        try BuildTool.assertRelativeBundleLinks(app)
        _ = try SigningTool.codesign(
          ["--verify", "--deep", "--strict", app.path], environment: publicContext.environment)
        if options.desktop { try Desktop.smokeSync(app: app, context: publicContext) }
        try ToolFiles.remove(relocated)
      }
      // Both operations only read the signed bundle/ZIP. The DMG can be built
      // and verified while the relocated ZIP runs its desktop checks.
      try Command.parallel([createImage, verifyArchive], limit: 2)
      if options.official {
        metadata.releaseNotes = try ReleaseTool.notes(metadata: metadata, context: context)
          .bilingual
        guard let privateKey = context.environment["SPARKLE_PRIVATE_KEY"],
          let release = built.metadata.release
        else { throw ToolError("Missing native archive signing metadata.") }
        let signed = try Command.execute(
          context.root.appendingPathComponent(
            "native-app/.build/artifacts/sparkle/Sparkle/bin/sign_update"
          ).path, ["--ed-key-file", "-", "-p", archive.path],
          environment: publicContext.environment, input: Data(privateKey.utf8))
        let signature = signed.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard signed.status == 0, ToolFiles.matches(signature, "^[A-Za-z0-9+/]{86}==$"),
          let info = try ToolFiles.metadata(archive)
        else {
          throw ToolError("Native Sparkle archive signing failed. Check the release signing key.")
        }
        let tag = try ReleaseTool.resolved(metadata, environment: context.environment).tag
        try ToolFiles.write(
          ReleaseMetadata.appcast(
            metadata: metadata, repository: release.repository, signature: signature,
            size: Int(info.st_size), tag: tag), to: output.appendingPathComponent("appcast.xml"),
          mode: 0o644)
        _ = try ReleaseMetadata.verify(
          metadata: metadata, directory: output, repository: release.repository,
          publicKey: release.publicKey, tag: tag)
      }
      return PackageResult(
        build: built, output: output,
        artifacts: names.filter { options.official || $0 != "appcast.xml" }.map {
          output.appendingPathComponent($0)
        })
    }
    if options.official, context.environment["POLKA_SIGNING_KEYCHAIN"]?.isEmpty != false {
      return try SigningTool.withKeychain(context.environment, work: work)
    }
    return try work(context.environment)
  }
}
