import CryptoKit
import Darwin
import Foundation

/// Compile on the host, then run the prepared executables on an isolated guest.
/// No host desktop input, profile or signing credentials are exposed.
public enum DesktopVM {
  public static let defaultImage = "ghcr.io/cirruslabs/macos-golden-gate-xcode:27"
  static let guestSource = "/Volumes/My Shared Files/polka-source"
  static let guestOutput = "/Volumes/My Shared Files/polka-output"
  static let guestBootstrap = "/Volumes/My Shared Files/polka-bootstrap"

  struct Configuration {
    let name: String
    let image: String
    let state: URL
    let tart: URL
    init(context: ToolContext) throws {
      let env = context.environment
      name = env["POLKA_VM_NAME"] ?? "polka-desktop-tests"
      guard ToolFiles.matches(name, "^polka-[A-Za-z0-9-]{1,80}$") else {
        throw ToolError(
          "POLKA_VM_NAME must start with polka- and contain only letters, digits and hyphens.")
      }
      image = env["POLKA_VM_IMAGE"] ?? defaultImage
      let home = FileManager.default.homeDirectoryForCurrentUser
      let base = home.appendingPathComponent("Library/Application Support/polka-development")
      state = URL(
        fileURLWithPath: env["POLKA_VM_STATE"] ?? base.appendingPathComponent("desktop-vm").path)
      let managed = base.appendingPathComponent("tart/tart.app/Contents/MacOS/tart")
      if let explicit = env["POLKA_TART"] {
        guard explicit.hasPrefix("/") else {
          throw ToolError("POLKA_TART must be an absolute executable path.")
        }
        tart = URL(fileURLWithPath: explicit)
      } else {
        let candidates = [managed.path, "/opt/homebrew/bin/tart", "/usr/local/bin/tart"]
        guard
          let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
          throw ToolError(
            "Tart is not installed. Install it with brew install openai/tools/tart, or set POLKA_TART to tart.app/Contents/MacOS/tart. Then run ./polka vm setup."
          )
        }
        tart = URL(fileURLWithPath: path)
      }
    }
    var owner: URL { state.appendingPathComponent(name + ".json") }
    var lock: URL { state.appendingPathComponent(name + ".lock") }
  }

  public static func usesVM(_ environment: [String: String]) throws -> Bool {
    switch environment["POLKA_DESKTOP_BACKEND"] {
    case "host": return false
    case "guest":
      // A guest marker alone must never accidentally enable host GUI tests.
      var value: Int32 = 0
      var size = MemoryLayout<Int32>.size
      guard sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0, value == 1 else {
        throw ToolError("POLKA_DESKTOP_BACKEND=guest requires a virtual machine.")
      }
      return false
    case nil: return environment["CI"] != "true" && environment["GITHUB_ACTIONS"] != "true"
    default: throw ToolError("POLKA_DESKTOP_BACKEND must be host or guest.")
    }
  }

  static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  struct Output {
    let status: Int32
    let text: String
  }
  struct TransportTimeout: Error, CustomStringConvertible {
    let command: String
    let diagnostics: String
    var description: String { "Tart \(command) timed out: \(diagnostics)" }
  }
  /// Bound every transport operation and reap the exact owned child on all exits.
  static func execute(
    _ config: Configuration, _ arguments: [String], context: ToolContext,
    timeout: TimeInterval = 30, stream: Bool = false
  ) async throws -> Output {
    try Task.checkCancellation()
    var env = Desktop.environment(context.environment)
    env["TART_NO_AUTO_PRUNE"] = "1"
    let child = try DesktopChild(executable: config.tart, arguments: arguments, environment: env)
    do {
      let deadline = Date().addingTimeInterval(timeout)
      var printed = 0
      while child.process.isRunning {
        if stream {
          let bytes = Data(child.diagnostics.utf8)
          if bytes.count > printed {
            FileHandle.standardOutput.write(bytes.dropFirst(printed))
            printed = bytes.count
          }
        }
        guard Date() < deadline else {
          throw TransportTimeout(
            command: arguments.first ?? "command", diagnostics: child.diagnostics)
        }
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      let code = child.process.terminationStatus
      try await child.stop()
      try Task.checkCancellation()
      if stream { FileHandle.standardOutput.write(Data(child.diagnostics.utf8).dropFirst(printed)) }
      return Output(status: code, text: child.diagnostics)
    } catch {
      try await child.stop()
      throw error
    }
  }

  static func checked(
    _ config: Configuration, _ arguments: [String], context: ToolContext,
    timeout: TimeInterval = 30, stream: Bool = false
  ) async throws -> String {
    let output = try await execute(
      config, arguments, context: context, timeout: timeout, stream: stream)
    guard output.status == 0 else {
      throw ToolError("Tart failed: \(output.text)", exitCode: output.status)
    }
    return output.text
  }

  static func existing(_ config: Configuration, context: ToolContext) async throws -> [String: Any]?
  {
    let output = try await checked(config, ["list", "--format", "json"], context: context)
    guard
      let entries = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
    else {
      throw ToolError("Invalid Tart VM list.")
    }
    return entries.first {
      $0["Name"] as? String == config.name && $0["Source"] as? String == "local"
    }
  }

  static func requireOwned(_ config: Configuration) throws {
    guard let owner = try? Files.json(config.owner) as? [String: Any],
      owner["name"] as? String == config.name, owner["image"] as? String == config.image
    else {
      throw ToolError(
        "VM is not managed by this runner, or its image changed. Run ./polka vm setup with a new POLKA_VM_NAME; existing VMs are never replaced."
      )
    }
  }

  public static func setup(context: ToolContext) async throws {
    let config = try Configuration(context: context)
    try Files.mkdir(config.state)
    let lock = try await DesktopLock.acquire(path: config.lock, timeout: 120)
    defer { try? lock.release() }
    if try await existing(config, context: context) == nil {
      if FileManager.default.fileExists(atPath: config.owner.path) { try requireOwned(config) }
      try Files.writeJSON(["name": config.name, "image": config.image], to: config.owner)
      print("Downloading the macOS/Xcode test image (one-time setup).")
      _ = try await checked(
        config, ["clone", config.image, config.name, "--concurrency", "8"], context: context,
        timeout: 86_400, stream: true)
    }
    try requireOwned(config)
    let info = try await checked(
      config, ["get", config.name, "--format", "json"], context: context)
    let json = try JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any]
    guard json?["Running"] as? Bool == false else {
      throw ToolError(
        "The test VM is already running. Stop its existing session before setup; this runner will not take it over."
      )
    }
    _ = try await checked(
      config,
      [
        "set", config.name, "--cpu", "4", "--memory", "12288", "--display", "1920x1080",
        "--no-display-refit",
      ], context: context)
    try await withGuest(config, context: context) { _ in
      print("VM setup passed: macOS 27+, Xcode 27+, and an active guest desktop.")
    }
  }

  static let doctorScript = """
    set -eu
    test "$(/usr/sbin/sysctl -n kern.hv_vmm_present)" = 1
    test "$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d . -f 1)" -ge 27
    test "$(/usr/bin/xcodebuild -version | /usr/bin/awk '/Xcode/{print int($2)}')" -ge 27
    test "$(/usr/bin/stat -f %u /dev/console)" = "$(/usr/bin/id -u)"
    test "$(/usr/bin/id -u)" -ne 0
    /usr/bin/xcrun swift --version
    /usr/bin/sw_vers
    /usr/bin/xcodebuild -version
    """

  static let displayScript = """
    import CoreGraphics
    import Darwin
    let display = CGMainDisplayID()
    let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] ?? []
    guard let mode = modes.first(where: { $0.width == 1920 && $0.height == 1080 }) else {
      fputs("Guest does not support the required 1920x1080 display.\\n", stderr)
      exit(1)
    }
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success,
      let configuration,
      CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil) == .success,
      CGCompleteDisplayConfiguration(configuration, .permanently) == .success
    else {
      fputs("Could not configure the guest display.\\n", stderr)
      exit(1)
    }
    let bounds = CGDisplayBounds(display)
    guard bounds.width == 1920 && bounds.height == 1080 else { exit(1) }
    print("Guest display configured: 1920x1080")
    """

  static var prepareScript: String {
    """
    set -eu
    test "$(/usr/sbin/sysctl -n kern.hv_vmm_present)" = 1
    test "$(/usr/bin/id -u)" = "$(/usr/bin/stat -f %u /dev/console)"
    /usr/bin/defaults write com.apple.WindowManager StandardHideWidgets -bool true
    /usr/bin/defaults write com.apple.WindowManager StageManagerHideWidgets -bool true
    /usr/bin/defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
    /usr/bin/defaults write com.apple.dock autohide -bool true
    /usr/bin/killall Dock NotificationCenter 2>/dev/null || true
    for service in $(/bin/launchctl list | /usr/bin/awk '$3 ~ /notificationcenterui/ || $3 == "com.apple.Dock.agent" || $3 == "com.apple.WindowManager.agent" { print $3 }'); do
      /bin/launchctl bootout "gui/$(/usr/bin/id -u)/$service"
    done
    \(quote(guestBootstrap + "/prepare-display"))
    /bin/sleep 2
    if /usr/bin/pgrep -x NotificationCenter >/dev/null || /usr/bin/pgrep -x Dock >/dev/null || /usr/bin/pgrep -x WindowManager >/dev/null; then
      echo 'A system overlay still covers the managed guest desktop.' >&2
      exit 1
    fi
    """
  }

  static func withGuest<T>(
    _ config: Configuration, source: URL? = nil, output: URL? = nil, context: ToolContext,
    readinessTimeout: TimeInterval = 180, probeTimeout: TimeInterval = 15,
    operation: (DesktopChild) async throws -> T
  ) async throws -> T {
    let bootstrap = try Files.temporary("polka-vm-bootstrap")
    defer { try? FileManager.default.removeItem(at: bootstrap) }
    try compileDisplay(to: bootstrap, context: context)
    let info = try await checked(
      config, ["get", config.name, "--format", "json"], context: context)
    guard let json = try JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any],
      json["Running"] as? Bool == false
    else {
      throw ToolError(
        "Test VM is already running outside this invocation; refusing to take it over.")
    }
    var arguments = [
      "run", config.name, "--no-graphics", "--no-audio", "--no-clipboard", "--no-usb-accessories",
      "--dir=polka-bootstrap:\(bootstrap.path):ro",
    ]
    if let source { arguments.append("--dir=polka-source:\(source.path):ro") }
    if let output { arguments.append("--dir=polka-output:\(output.path)") }
    var env = Desktop.environment(context.environment)
    env["TART_NO_AUTO_PRUNE"] = "1"
    let vm = try DesktopChild(executable: config.tart, arguments: arguments, environment: env)
    do {
      print("Starting isolated desktop \(config.name)…")
      let deadline = Date().addingTimeInterval(readinessTimeout)
      var last = ""
      var readiness = doctorScript
      if source != nil { readiness += "\ntest -r " + quote(guestSource + "/run.sh") }
      if output != nil { readiness += "\ntest -w " + quote(guestOutput) }
      while true {
        try Task.checkCancellation()
        guard vm.process.isRunning else { throw ToolError("VM failed to start: \(vm.diagnostics)") }
        guard Date() < deadline else {
          throw ToolError(
            "Guest desktop/Xcode did not become ready. \(last). Image must provide auto-login and Tart Guest Agent in the GUI session."
          )
        }
        do {
          let ready = try await execute(
            config, ["exec", config.name, "/bin/sh", "-c", readiness], context: context,
            timeout: min(probeTimeout, deadline.timeIntervalSinceNow))
          if ready.status == 0 {
            print(ready.text)
            break
          }
          last = ready.text
        } catch let error as TransportTimeout {
          // The guest agent can be unavailable during boot. execute has reaped
          // this probe; keep the owned VM running until the readiness deadline.
          last = error.description
        }
        guard Date() < deadline else {
          throw ToolError(
            "Guest desktop/Xcode did not become ready. \(last). Image must provide auto-login and Tart Guest Agent in the GUI session."
          )
        }
        try await Task.sleep(
          nanoseconds: UInt64(max(0, min(1, deadline.timeIntervalSinceNow)) * 1_000_000_000))
      }
      print(
        try await checked(
          config, ["exec", config.name, "/bin/sh", "-c", prepareScript], context: context,
          timeout: 60))
      let result = try await operation(vm)
      try await vm.stop()
      try Data(vm.diagnostics.utf8).write(to: config.state.appendingPathComponent("last-boot.log"))
      return result
    } catch {
      try await vm.stop()
      try? Data(vm.diagnostics.utf8).write(to: config.state.appendingPathComponent("last-boot.log"))
      throw error
    }
  }

  /// Include edited and untracked source, without ignored caches, secrets or Git credentials.
  static func snapshot(context: ToolContext, to destination: URL) throws {
    try Files.mkdir(destination)
    let listed = try Command.execute(
      "git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
      directory: context.root)
    guard listed.status == 0 else {
      throw ToolError("Cannot snapshot project sources: \(listed.error)")
    }
    let fm = FileManager.default
    for bytes in listed.stdout.split(separator: 0) {
      let path = String(decoding: bytes, as: UTF8.self)
      guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
        throw ToolError("Unsafe source path.")
      }
      if path.split(separator: "/").contains(where: { $0.hasPrefix(".env") && $0 != ".env.example" }
      ) {
        continue
      }
      let from = context.root.appendingPathComponent(path)
      guard fm.fileExists(atPath: from.path) else { continue }  // deleted worktree file
      let target = destination.appendingPathComponent(path)
      let resolved = from.resolvingSymlinksInPath().standardizedFileURL.path
      guard
        resolved.hasPrefix(context.root.resolvingSymlinksInPath().standardizedFileURL.path + "/")
      else {
        throw ToolError("Source symlink leaves the project: \(path)")
      }
      try Files.mkdir(target.deletingLastPathComponent())
      try fm.copyItem(at: from, to: target)
    }
  }

  static let fixtureEnvironment = [
    "POLKA_NATIVE_SCROLL_ONLY", "POLKA_NATIVE_EXTERNAL_ONLY", "POLKA_NATIVE_FILE_INTERNAL_ONLY",
    "POLKA_NATIVE_SMOKE_WINDOW_CAPTURE",
    "POLKA_NATIVE_SYSTEM_STATUS_MEASURE",
  ]
  static func compileDisplay(to directory: URL, context: ToolContext) throws {
    let source = directory.appendingPathComponent("prepare-display.swift")
    try Data(displayScript.utf8).write(to: source)
    try Command.run(
      "/usr/bin/xcrun",
      ["swiftc", source.path, "-o", directory.appendingPathComponent("prepare-display").path],
      environment: SigningTool.publicEnvironment(context.environment))
    try FileManager.default.removeItem(at: source)
  }

  /// Only runnable outputs are exported, never .build databases or credentials.
  static func prepareHost(
    arguments: [String], app: URL?, staging: URL, context: ToolContext
  ) throws {
    let request = try ToolRequest(arguments)
    guard request.command == "desktop" else {
      throw ToolError("VM runner requires a desktop command.")
    }
    let selected = request.positionals.first ?? "core"
    let updates = selected == "updates" || selected == "all"
    let files = selected == "files" || selected == "all" && request.flags.contains("external")
    let release = request.flags.contains("release")
    let runtime = staging.appendingPathComponent("runtime")
    try Files.mkdir(runtime)
    print("Preparing host-built executables for the VM…")
    try Command.run(
      "/usr/bin/xcrun",
      ["swift", "build"] + context.swiftBuildArguments
        + ["--package-path", "tools", "-c", "debug", "--product", "polka-tool"],
      environment: SigningTool.publicEnvironment(context.environment), directory: context.root)
    let tools = try Command.capture(
      "/usr/bin/xcrun",
      ["swift", "build"] + context.swiftBuildArguments
        + ["--package-path", "tools", "-c", "debug", "--show-bin-path"],
      environment: SigningTool.publicEnvironment(context.environment), directory: context.root
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: tools).appendingPathComponent("polka-tool"),
      to: runtime.appendingPathComponent("polka-tool"))
    if let app {
      try BuildTool.assertRelativeBundleLinks(app)
      try Command.run("/usr/bin/ditto", [app.path, runtime.appendingPathComponent("app.app").path])
    }
    if app == nil || updates {
      let output = runtime.appendingPathComponent(app == nil ? "app.app" : "prepared.app")
      let built = try BuildTool.build(
        options: BuildOptions(
          release: release, prebuilt: request.flags.contains("prebuilt"), bundlePath: output),
        context: context)
      if updates && app == nil {
        try Command.run(
          "/usr/bin/ditto",
          [built.bundle.path, runtime.appendingPathComponent("prepared.app").path])
      }
    }
    if updates {
      try FileManager.default.copyItem(
        at: context.root.appendingPathComponent(
          "native-app/.build/artifacts/sparkle/Sparkle/bin/sign_update"),
        to: runtime.appendingPathComponent("sign_update"))
    }
    if files {
      try Command.run(
        "/usr/bin/xcrun",
        [
          "swiftc", "tests/desktop/native-external-file-source.swift", "-o",
          runtime.appendingPathComponent("external-source").path,
        ],
        environment: SigningTool.publicEnvironment(context.environment), directory: context.root)
    }
  }

  static func guestScript(
    arguments: [String], workspace: String, environment: [String: String] = [:]
  ) -> String {
    """
    set -euo pipefail
    export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
    export POLKA_DESKTOP_BACKEND=guest
    \(fixtureEnvironment.compactMap { key in environment[key].map { "export " + key + "=" + quote($0) } }.joined(separator: "\n"))
    unset POLKA_PROFILE ELECTRON_RUN_AS_NODE POLKA_VM_PREPARED_APP POLKA_VM_SIGN_UPDATE POLKA_VM_EXTERNAL_SOURCE
    workspace=\(quote(workspace))
    mkdir -p "$workspace"
    /usr/bin/rsync -a --delete --checksum --exclude=native-app/.build --exclude=tools/.build --exclude=release --exclude=artifacts \(quote(guestSource + "/project/")) "$workspace/"
    /usr/bin/rsync -a --delete --checksum \(quote(guestSource + "/runtime/")) "$workspace/runtime/"
    cd "$workspace"
    rm -rf artifacts/desktop
    export POLKA_NATIVE_APP="$workspace/runtime/app.app"
    if test -d "$workspace/runtime/prepared.app"; then
      export POLKA_VM_PREPARED_APP="$workspace/runtime/prepared.app"
      export POLKA_VM_SIGN_UPDATE="$workspace/runtime/sign_update"
    fi
    if test -x "$workspace/runtime/external-source"; then
      export POLKA_VM_EXTERNAL_SOURCE="$workspace/runtime/external-source"
    fi
    echo 'Running host-built executables in the VM (guest compilation disabled).'
    set +e
    ./runtime/polka-tool \(arguments.filter { $0 != "--prebuilt" }.map(quote).joined(separator: " ")) --prebuilt 2>&1 | /usr/bin/tee \(quote(guestOutput + "/tests.log"))
    status=$?
    set -e
    if test -d artifacts; then /usr/bin/ditto artifacts \(quote(guestOutput + "/artifacts")); fi
    exit "$status"
    """
  }

  public static func run(
    arguments: [String], app: URL? = nil, context: ToolContext = ToolContext()
  ) async throws {
    try await runPrepared(arguments: arguments, context: context) { staging in
      try prepareHost(arguments: arguments, app: app, staging: staging, context: context)
    }
  }

  static func runPrepared(
    arguments: [String], context: ToolContext, prepare: (URL) throws -> Void
  ) async throws {
    let config = try Configuration(context: context)
    try Files.mkdir(config.state)
    let lock = try await DesktopLock.acquire(path: config.lock, timeout: 600)
    defer { try? lock.release() }
    try requireOwned(config)
    let staging = try Files.temporary("polka-vm-source")
    defer { try? FileManager.default.removeItem(at: staging) }
    let preparationStart = ProcessInfo.processInfo.systemUptime
    try prepare(staging)
    try snapshot(context: context, to: staging.appendingPathComponent("project"))
    let preparationSeconds = ProcessInfo.processInfo.systemUptime - preparationStart
    let stamp = UUID().uuidString
    let output = context.root.appendingPathComponent("artifacts/desktop/vm/" + stamp)
    try Files.mkdir(output)
    let hash = SHA256.hash(data: Data(context.root.standardizedFileURL.path.utf8)).prefix(8).map {
      String(format: "%02x", $0)
    }.joined()
    let script = guestScript(
      arguments: arguments, workspace: "/Users/admin/polka-workspaces/" + hash,
      environment: context.environment)
    try Data(script.utf8).write(to: staging.appendingPathComponent("run.sh"))
    var failure: Error?
    var guestTestsSeconds: Double = 0
    let vmStart = ProcessInfo.processInfo.systemUptime
    do {
      try await withGuest(config, source: staging, output: output, context: context) { _ in
        let started = ProcessInfo.processInfo.systemUptime
        defer { guestTestsSeconds = ProcessInfo.processInfo.systemUptime - started }
        let result = try await execute(
          config,
          ["exec", config.name, "/usr/bin/caffeinate", "-diu", "/bin/sh", guestSource + "/run.sh"],
          context: context,
          timeout: 3600, stream: true)
        guard result.status == 0 else {
          throw ToolError(
            "VM tests failed (\(result.status)). See \(output.path)/tests.log",
            exitCode: result.status)
        }
      }
    } catch { failure = error }
    let vmSeconds = ProcessInfo.processInfo.systemUptime - vmStart
    // Guest diagnostics remain available on failures, and in their normal paths.
    let artifacts = output.appendingPathComponent("artifacts")
    if FileManager.default.fileExists(atPath: artifacts.path) {
      try Command.run(
        "/usr/bin/ditto", [artifacts.path, context.root.appendingPathComponent("artifacts").path],
        cancellable: false)
    }
    try Files.writeJSON(
      [
        "vm": config.name, "image": config.image, "arguments": arguments, "ok": failure == nil,
        "failure": failure.map { String(describing: $0) } ?? "",
        "compilation": "host", "hostPreparationSeconds": preparationSeconds,
        "vmSeconds": vmSeconds, "guestTestsSeconds": guestTestsSeconds,
      ], to: output.appendingPathComponent("result.json"))
    print("VM diagnostics: \(output.path)")
    if let failure { throw failure }
  }

  public static func doctor(context: ToolContext) async throws {
    let config = try Configuration(context: context)
    try requireOwned(config)
    let lock = try await DesktopLock.acquire(path: config.lock, timeout: 120)
    defer { try? lock.release() }
    try await withGuest(config, context: context) { _ in
      print("VM is ready for isolated desktop tests.")
    }
  }
}
