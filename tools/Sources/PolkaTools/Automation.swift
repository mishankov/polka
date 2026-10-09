import Darwin
import Foundation

public struct ToolRequest {
  public let command: String
  public let arguments: [String]
  public let flags: Set<String>
  public let positionals: [String]
  public init(_ arguments: [String]) throws {
    command = arguments.first ?? "help"
    self.arguments = Array(arguments.dropFirst())
    let allowed: [String: Set<String>] = [
      "help": [], "setup": [], "dev": ["release", "prebuilt"],
      "build": ["debug", "release", "official", "prebuilt", "development-signing"],
      "build-helpers": [], "test": [], "coverage": [], "search-test": [],
      "desktop": ["prebuilt", "release", "external"],
      "verify": ["prebuilt", "release", "no-desktop", "no-updates", "no-tools", "external-drops"],
      "package": ["prebuilt", "desktop", "official", "debug", "dir"],
      "release": ["prebuilt", "desktop", "publish"], "release-verify": [],
      "release-notes": ["version"], "release-prepare": [], "signing-certificate": [],
      "emoji-data": [], "format": ["check"],
    ]
    guard let options = allowed[command] else {
      throw ToolError("Unknown command: \(command). Run ./polka help.")
    }
    flags = Set(self.arguments.filter { $0.hasPrefix("--") }.map { String($0.dropFirst(2)) })
    positionals = self.arguments.filter { !$0.hasPrefix("--") }
    guard flags.subtracting(options.union(["help"])).isEmpty else {
      throw ToolError("Unknown option for \(command). Run ./polka help.")
    }
    if flags.contains("help") { return }
    let permitted = ["test", "desktop", "release-notes", "signing-certificate"]
    guard permitted.contains(command) || positionals.isEmpty else {
      throw ToolError("Unexpected argument for \(command).")
    }
    if command == "test",
      positionals.count > 1 || !["all", "app", "tools"].contains(positionals.first ?? "all")
    {
      throw ToolError("Usage: ./polka test [all|app|tools]")
    }
    if command == "desktop",
      positionals.count > 1
        || !["core", "all", "updates", "files"].contains(positionals.first ?? "core")
    {
      throw ToolError("Usage: ./polka desktop [core|all|updates|files]")
    }
    if flags.contains("debug") && flags.contains("release") {
      throw ToolError("Choose --debug or --release.")
    }
    if flags.contains("official") && flags.contains("development-signing") {
      throw ToolError("Choose official or development signing.")
    }
    if flags.contains("no-desktop") && flags.contains("external-drops") {
      throw ToolError("--external-drops requires desktop verification.")
    }
    if command == "package" {
      try PackageOptions(directoryOnly: flags.contains("dir"), desktop: flags.contains("desktop"))
        .validate()
    }
  }
}

public enum Automation {
  public static let help = """
    Usage: ./polka COMMAND [OPTIONS]
      setup                         Resolve Swift packages and build helpers
      dev [--release --prebuilt]     Build with the stable development identity and run
      build [--debug --prebuilt --official --development-signing]
      test [all|app|tools]           Run Swift tests (default: all)
      coverage                      Run app tests and enforce LLVM coverage gates
      search-test                   Verify the native search regression corpus
      desktop [core|all|updates|files] [--release --prebuilt --external]
      verify [--no-desktop --no-updates --no-tools --prebuilt --release --external-drops]
      package [--prebuilt --desktop --official --debug --dir]
      release [--prebuilt --desktop --publish]
      release-verify                Authenticate release artifacts
      release-notes TAG OUTPUT.md [SOURCE.json] | --version TAG
      release-prepare               Pin and validate the CI release source
      signing-certificate DIRECTORY Create a persistent release signing identity
      emoji-data                    Regenerate the pinned Unicode/CLDR catalog
      format [--check]              Format or lint repository Swift source
      build-helpers                 Compile the native helper executables
    """
  public static func format(check: Bool, context: ToolContext) throws {
    let paths = [
      "native-app/Package.swift", "native-app/Sources", "native-app/Tests", "tools/Package.swift",
      "tools/Sources", "tools/Tests", "native", "scripts", "tests/desktop",
    ]
    try Command.run(
      "swift",
      [
        "format", check ? "lint" : "format", check ? "--strict" : "--in-place", "--recursive",
        "--parallel",
      ] + paths, environment: context.environment, directory: context.root)
  }
  public static func tests(_ selected: String, context: ToolContext) throws {
    for package in selected == "all"
      ? ["native-app", "tools"] : [selected == "app" ? "native-app" : "tools"]
    {
      try Command.run(
        "swift", ["test"] + context.swiftBuildArguments + ["--package-path", package],
        environment: context.environment,
        directory: context.root)
    }
  }
  @discardableResult public static func developmentBuild(
    release: Bool, prebuilt: Bool, context: ToolContext
  ) throws -> BuildResult {
    try DevelopmentTool.withSigning(context.environment) { environment, signing in
      try BuildTool.build(
        options: BuildOptions(release: release, prebuilt: prebuilt, developmentSigning: signing),
        context: ToolContext(root: context.root, environment: environment))
    }
  }
  private static func desktopBuild(release: Bool, context: ToolContext) throws -> URL {
    let product = try PolkaMetadata.load(root: context.root).build.productName + " Native"
    let output = context.root.appendingPathComponent(
      "release/native-test/\(release ? "release" : "debug")/\(product).app")
    return try BuildTool.build(
      options: BuildOptions(release: release, bundlePath: output), context: context
    ).bundle
  }
  public static func run(_ request: ToolRequest, context: ToolContext = ToolContext()) async throws
  {
    let flags = request.flags
    if request.command == "help" || flags.contains("help") {
      print(help)
      return
    }
    let release = flags.contains("release")
    let prebuilt = flags.contains("prebuilt")
    switch request.command {
    case "setup":
      for package in ["native-app", "tools"] {
        try Command.run(
          "swift", ["package", "--package-path", package, "resolve"],
          environment: context.environment, directory: context.root)
      }
      try BuildTool.buildHelpers(context: context)
    case "dev":
      let built = try developmentBuild(release: release, prebuilt: prebuilt, context: context)
      try Task.checkCancellation()
      if ToolCancellationRegistry.shared.isCancelled { throw CancellationError() }
      let child = Command.process(
        built.bundle.appendingPathComponent("Contents/MacOS/PolkaNative").path,
        environment: SigningTool.publicEnvironment(context.environment), directory: context.root)
      child.standardInput = FileHandle.standardInput
      child.standardOutput = FileHandle.standardOutput
      child.standardError = FileHandle.standardError
      try child.run()
      let registration = ToolCancellationRegistry.shared.register { Command.terminate(child) }
      defer { ToolCancellationRegistry.shared.unregister(registration) }
      let signals = [SIGINT, SIGTERM].map { value -> DispatchSourceSignal in
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
        source.setEventHandler { Command.terminate(child, signal: value) }
        source.resume()
        return source
      }
      child.waitUntilExit()
      for source in signals { source.cancel() }
      guard child.terminationStatus == 0 else {
        throw ToolError(
          "Polka exited with status \(child.terminationStatus).", exitCode: child.terminationStatus)
      }
    case "build":
      if flags.contains("development-signing") {
        _ = try developmentBuild(
          release: !flags.contains("debug"), prebuilt: prebuilt, context: context)
      } else if flags.contains("official") {
        try SigningTool.withKeychain(context.environment) { environment in
          _ = try BuildTool.build(
            options: BuildOptions(
              release: !flags.contains("debug"), official: true, prebuilt: prebuilt),
            context: ToolContext(root: context.root, environment: environment))
        }
      } else {
        _ = try BuildTool.build(
          options: BuildOptions(release: !flags.contains("debug"), prebuilt: prebuilt),
          context: context)
      }
    case "build-helpers": try BuildTool.buildHelpers(context: context)
    case "test": try tests(request.positionals.first ?? "all", context: context)
    case "coverage": try Coverage.run(context: context)
    case "search-test": try Regression.run(context: context)
    case "format": try format(check: flags.contains("check"), context: context)
    case "verify":
      try format(check: true, context: context)
      try Coverage.run(context: context)
      if !flags.contains("no-tools") { try tests("tools", context: context) }
      // Preserve coverage build settings across the probe build so the next
      // verification can reuse instrumented intermediates. Export happens first.
      try Regression.run(context: context, codeCoverage: true)
      if !flags.contains("no-desktop") {
        var app: URL?
        if !prebuilt {
          app = try desktopBuild(release: release, context: context)
        }
        try await Desktop.smoke(release: release, app: app, context: context)
        if !flags.contains("no-updates") {
          try await UpdateSmoke.run(prebuilt: true, release: release, context: context)
        }
        if flags.contains("external-drops") {
          try await Desktop.files(release: release, app: app, external: true, context: context)
        }
      }
    case "desktop":
      let selected = request.positionals.first ?? "core"
      var app: URL?
      if selected != "updates", !prebuilt {
        app = try desktopBuild(release: release, context: context)
      }
      if selected == "core" || selected == "all" {
        try await Desktop.smoke(release: release, app: app, context: context)
      }
      if selected == "updates" || selected == "all" {
        try await UpdateSmoke.run(
          prebuilt: prebuilt || app != nil, release: release, context: context)
      }
      if selected == "files" || selected == "all" && flags.contains("external") {
        try await Desktop.files(
          release: release, app: app, external: true, context: context)
      }
    case "package":
      _ = try PackageTool.package(
        options: PackageOptions(
          official: flags.contains("official"), prebuilt: prebuilt,
          directoryOnly: flags.contains("dir"), debug: flags.contains("debug"),
          desktop: flags.contains("desktop")), context: context)
    case "release":
      _ = try ReleaseTool.release(
        options: ReleaseOptions(
          prebuilt: prebuilt, desktop: flags.contains("desktop"), publish: flags.contains("publish")
        ), context: context)
    case "release-verify": _ = try ReleaseTool.verifyRelease(context: context)
    case "release-notes":
      try ReleaseTool.notesCommand(arguments: request.arguments, context: context)
    case "release-prepare": _ = try ReleasePreparation.run(context: context)
    case "signing-certificate":
      try ReleaseTool.createSigningCertificate(arguments: request.positionals, context: context)
    case "emoji-data": try await EmojiGenerator.run(context: context)
    default: throw ToolError("Unknown command.")
    }
  }
}
