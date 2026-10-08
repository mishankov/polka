import Foundation

public enum Regression {
  public static func canonicalJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
  }
  public static func run(context: ToolContext, codeCoverage: Bool = false) throws {
    let corpus = context.root.appendingPathComponent("tests/fixtures/search-cases.json.gz")
    let decompressed = try Command.execute("/usr/bin/gunzip", ["-c", corpus.path])
    guard decompressed.status == 0,
      let cases = try JSONSerialization.jsonObject(with: decompressed.stdout) as? [[String: Any]]
    else { throw ToolError("Invalid feature corpus.") }
    var probe = context.environment["POLKA_CORE_PROBE"]
    if probe == nil {
      try Command.run(
        "swift",
        ["build", "--package-path", "native-app", "--product", "PolkaCoreProbe"]
          + (codeCoverage ? ["--enable-code-coverage"] : []),
        environment: context.environment, directory: context.root)
      let products = try Command.capture(
        "swift", ["build", "--package-path", "native-app", "--show-bin-path"],
        environment: context.environment, directory: context.root
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      probe = URL(fileURLWithPath: products).appendingPathComponent("PolkaCoreProbe").path
    }
    var input = Data()
    for item in cases {
      guard let request = item["request"] else { throw ToolError("Missing feature request.") }
      input.append(try canonicalJSON(request))
      input.append(10)
    }
    // Keep probe instrumentation out of the XCTest coverage data. The coverage
    // gate has already been exported, and the next test run must start fresh.
    let profiles = codeCoverage ? try Files.temporary("polka-regression-profiles") : nil
    defer { if let profiles { try? FileManager.default.removeItem(at: profiles) } }
    var environment = context.environment
    if let profiles {
      environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("probe-%p.profraw").path
    }
    let result = try Command.execute(
      probe!, environment: environment, directory: context.root, input: input)
    guard result.status == 0 else { throw ToolError("Feature probe failed (\(result.status)).") }
    let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count == cases.count else {
      throw ToolError("Expected one result per feature case.")
    }
    var failures: [[String: Any]] = []
    for (index, line) in lines.enumerated() {
      let actual = try JSONSerialization.jsonObject(
        with: Data(line.utf8), options: [.fragmentsAllowed])
      guard let expected = cases[index]["expected"] else {
        throw ToolError("Missing feature expectation.")
      }
      if try canonicalJSON(actual) != canonicalJSON(expected) {
        var failure = cases[index]
        failure["actual"] = actual
        failures.append(failure)
      }
    }
    if !failures.isEmpty {
      try Files.writeJSON(
        failures, to: context.root.appendingPathComponent("artifacts/search-failures.json"))
      throw ToolError(
        "\(failures.count)/\(cases.count) native feature regressions. See artifacts/search-failures.json."
      )
    }
    print(
      "Native feature regressions passed: \(cases.count) calculator, conversion, launcher and emoji cases."
    )
  }
}
