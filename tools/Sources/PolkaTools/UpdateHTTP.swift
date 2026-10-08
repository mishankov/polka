import Foundation
import Network

/// Disposable localhost feed used by the actual Sparkle installation test.
final class UpdateHTTPServer: @unchecked Sendable {
  private let listener: NWListener, queue = DispatchQueue(label: "polka.tools.update-http")
  private let mutex = NSLock()
  private var feed = Data(), archive = Data(), active: [UUID: NWConnection] = [:]
  private var requests: [[String: Any]] = []
  let port: UInt16
  var origin: String { "http://127.0.0.1:\(port)" }
  var requestLog: [[String: Any]] {
    mutex.lock()
    defer { mutex.unlock() }
    return requests
  }
  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let starting = try NWListener(using: parameters)
    // Network requires a connection handler before start; the final handler
    // can capture self only after the bound port completes initialization.
    starting.newConnectionHandler = { $0.cancel() }
    let ready = DispatchSemaphore(value: 0)
    var failure: NWError?
    starting.stateUpdateHandler = { state in
      if case .ready = state {
        ready.signal()
      } else if case .failed(let error) = state {
        failure = error
        ready.signal()
      }
    }
    starting.start(queue: DispatchQueue(label: "polka.tools.update-listener"))
    guard ready.wait(timeout: .now() + 5) == .success else {
      starting.cancel()
      throw DesktopFailure("Local update server did not start")
    }
    if let failure {
      starting.cancel()
      throw failure
    }
    guard let bound = starting.port else {
      starting.cancel()
      throw DesktopFailure("Local update server has no port")
    }
    listener = starting
    port = bound.rawValue
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      let id = UUID()
      self.mutex.lock()
      self.active[id] = connection
      self.mutex.unlock()
      connection.stateUpdateHandler = { [weak self, weak connection] state in
        if case .cancelled = state {
          self?.remove(id)
        } else if case .failed = state {
          self?.remove(id)
          connection?.cancel()
        }
      }
      connection.start(queue: self.queue)
      self.receive(connection, id: id, buffer: Data())
    }
  }
  func set(feed: String, archive: Data) {
    mutex.lock()
    self.feed = Data(feed.utf8)
    self.archive = archive
    mutex.unlock()
  }
  private func remove(_ id: UUID) {
    mutex.lock()
    active.removeValue(forKey: id)
    mutex.unlock()
  }
  private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] bytes, _, complete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var data = buffer
      data.append(bytes ?? Data())
      guard data.count <= 32_768 else {
        connection.cancel()
        return
      }
      if let end = data.range(of: Data("\r\n\r\n".utf8)),
        let headers = String(data: data[..<end.lowerBound], encoding: .utf8),
        let first = headers.components(separatedBy: "\r\n").first
      {
        let fields = first.split(separator: " ")
        guard fields.count == 3, fields[0] == "GET" else {
          connection.cancel()
          return
        }
        let path = String(fields[1])
        self.mutex.lock()
        self.requests.append(["url": path, "at": Date().timeIntervalSince1970 * 1000])
        let body =
          path == "/appcast.xml" ? self.feed : path.hasSuffix(".zip") ? self.archive : Data()
        self.mutex.unlock()
        let status = path == "/appcast.xml" || path.hasSuffix(".zip") ? "200 OK" : "404 Not Found"
        let type = path == "/appcast.xml" ? "application/xml" : "application/octet-stream"
        let reply =
          Data(
            "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
              .utf8) + body
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
      } else if complete || error != nil {
        connection.cancel()
      } else {
        self.receive(connection, id: id, buffer: data)
      }
    }
  }
  func stop() {
    listener.cancel()
    mutex.lock()
    let connections = Array(active.values)
    active.removeAll()
    mutex.unlock()
    for connection in connections { connection.cancel() }
  }
}
