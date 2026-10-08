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
      let stage = try ToolFiles.temporary("polka-native-dmg-")
      do {
        try ToolFiles.manager.copyItem(
          at: built.bundle, to: stage.appendingPathComponent(built.metadata.productName + ".app"))
        try ToolFiles.manager.createSymbolicLink(
          at: stage.appendingPathComponent("Applications"),
          withDestinationURL: URL(fileURLWithPath: "/Applications"))
        try Command.run(
          "/usr/bin/hdiutil",
          [
            "create", "-ov", "-volname", built.metadata.productName, "-srcfolder", stage.path,
            "-format", "UDZO", image.path,
          ], environment: publicContext.environment)
        try Command.run(
          "/usr/bin/hdiutil", ["verify", image.path], environment: publicContext.environment)
        try ToolFiles.remove(stage)
      } catch {
        try? ToolFiles.remove(stage)
        throw error
      }
      let relocated = try ToolFiles.temporary("polka-native-zip-")
      do {
        try Command.run(
          "/usr/bin/ditto", ["-x", "-k", archive.path, relocated.path],
          environment: publicContext.environment)
        let app = relocated.appendingPathComponent(built.metadata.productName + ".app")
        try BuildTool.assertRelativeBundleLinks(app)
        _ = try SigningTool.codesign(
          ["--verify", "--deep", "--strict", app.path], environment: publicContext.environment)
        if options.desktop { try Desktop.smokeSync(app: app, context: publicContext) }
        try ToolFiles.remove(relocated)
      } catch {
        try? ToolFiles.remove(relocated)
        throw error
      }
      if options.official {
        metadata.releaseNotes = try ReleaseNotes.read(version: metadata.version, root: context.root)
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
