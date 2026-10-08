import Darwin
import Foundation
import PolkaTools

@main struct PolkaToolCLI {
  static func main() async {
    let task = Task {
      try await Automation.run(ToolRequest(Array(CommandLine.arguments.dropFirst())))
      try Task.checkCancellation()
    }
    let signals = [SIGINT, SIGTERM].map { value -> DispatchSourceSignal in
      signal(value, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
      source.setEventHandler {
        ToolCancellationRegistry.shared.cancel()
        task.cancel()
      }
      source.resume()
      return source
    }
    do {
      try await task.value
    } catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(error is CancellationError ? 130 : (error as? ToolError)?.exitCode ?? 1)
    }
    for source in signals { source.cancel() }
  }
}
