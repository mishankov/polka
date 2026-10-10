import CSQLite
import Foundation

/// Opens only the established settings table; legacy workspace tables are preserved.
public final class SettingsStore {
  private var db: OpaquePointer?
  private let lock = NSRecursiveLock()
  public init(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let status = sqlite3_open(root.appendingPathComponent("workspace.sqlite").path, &db)
    guard status == SQLITE_OK else {
      let error = failure()
      if let db { sqlite3_close(db) }
      db = nil
      throw error
    }
    do {
      try execute(
        "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);"
      )
    } catch {
      close()
      throw error
    }
  }
  deinit { close() }
  private func failure() -> Error {
    PolkaCoreError.storage(
      db.map { String(cString: sqlite3_errmsg($0)) } ?? localized("Settings storage is closed"))
  }
  private func execute(_ sql: String) throws {
    guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }
  private func prepared<T>(_ sql: String, operation: (OpaquePointer) throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    guard let db else { throw failure() }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw failure()
    }
    defer { sqlite3_finalize(statement) }
    return try operation(statement)
  }
  private func bind(_ value: String, at index: Int32, statement: OpaquePointer) throws {
    let status = value.withCString {
      sqlite3_bind_text(
        statement, index, $0, Int32(value.utf8.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard status == SQLITE_OK else { throw failure() }
  }
  private func decode(_ statement: OpaquePointer, column: Int32) throws -> Any {
    guard let text = sqlite3_column_text(statement, column) else { return NSNull() }
    return try JSONSerialization.jsonObject(
      with: Data(String(cString: text).utf8), options: [.fragmentsAllowed])
  }
  public func get(key: String) throws -> Any? {
    try prepared("SELECT value FROM settings WHERE key=?") { statement in
      try bind(key, at: 1, statement: statement)
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return nil }
      guard status == SQLITE_ROW else { throw failure() }
      return try decode(statement, column: 0)
    }
  }
  public func all() throws -> [String: Any] {
    try prepared("SELECT key,value FROM settings") { statement in
      var result: [String: Any] = [:]
      while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return result }
        guard status == SQLITE_ROW, let key = sqlite3_column_text(statement, 0) else {
          throw failure()
        }
        result[String(cString: key)] = try decode(statement, column: 1)
      }
    }
  }
  @discardableResult public func set(key: String, value: Any) throws -> Any {
    guard key.utf16.count <= 300,
      key.range(
        of: "secret|password|api[-_]?key|token", options: [.regularExpression, .caseInsensitive])
        == nil
    else { throw PolkaCoreError.invalid(localized("Secrets must be stored in secure storage")) }
    let data = try JSONSerialization.data(
      withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    guard let text = String(data: data, encoding: .utf8), text.utf16.count <= 10_000_000 else {
      throw PolkaCoreError.invalid(localized("Invalid settings"))
    }
    try prepared(
      "INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
    ) { statement in
      try bind(key, at: 1, statement: statement)
      try bind(text, at: 2, statement: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    return value
  }
  public func close() {
    lock.lock()
    defer { lock.unlock() }
    if let db {
      sqlite3_close(db)
      self.db = nil
    }
  }
}
