import Darwin
import Foundation
import PolkaTools

// Disposable external-command stand-in used only by Swift integration tests.
@main struct ToolFixtureCLI {
  static func main() throws {
    let env = ProcessInfo.processInfo.environment
    let args = Array(CommandLine.arguments.dropFirst())
    let command = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    func append(_ value: Any, to path: String) throws {
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      try handle.seekToEnd()
      var data = try JSONSerialization.data(withJSONObject: value)
      data.append(10)
      try handle.write(contentsOf: data)
    }
    if let directory = env["INSTALL_TEST_ROOT"], let log = env["INSTALL_TEST_LOG"] {
      try append(["command": command, "args": args], to: log)
      let root = URL(fileURLWithPath: directory)
      let fm = FileManager.default
      func fail(_ condition: Bool) { if condition { exit(1) } }
      func writable(_ path: URL) throws {
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: path.path, isDirectory: &directory), directory.boolValue else {
          return
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        for file in try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
          try writable(file)
        }
      }
      switch command {
      case "uname": print(args.first == "-s" ? env["PLATFORM"] ?? "Darwin" : env["ARCH"] ?? "arm64")
      case "sw_vers": print(env["OS_VERSION"] ?? "27.0")
      case "pgrep": exit(env["RUNNING"] == "true" ? 0 : 1)
      case "curl":
        fail(env["DOWNLOAD_FAILURE"] != nil)
        if args.last!.hasSuffix("/latest") {
          print(
            env["RELEASE_URL"] ?? "https://github.com/mishankov/polka/releases/tag/v0.5.0",
            terminator: "")
        } else {
          let destination = URL(fileURLWithPath: args[args.firstIndex(of: "--output")! + 1])
          let source = root.appendingPathComponent(
            args.last!.hasSuffix("/checksums.txt") ? "checksums.txt" : "archive.zip")
          try? fm.removeItem(at: destination)
          try fm.copyItem(at: source, to: destination)
        }
      case "zipinfo": print(env["ZIP_ENTRIES"] ?? "Polka.app/\nPolka.app/Contents/Info.plist")
      case "ditto":
        let extracting = args.first == "-x"
        let source =
          extracting ? root.appendingPathComponent("bundle") : URL(fileURLWithPath: args[0])
        let destination = URL(fileURLWithPath: extracting ? args.last! + "/Polka.app" : args[1])
        try fm.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        fail(!extracting && env["COPY_FAILURE"] != nil)
      case "plutil":
        print(
          args[1] == "CFBundleIdentifier"
            ? env["BUNDLE_ID"] ?? "app.polka.desktop" : env["BUNDLE_VERSION"] ?? "0.5.0")
      case "codesign":
        fail(
          env["SIGNATURE_FAILURE"] != nil
            || (env["STAGED_SIGNATURE_FAILURE"] != nil && args.last!.contains(".polka-install.")))
      case "xattr":
        fail(env["QUARANTINE_FAILURE"] != nil)
        try fm.removeItem(atPath: args.last! + "/quarantine")
      case "mv":
        fail(
          env["MOVE_FAILURE"] != nil && args[0].contains(".polka-install.")
            && args[0].hasSuffix("/Polka.app"))
        try fm.moveItem(atPath: args[0], toPath: args[1])
      case "open": fail(env["LAUNCH_FAILURE"] != nil)
      case "sudo":
        if args.first == "-v" { exit(0) }
        if args.first == "rm" || args.first == "mv" {
          try writable(URL(fileURLWithPath: args.first == "mv" ? args[1] : args.last!))
        }
        let child = Command.process(args[0], Array(args.dropFirst()), environment: env)
        try child.run()
        child.waitUntilExit()
        exit(child.terminationStatus)
      default: throw ToolError("Unexpected installer command: \(command)")
      }
      return
    }
    if let log = env["RELEASE_TEST_LOG"] {
      try append(args, to: log)
      if args.starts(with: ["release", "view"]) {
        guard let existing = env["RELEASE_TEST_EXISTING"], !existing.isEmpty else { exit(1) }
        print("{\"isDraft\":\(existing == "draft"),\"targetCommitish\":\"master\"}")
      } else if args.starts(with: ["release", "create"]) {
        if let index = args.firstIndex(of: "--notes-file"),
          let path = env["RELEASE_TEST_DESCRIPTION"]
        {
          try FileManager.default.copyItem(atPath: args[index + 1], toPath: path)
        }
      } else if args.first == "api" && args.contains("POST") {
        let ref = String(args.first { $0.hasPrefix("ref=") }!.dropFirst(4))
        let requested = String(args.first { $0.hasPrefix("sha=") }!.dropFirst(4))
        let race = env["RELEASE_TEST_RACE"] ?? ""
        try Command.run(
          "git",
          [
            "--git-dir", env["RELEASE_TEST_REMOTE"]!, "update-ref", ref,
            race.isEmpty ? requested : race,
          ], environment: env)
      } else if args.first == "api" && args[1].contains("/commits/") {
        print(env["RELEASE_TEST_COMMIT"]!)
      } else {
        throw ToolError("Unexpected GitHub fixture operation.")
      }
      return
    }
    if args.first == "ignore-termination", args.count == 2 {
      signal(SIGTERM, SIG_IGN)
      try Data(String(getpid()).utf8).write(to: URL(fileURLWithPath: args[1]), options: .atomic)
      while true { _ = pause() }
    }
    if args.first == "streams" {
      FileHandle.standardOutput.write(Data(String(repeating: "o", count: 1_000_000).utf8))
      FileHandle.standardError.write(Data(String(repeating: "e", count: 1_000_000).utf8))
      return
    }
    if args.first == "stdin" {
      FileHandle.standardOutput.write(FileHandle.standardInput.readDataToEndOfFile())
      return
    }
    if args.first == "fail" {
      FileHandle.standardError.write(Data("fixture secret diagnostic".utf8))
      exit(9)
    }
    throw ToolError("A disposable fixture environment is required.")
  }
}
