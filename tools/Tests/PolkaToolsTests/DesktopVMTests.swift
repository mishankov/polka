import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import PolkaTools

final class DesktopVMTests: XCTestCase {
  func testLocalDesktopUsesVMButCIAndExplicitHostStayDirect() throws {
    XCTAssertTrue(try DesktopVM.usesVM([:]))
    XCTAssertTrue(try DesktopVM.usesVM(["CI": "false"]))
    XCTAssertFalse(try DesktopVM.usesVM(["CI": "true"]))
    XCTAssertFalse(try DesktopVM.usesVM(["GITHUB_ACTIONS": "true"]))
    XCTAssertFalse(try DesktopVM.usesVM(["POLKA_DESKTOP_BACKEND": "host"]))
    XCTAssertThrowsError(try DesktopVM.usesVM(["POLKA_DESKTOP_BACKEND": "wrong"]))
  }

  func testShellArgumentsCannotRunSubstitutionsOrBreakQuoting() throws {
    let values = [
      "space and 'quote'", "$(touch /tmp/polka-never-created)", "`id`", "a\nb", "--release",
    ]
    for value in values {
      let result = try Command.capture("/bin/sh", ["-c", "printf %s " + DesktopVM.quote(value)])
      XCTAssertEqual(result, value)
    }
  }

  func testGuestDisplayPreparationCompilesWithoutChangingHostDisplay() throws {
    let root = try Files.temporary("polka-vm-display-script")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("prepare.swift")
    try TestSupport.write(DesktopVM.displayScript, to: source)
    _ = try Command.capture("/usr/bin/xcrun", ["swiftc", "-typecheck", source.path])
    _ = try Command.capture("/bin/sh", ["-n", "-c", DesktopVM.prepareScript])
    XCTAssertLessThan(
      try XCTUnwrap(DesktopVM.prepareScript.range(of: "kern.hv_vmm_present"))
        .lowerBound, try XCTUnwrap(DesktopVM.prepareScript.range(of: "defaults write")).lowerBound)
  }

  func testSnapshotIncludesDraftSourcesAndDeletionsWithoutIgnoredData() throws {
    let root = try Files.temporary("polka-vm-snapshot")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    let snapshot = root.appendingPathComponent("snapshot")
    try Files.mkdir(repo)
    _ = try Command.capture("git", ["init", "-q"], directory: repo)
    try TestSupport.write(
      ".env*\nartifacts/\n.build/\n", to: repo.appendingPathComponent(".gitignore"))
    try TestSupport.write("old", to: repo.appendingPathComponent("edited.swift"))
    try TestSupport.write("removed", to: repo.appendingPathComponent("deleted.swift"))
    _ = try Command.capture("git", ["add", "."], directory: repo)
    try TestSupport.write("new unsaved source", to: repo.appendingPathComponent("edited.swift"))
    try FileManager.default.removeItem(at: repo.appendingPathComponent("deleted.swift"))
    try TestSupport.write("new file", to: repo.appendingPathComponent("new.swift"))
    try TestSupport.write("secret", to: repo.appendingPathComponent(".env.local"))
    try TestSupport.write("old result", to: repo.appendingPathComponent("artifacts/result.json"))
    try DesktopVM.snapshot(context: ToolContext(root: repo), to: snapshot)
    XCTAssertEqual(
      try String(contentsOf: snapshot.appendingPathComponent("edited.swift"), encoding: .utf8),
      "new unsaved source")
    XCTAssertEqual(
      try String(contentsOf: snapshot.appendingPathComponent("new.swift"), encoding: .utf8),
      "new file")
    XCTAssertEqual(try TestSupport.children(snapshot), [".gitignore", "edited.swift", "new.swift"])
    try FileManager.default.createSymbolicLink(
      at: repo.appendingPathComponent("escape"), withDestinationURL: root)
    XCTAssertThrowsError(
      try DesktopVM.snapshot(
        context: ToolContext(root: repo), to: root.appendingPathComponent("unsafe")))
  }

  func testGuestScriptRunsCurrentSnapshotAndCollectsArtifactsOnFailure() throws {
    let root = try Files.temporary("polka-vm-script")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let output = root.appendingPathComponent("output")
    let workspace = root.appendingPathComponent("workspace")
    try Files.mkdir(output)
    try TestSupport.write(
      "edited source", to: source.appendingPathComponent("project/source.swift"))
    try TestSupport.write(
      "retained cache", to: workspace.appendingPathComponent("native-app/.build/cache"))
    try TestSupport.write("stale source", to: workspace.appendingPathComponent("removed.swift"))
    try TestSupport.write(
      "stale result", to: workspace.appendingPathComponent("artifacts/desktop/old.json"))
    try TestSupport.write(
      """
      #!/bin/sh
      mkdir -p artifacts/desktop/native-smoke
      printf '%s\\n' "$@" > artifacts/desktop/native-smoke/arguments
      printf '%s' "$POLKA_NATIVE_SCROLL_ONLY" > artifacts/desktop/native-smoke/scroll-mode
      cat source.swift
      exit 7
      """, to: source.appendingPathComponent("runtime/polka-tool"), executable: true)
    try TestSupport.write(
      "#!/bin/sh\nexit 99\n", to: source.appendingPathComponent("project/polka"), executable: true)
    try TestSupport.write(
      "stale helper", to: workspace.appendingPathComponent("runtime/sign_update"))
    let arguments = ["desktop", "core", "'literal' $(id)"]
    let script = DesktopVM.guestScript(
      arguments: arguments, workspace: workspace.path,
      environment: ["POLKA_NATIVE_SCROLL_ONLY": "1", "SECRET": "must not cross"]
    )
    .replacingOccurrences(of: DesktopVM.guestSource, with: source.path)
    .replacingOccurrences(of: DesktopVM.guestOutput, with: output.path)
    XCTAssertFalse(script.contains("must not cross"))
    let result = try Command.execute("/bin/sh", ["-c", script])
    XCTAssertEqual(result.status, 7)
    XCTAssertEqual(
      try String(contentsOf: output.appendingPathComponent("tests.log"), encoding: .utf8),
      "edited source")
    XCTAssertEqual(
      try String(
        contentsOf: output.appendingPathComponent("artifacts/desktop/native-smoke/arguments"),
        encoding: .utf8), (arguments + ["--prebuilt"]).joined(separator: "\n") + "\n")
    XCTAssertEqual(
      try String(
        contentsOf: output.appendingPathComponent("artifacts/desktop/native-smoke/scroll-mode"),
        encoding: .utf8), "1")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: workspace.appendingPathComponent("native-app/.build/cache").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: workspace.appendingPathComponent("removed.swift").path)
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: workspace.appendingPathComponent("runtime/sign_update").path))
    XCTAssertFalse(script.contains("swift run"))
    XCTAssertFalse(script.contains("swift build"))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: output.appendingPathComponent("artifacts/desktop/old.json").path))
  }

  func testGuestCannotCompileWithoutPreparedUpdaterOutputs() throws {
    XCTAssertThrowsError(
      try BuildTool.build(context: ToolContext(environment: ["POLKA_DESKTOP_BACKEND": "guest"]))
    ) { XCTAssertTrue(String(describing: $0).contains("Guest compilation is disabled")) }
  }

  func testPreparedTemplateCannotReplaceAnOrdinaryBuildOrDeleteItsInput() throws {
    let root = try Files.temporary("polka-vm-template-guard")
    defer { try? FileManager.default.removeItem(at: root) }
    let template = root.appendingPathComponent("input.app")
    try TestSupport.write("preserve input", to: template.appendingPathComponent("marker"))
    XCTAssertThrowsError(
      try BuildTool.build(
        options: BuildOptions(prebuilt: true, bundlePath: template, preparedBundle: template),
        context: ToolContext(root: TestSupport.root))
    ) {
      XCTAssertTrue(String(describing: $0).contains("restricted to disposable updater fixtures"))
    }
    XCTAssertEqual(
      try String(contentsOf: template.appendingPathComponent("marker"), encoding: .utf8),
      "preserve input")
  }

  /// Real process transport with a synthetic Tart executable; no VM or desktop.
  private func fixture(
    _ root: URL, failure: Int = 0, running: Bool = false,
    firstProbeHangs: Bool = false, allProbesHang: Bool = false
  ) throws -> ToolContext {
    let tart = root.appendingPathComponent("tart")
    let log = root.appendingPathComponent("calls")
    let pid = root.appendingPathComponent("vm.pid")
    let script = """
      #!/bin/sh
      printf '%s\\n' "$*" >> \(DesktopVM.quote(log.path))
      case "$1" in
        list) printf '[{"Name":"polka-fixture","Source":"local"}]' ;;
        get) printf '{"Running":\(running ? "true" : "false")}' ;;
        run)
          echo $$ > \(DesktopVM.quote(pid.path))
          for arg in "$@"; do
            case "$arg" in
              --dir=polka-output:*) printf '%s' "${arg#--dir=polka-output:}" > \(DesktopVM.quote(root.appendingPathComponent("output.path").path)) ;;
            esac
          done
          trap 'exit 0' TERM INT
          while :; do sleep 0.1; done
          ;;
        exec)
          if test "$4" = '-c'; then
            if \(allProbesHang ? "true" : "false") || { \(firstProbeHangs ? "true" : "false") && ! test -f \(DesktopVM.quote(root.appendingPathComponent("probe.pids").path)); }; then
              echo $$ >> \(DesktopVM.quote(root.appendingPathComponent("probe.pids").path))
              trap 'exit 0' TERM INT
              while :; do sleep 0.1; done
            fi
          fi
          if test "$4" = '-c'; then echo 'guest ready'; exit 0; fi
          if test -f \(DesktopVM.quote(root.appendingPathComponent("output.path").path)); then
            output=$(cat \(DesktopVM.quote(root.appendingPathComponent("output.path").path)))
            mkdir -p "$output/artifacts/desktop/native-smoke"
            echo 'synthetic failure report' > "$output/artifacts/desktop/native-smoke/result.json"
            echo 'synthetic guest log' > "$output/tests.log"
          fi
          echo 'synthetic guest result'
          exit \(failure)
          ;;
        *) exit 1 ;;
      esac
      """
    try TestSupport.write(script, to: tart, executable: true)
    var env = ProcessInfo.processInfo.environment
    env["POLKA_VM_NAME"] = "polka-fixture"
    env["POLKA_VM_STATE"] = root.appendingPathComponent("state").path
    env["POLKA_TART"] = tart.path
    let context = ToolContext(root: TestSupport.root, environment: env)
    let config = try DesktopVM.Configuration(context: context)
    try Files.writeJSON(["name": config.name, "image": config.image], to: config.owner)
    return context
  }

  func testHeadlessLifecycleReapsVMOnSuccessAndGuestFailure() async throws {
    for failure in [0, 7] {
      let root = try Files.temporary("polka-vm-lifecycle")
      defer { try? FileManager.default.removeItem(at: root) }
      let context = try fixture(root, failure: failure)
      let config = try DesktopVM.Configuration(context: context)
      do {
        try await DesktopVM.withGuest(config, context: context) { _ in
          let result = try await DesktopVM.execute(
            config, ["exec", config.name, "/bin/sh", "/fixture/run.sh"], context: context)
          if result.status != 0 { throw ToolError("test failed", exitCode: result.status) }
        }
        XCTAssertEqual(failure, 0)
      } catch { XCTAssertEqual((error as? ToolError)?.exitCode, Int32(failure)) }
      let pid = try Int32(
        String(contentsOf: root.appendingPathComponent("vm.pid"), encoding: .utf8)
          .trimmingCharacters(
            in: .whitespacesAndNewlines)
      ).unwrap()
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
      let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
      XCTAssertTrue(calls.contains("--no-graphics --no-audio --no-clipboard --no-usb-accessories"))
      XCTAssertFalse(calls.contains("stop "))  // never target another VM by name
    }
  }

  func testFullRunnerPreservesExitStatusArtifactsAndReleasesLockAfterFailure() async throws {
    let root = try Files.temporary("polka-vm-result")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("project")
    try Files.mkdir(repo)
    _ = try Command.capture("git", ["init", "-q"], directory: repo)
    try TestSupport.write("artifacts/\n", to: repo.appendingPathComponent(".gitignore"))
    try TestSupport.write("current source", to: repo.appendingPathComponent("source.swift"))
    var context = try fixture(root, failure: 7)
    context.root = repo
    do {
      try await DesktopVM.runPrepared(arguments: ["desktop", "core"], context: context) { staging in
        try TestSupport.write(
          "#!/bin/sh\nexit 7\n", to: staging.appendingPathComponent("runtime/polka-tool"),
          executable: true)
      }
      XCTFail("Failed guest passed")
    } catch { XCTAssertEqual((error as? ToolError)?.exitCode, 7) }
    let runs = repo.appendingPathComponent("artifacts/desktop/vm")
    let run = runs.appendingPathComponent(try XCTUnwrap(TestSupport.children(runs).first))
    let result = try XCTUnwrap(
      Files.json(run.appendingPathComponent("result.json")) as? [String: Any])
    XCTAssertEqual(result["ok"] as? Bool, false)
    XCTAssertEqual(
      try String(
        contentsOf: repo.appendingPathComponent("artifacts/desktop/native-smoke/result.json"),
        encoding: .utf8), "synthetic failure report\n")
    XCTAssertEqual(
      try String(contentsOf: run.appendingPathComponent("tests.log"), encoding: .utf8),
      "synthetic guest log\n")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: try DesktopVM.Configuration(context: context).lock.path))
    let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
    XCTAssertTrue(calls.contains("/usr/bin/caffeinate -diu /bin/sh"))
  }

  func testHostBuildFailureNeverStartsGuestAndReleasesLock() async throws {
    let root = try Files.temporary("polka-vm-build-failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try fixture(root)
    do {
      try await DesktopVM.runPrepared(arguments: ["desktop", "core"], context: context) { _ in
        throw ToolError("host compilation failed", exitCode: 9)
      }
      XCTFail("Failed build passed")
    } catch { XCTAssertEqual((error as? ToolError)?.exitCode, 9) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("vm.pid").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: try DesktopVM.Configuration(context: context).lock.path))
  }

  func testTransportTimeoutReapsOwnedProcess() async throws {
    let root = try Files.temporary("polka-vm-timeout")
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try fixture(root)
    let config = try DesktopVM.Configuration(context: context)
    do {
      _ = try await DesktopVM.execute(config, ["run", config.name], context: context, timeout: 2)
      XCTFail("Hung transport passed")
    } catch { XCTAssertTrue(String(describing: error).contains("timed out")) }
    let pid = try XCTUnwrap(
      Int32(
        String(contentsOf: root.appendingPathComponent("vm.pid"), encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testReadinessRetriesTimedOutProbeWithoutStoppingGuest() async throws {
    let root = try Files.temporary("polka-vm-slow-boot")
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try fixture(root, firstProbeHangs: true)
    let config = try DesktopVM.Configuration(context: context)
    try await DesktopVM.withGuest(
      config, context: context, readinessTimeout: 5, probeTimeout: 1
    ) { vm in
      XCTAssertTrue(vm.process.isRunning)
      let pid = try XCTUnwrap(
        Int32(
          try String(contentsOf: root.appendingPathComponent("probe.pids"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
    }
    let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
    XCTAssertEqual(calls.components(separatedBy: "exec polka-fixture").count - 1, 3)
    XCTAssertTrue(calls.contains("StandardHideWidgets"))
  }

  func testReadinessDeadlineStopsGuestAndEveryTimedOutProbe() async throws {
    let root = try Files.temporary("polka-vm-unready")
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try fixture(root, allProbesHang: true)
    let config = try DesktopVM.Configuration(context: context)
    let started = Date()
    do {
      try await DesktopVM.withGuest(
        config, context: context, readinessTimeout: 2, probeTimeout: 0.5
      ) { _ in XCTFail("Unready guest passed") }
      XCTFail("Unready guest passed")
    } catch {
      XCTAssertTrue(String(describing: error).contains("did not become ready"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    let paths = ["vm.pid", "probe.pids"]
    for path in paths {
      let pids = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
      for line in pids.split(separator: "\n") {
        let pid = try XCTUnwrap(Int32(line))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
      }
    }
  }

  func testCancellationStopsOwnedVMBeforeReturning() async throws {
    let root = try Files.temporary("polka-vm-cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try fixture(root)
    let config = try DesktopVM.Configuration(context: context)
    // Compiler startup is setup, not part of the cancellation/startup deadline.
    // Keep the real helper, but build it before the five-second expectation.
    let prepared = root.appendingPathComponent("prepared")
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try DesktopVM.compileDisplay(to: prepared, context: context)
    let started = expectation(description: "Guest operation started")
    let worker = Task {
      try await DesktopVM.withGuest(
        config, context: context,
        prepareDisplay: { destination, _ in
          try FileManager.default.copyItem(
            at: prepared.appendingPathComponent("prepare-display"),
            to: destination.appendingPathComponent("prepare-display"))
        }
      ) { _ in
        started.fulfill()
        try await Task.sleep(nanoseconds: 20_000_000_000)
      }
    }
    await fulfillment(of: [started], timeout: 5)
    worker.cancel()
    do {
      try await worker.value
      XCTFail("Cancelled run passed")
    } catch { XCTAssertTrue(error is CancellationError) }
    let pid = try Int32(
      String(contentsOf: root.appendingPathComponent("vm.pid"), encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines)
    ).unwrap()
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testRunningOrUnownedVMIsNeverTakenOver() async throws {
    let root = try Files.temporary("polka-vm-external")
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try fixture(root, running: true)
    let config = try DesktopVM.Configuration(context: context)
    do {
      try await DesktopVM.withGuest(config, context: context) { _ in XCTFail("Borrowed VM") }
      XCTFail("Accepted running VM")
    } catch { XCTAssertTrue(String(describing: error).contains("already running")) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("vm.pid").path))
    try FileManager.default.removeItem(at: config.owner)
    XCTAssertThrowsError(try DesktopVM.requireOwned(config))
  }
}

extension Optional {
  fileprivate func unwrap() throws -> Wrapped { try XCTUnwrap(self) }
}
