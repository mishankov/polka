import CryptoKit
import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import PolkaCore
import X509

struct NativeNearbyPeer: Codable, Equatable, Identifiable {
  var id: String
  var name: String
}
struct NativeSyncPeer: Codable, Equatable, Identifiable {
  var id: String
  var name: String
  var status: String
  var lastSync: Double?
  var error: String?
}
struct NativeSyncInvitation: Codable, Equatable {
  var code: String
  var expiresAt: Double
}
struct NativeClipboardSyncState: Codable, Equatable {
  var enabled: Bool
  var status: String
  var storage: ClipboardStorageState
  var deviceName: String
  var nearby: [NativeNearbyPeer]
  var peers: [NativeSyncPeer]
  var invitation: NativeSyncInvitation?
  var error: String?
}
private struct TrustedPeer: Codable, Equatable {
  var id: String
  var name: String
  var token: String
  var fingerprint: String
  func validate() throws {
    guard validDeviceID(id), !name.isEmpty, name.utf16.count <= 100, validToken(token),
      validFingerprint(fingerprint)
    else { throw PolkaCoreError.invalid("Некорректные данные связанного Mac") }
  }
}
private struct SyncCredentials: Codable {
  var enabled: Bool
  var key: String
  var cert: String
  var peers: [TrustedPeer]
  func validate() throws {
    guard peers.count <= 32 else { throw PolkaCoreError.invalid("Слишком много устройств") }
    for peer in peers { try peer.validate() }
    _ = try NIOSSLCertificate(bytes: Array(cert.utf8), format: .pem)
    _ = try NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem)
  }
}
private struct PairCode: Codable {
  var version = 1
  var id: String
  var fingerprint: String
  var secret: String
  func validate() throws {
    guard version == 1, validDeviceID(id), validFingerprint(fingerprint),
      validToken(secret)
    else { throw PolkaCoreError.invalid("Некорректный код подключения") }
  }
}
private struct PairRequest: Codable {
  var name: String
  var token: String
}
private struct PairResponse: Codable {
  var id: String
  var name: String
}
private struct MissingResponse: Codable { var missing: [String] }
private struct SyncEndpoint {
  var name: String
  var host: String
  var port: Int
}
private let maxManifestBytes = 16 * 1024 * 1024
private let maxWireBytes = ClipboardLimits.maxClipBytes * 6 + 2 * 1024 * 1024
private func validToken(_ token: String) -> Bool {
  token.utf8.count == 43
    && token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
}
private func validFingerprint(_ value: String) -> Bool {
  value.range(of: "^(?:[A-F0-9]{2}:){31}[A-F0-9]{2}$", options: .regularExpression) != nil
}
private func timingSafeEqual(_ a: String, _ b: String) -> Bool {
  let a = Array(a.utf8)
  let b = Array(b.utf8)
  guard a.count == b.count else { return false }
  var difference: UInt8 = 0
  for index in a.indices { difference |= a[index] ^ b[index] }
  return difference == 0
}
private func base64URL(_ data: Data) -> String {
  data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
    of: "/", with: "_"
  ).replacingOccurrences(of: "=", with: "")
}
private func decodeBase64URL(_ value: String) -> Data? {
  var value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
    of: "_", with: "/")
  value += String(repeating: "=", count: (4 - value.count % 4) % 4)
  return Data(base64Encoded: value)
}
private func certificateFingerprint(_ certificate: NIOSSLCertificate) throws -> String {
  SHA256.hash(data: Data(try certificate.toDERBytes())).map { String(format: "%02X", $0) }.joined(
    separator: ":")
}
private final class FingerprintBox { var value = "" }

// The initializer and response handler share one completion gate. Initialization
// can fail before an HTTP handler exists, and channelInactive may race that error.
final class NativeSyncRequestResponse: @unchecked Sendable {
  let promise: EventLoopPromise<Data>
  private let lock = NSLock()
  private var completed = false
  init(loop: EventLoop) { promise = loop.makePromise(of: Data.self) }
  private func finish(_ action: () -> Void) {
    lock.lock()
    let finish = !completed
    completed = true
    lock.unlock()
    if finish { action() }
  }
  func succeed(_ value: Data) { finish { promise.succeed(value) } }
  func fail(_ error: Error) { finish { promise.fail(error) } }
  func initialize(
    loop: EventLoop, accepted: Bool,
    install: () throws -> EventLoopFuture<Void>
  ) -> EventLoopFuture<Void> {
    guard accepted else {
      let error = PolkaCoreError.invalid("Синхронизация остановлена")
      fail(error)
      return loop.makeFailedFuture(error)
    }
    do {
      return try install().flatMapError { error in
        self.fail(error)
        return loop.makeFailedFuture(error)
      }
    } catch {
      fail(error)
      return loop.makeFailedFuture(error)
    }
  }
}

/// Clipboard sync v1. PEM identities stay in encrypted sync.enc;
/// mutual certificate pins are verified during TLS 1.3 before HTTP application bytes.
final class NativeClipboardSync: @unchecked Sendable {
  private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  private let path: URL
  private let codec: EncryptionCodec
  private let history: ClipboardHistory
  private let changed: () -> Void
  private let discoveryEnabled: Bool
  private let lock = NSRecursiveLock()
  private var credentials: SyncCredentials?
  private var server: Channel?
  private var connections: [ObjectIdentifier: Channel] = [:]
  private var serverConnections = Set<ObjectIdentifier>()
  private var nearby: [String: SyncEndpoint] = [:]
  private var statuses: [String: NativeSyncPeer] = [:]
  private var invitation: (secret: String, expiresAt: Double)?
  private var timer: DispatchSourceTimer?
  private var discovery: NativeSyncDiscovery?
  private var stopped = false
  private var errorMessage: String?
  private var exchangeTask: Task<Void, Never>?
  private var lifecycleGeneration = 0
  let storage: ClipboardStorage
  let deviceName: String
  init(
    path: URL, codec: EncryptionCodec, history: ClipboardHistory, name: String? = nil,
    discovery: Bool = true, changed: @escaping () -> Void = {}
  ) {
    self.path = path
    self.codec = codec
    self.history = history
    self.changed = changed
    self.discoveryEnabled = discovery
    deviceName = String(
      decoding: (name ?? Host.current().localizedName ?? "Mac").utf16.prefix(100), as: UTF16.self)
    storage = ClipboardStorage(path: path, changed: changed)
  }
  private func synchronized<T>(_ block: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try block()
  }
  private func notify() { changed() }
  var port: Int { synchronized { server?.localAddress?.port ?? 0 } }
  func state() -> NativeClipboardSyncState {
    synchronized {
      let historyStatus = history.storage.state().status
      let status: String =
        historyStatus == .failed
        ? "blocked"
        : historyStatus != .ready
          ? "starting"
          : storage.state().status == .failed || errorMessage != nil
            ? "failed"
            : !storage.ready
              ? "starting"
              : credentials?.enabled != true
                ? "disabled" : history.getPreferences().paused ? "paused" : "active"
      var displayInvitation: NativeSyncInvitation?
      if let invitation, invitation.expiresAt > Date().timeIntervalSince1970 * 1000,
        let credentials,
        let cert = try? NIOSSLCertificate(bytes: Array(credentials.cert.utf8), format: .pem),
        let fingerprint = try? certificateFingerprint(cert),
        let bytes = try? JSONEncoder().encode(
          PairCode(id: history.deviceId, fingerprint: fingerprint, secret: invitation.secret))
      {
        displayInvitation = NativeSyncInvitation(
          code: base64URL(bytes), expiresAt: invitation.expiresAt)
      }
      return NativeClipboardSyncState(
        enabled: credentials?.enabled ?? false, status: status, storage: storage.state(),
        deviceName: deviceName,
        nearby: nearby.filter { id, _ in !(credentials?.peers.contains { $0.id == id } ?? false) }
          .map { NativeNearbyPeer(id: $0.key, name: $0.value.name) }.sorted { $0.name < $1.name },
        peers: (credentials?.peers ?? []).map {
          statuses[$0.id] ?? NativeSyncPeer(id: $0.id, name: $0.name, status: "offline")
        }, invitation: displayInvitation, error: errorMessage)
    }
  }
  private func requireReady() throws {
    try history.storage.requireReady()
    try storage.requireReady()
  }
  func initialize() async throws {
    do {
      try synchronized {
        try history.storage.requireReady()
        let data: Data? = try storage.run("read") {
          try readEncryptedFile(path, maximumBytes: 2 * 1024 * 1024)
        }
        if let data {
          let decoded = try storage.run("decrypt") { try codec.decode(data) }
          credentials = try storage.run("parse") {
            let value = try decodeClipboardJSON(SyncCredentials.self, from: decoded)
            try value.validate()
            return value
          }
        } else {
          credentials = try Self.generateCredentials()
        }
        try history.persistIdentity()
        try storage.loaded()
        if data == nil { try mutate { _ in } }
      }
      if synchronized({ credentials?.enabled == true }) { try await open() }
    } catch {
      synchronized {
        if history.storage.ready && storage.state().status != .failed {
          errorMessage = error.localizedDescription
        }
      }
      await close()
      throw error
    }
  }
  private static func generateCredentials() throws -> SyncCredentials {
    let key = P256.Signing.PrivateKey()
    let name = try DistinguishedName { CommonName("Everything clipboard sync") }
    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(
        bytes: (0..<16).map { _ in UInt8.random(in: 0...255) }),
      publicKey: Certificate.PublicKey(key.publicKey),
      notValidBefore: Date().addingTimeInterval(-300),
      notValidAfter: Date(timeIntervalSince1970: 2_398_377_600), issuer: name, subject: name,
      signatureAlgorithm: .ecdsaWithSHA256, extensions: Certificate.Extensions {},
      issuerPrivateKey: Certificate.PrivateKey(key))
    return SyncCredentials(
      enabled: false, key: key.pemRepresentation, cert: try certificate.serializeAsPEM().pemString,
      peers: [])
  }
  private func mutate(_ block: (inout SyncCredentials) throws -> Void) throws {
    try synchronized {
      try requireReady()
      guard var next = credentials else {
        throw PolkaCoreError.invalid("Синхронизация ещё не готова")
      }
      try block(&next)
      try next.validate()
      let encrypted = try storage.run("encrypt") { try codec.encode(JSONEncoder().encode(next)) }
      try storage.run("write") {
        try FileManager.default.createDirectory(
          at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        let temp = path.appendingPathExtension("tmp")
        do {
          try encrypted.write(to: temp)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
          guard rename(temp.path, path.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
          }
        } catch {
          try? FileManager.default.removeItem(at: temp)
          throw error
        }
      }
      credentials = next
      notify()
    }
  }
  func setEnabled(_ enabled: Bool) async throws {
    do {
      try mutate { $0.enabled = enabled }
      if enabled {
        synchronized { stopped = false }
        try await open()
      } else {
        await close()
      }
    } catch {
      synchronized {
        if storage.state().status != .failed { errorMessage = error.localizedDescription }
      }
      await close()
      throw error
    }
  }
  func invite() throws {
    try synchronized {
      try requireReady()
      guard server != nil, credentials?.enabled == true else {
        throw PolkaCoreError.invalid("Сначала включите синхронизацию")
      }
      guard credentials!.peers.count < 32 else {
        throw PolkaCoreError.invalid("Можно связать не больше 32 устройств")
      }
      invitation = (
        base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) })),
        Date().timeIntervalSince1970 * 1000 + 5 * 60_000
      )
      notify()
    }
  }
  func cancelInvite() {
    synchronized {
      invitation = nil
      notify()
    }
  }
  func forget(_ id: String) async throws {
    do {
      try mutate { $0.peers.removeAll { $0.id == id } }
      synchronized {
        statuses.removeValue(forKey: id)
        notify()
      }
    } catch {
      if !storage.ready { await close() }
      throw error
    }
  }
  private func configuration(_ credentials: SyncCredentials, server: Bool) throws
    -> TLSConfiguration
  {
    let certificate = try NIOSSLCertificate(bytes: Array(credentials.cert.utf8), format: .pem)
    let key = try NIOSSLPrivateKey(bytes: Array(credentials.key.utf8), format: .pem)
    var config =
      server
      ? TLSConfiguration.makeServerConfiguration(
        certificateChain: [.certificate(certificate)], privateKey: .privateKey(key))
      : TLSConfiguration.makeClientConfiguration()
    config.certificateChain = [.certificate(certificate)]
    config.privateKey = .privateKey(key)
    config.minimumTLSVersion = .tlsv13
    config.certificateVerification = .noHostnameVerification
    config.applicationProtocols = ["http/1.1"]
    return config
  }
  private func open() async throws {
    let opening: (SyncCredentials, Int)? = try synchronized {
      try requireReady()
      if server != nil { return nil }
      errorMessage = nil
      stopped = false
      lifecycleGeneration += 1
      return (credentials!, lifecycleGeneration)
    }
    guard let (creds, epoch) = opening else { return }
    let context = try NIOSSLContext(configuration: configuration(creds, server: true))
    let channel = try await ServerBootstrap(group: Self.group).serverChannelOption(
      ChannelOptions.backlog, value: 16
    ).childChannelInitializer { [weak self] channel in
      let box = FingerprintBox()
      let tls = NIOSSLServerHandler(
        context: context,
        customVerificationCallback: { chain, promise in
          guard let leaf = chain.first, let fingerprint = try? certificateFingerprint(leaf) else {
            promise.succeed(.failed)
            return
          }
          box.value = fingerprint
          promise.succeed(.certificateVerified)
        })
      guard self?.track(channel, isServer: true, generation: epoch) == true else {
        return channel.close()
      }
      do { try channel.pipeline.syncOperations.addHandler(tls) } catch {
        return channel.eventLoop.makeFailedFuture(error)
      }
      return channel.pipeline.configureHTTPServerPipeline().flatMap {
        channel.pipeline.addHandler(SyncServerHandler(owner: self, fingerprint: box))
      }
    }.bind(host: "::", port: 0).get()
    let installed = synchronized { () -> Bool in
      guard !stopped, credentials?.enabled == true, lifecycleGeneration == epoch, server == nil
      else { return false }
      server = channel
      return true
    }
    guard installed else {
      try? await channel.close().get()
      return
    }
    if discoveryEnabled {
      await MainActor.run {
        synchronized {
          guard !stopped, lifecycleGeneration == epoch, server === channel else { return }
          let d = NativeSyncDiscovery(
            id: history.deviceId, name: deviceName, port: Int32(port),
            up: { [weak self] id, name, host, port in
              self?.discover(id: id, name: name, host: host, port: port)
            },
            down: { [weak self] id in
              self?.synchronized {
                self?.nearby.removeValue(forKey: id)
                self?.statuses[id]?.status = "offline"
                self?.notify()
              }
            },
            failed: { [weak self] message in
              self?.synchronized {
                self?.errorMessage = message
                self?.notify()
              }
            })
          discovery = d
          d.start()
        }
      }
    }
    synchronized {
      guard !stopped, lifecycleGeneration == epoch, server === channel else { return }
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
      timer.schedule(deadline: .now() + 3, repeating: 3)
      timer.setEventHandler { [weak self] in
        Task {
          await self?.syncNow()
          self?.notify()
        }
      }
      self.timer = timer
      timer.resume()
      notify()
    }
  }
  @discardableResult private func track(
    _ channel: Channel, isServer: Bool = false, generation: Int? = nil
  ) -> Bool {
    let accepted = synchronized { () -> Bool in
      guard !stopped, credentials?.enabled == true,
        generation == nil || generation == lifecycleGeneration
      else { return false }
      if isServer && serverConnections.count >= 16 { return false }
      let id = ObjectIdentifier(channel)
      connections[id] = channel
      if isServer { serverConnections.insert(id) }
      return true
    }
    guard accepted else { return false }
    channel.closeFuture.whenComplete { [weak self, weak channel] _ in
      guard let channel else { return }
      self?.synchronized {
        let id = ObjectIdentifier(channel)
        self?.connections.removeValue(forKey: id)
        self?.serverConnections.remove(id)
      }
    }
    return true
  }
  func discover(id: String, name: String, host: String, port: Int) {
    guard validDeviceID(id), id != history.deviceId, name.utf16.count <= 100,
      host.utf16.count <= 200, (1...65535).contains(port),
      (try? SocketAddress(ipAddress: host, port: port)) != nil
    else { return }
    synchronized {
      guard nearby.count < 128 || nearby[id] != nil else { return }
      nearby[id] = SyncEndpoint(name: name, host: host, port: port)
      notify()
    }
    Task { await syncNow() }
  }
  fileprivate func serve(head: HTTPRequestHead, data: Data, fingerprint: String) throws -> Data {
    try synchronized {
      try requireReady()
      guard !stopped, credentials?.enabled == true, validFingerprint(fingerprint) else {
        throw PolkaCoreError.invalid("Синхронизация отключена")
      }
      let id = head.headers.first(name: "x-everything-id") ?? ""
      let token = head.headers.first(name: "x-everything-token") ?? ""
      if head.method == .POST && head.uri == "/pair" {
        guard let invite = invitation, invite.expiresAt > Date().timeIntervalSince1970 * 1000,
          timingSafeEqual(token, invite.secret)
        else { throw PolkaCoreError.invalid("Код недействителен") }
        invitation = nil
        notify()
        let body = try decodeClipboardJSON(PairRequest.self, from: data)
        let incoming = TrustedPeer(
          id: id, name: body.name, token: body.token, fingerprint: fingerprint)
        try incoming.validate()
        guard id != history.deviceId else { throw PolkaCoreError.invalid("Это тот же Mac") }
        try mutate { next in
          guard next.peers.count < 32 else {
            throw PolkaCoreError.invalid("Слишком много устройств")
          }
          next.peers.removeAll { $0.id == id }
          next.peers.append(incoming)
        }
        return try JSONEncoder().encode(PairResponse(id: history.deviceId, name: deviceName))
      }
      guard let peer = credentials?.peers.first(where: { $0.id == id }),
        timingSafeEqual(peer.token, token), timingSafeEqual(peer.fingerprint, fingerprint),
        !history.getPreferences().paused
      else { throw PolkaCoreError.invalid("Устройство не связано или история на паузе") }
      let snippets = head.headers.first(name: "x-everything-snippets") == "1"
      if head.method == .GET && head.uri == "/manifest" {
        try history.prune()
        return try JSONEncoder().encode(history.manifest(snippets: snippets))
      }
      if head.method == .GET && head.uri.hasPrefix("/clip/") {
        let id = String(head.uri.dropFirst(6))
        guard validClipID(id) else { throw PolkaCoreError.invalid("Некорректный идентификатор") }
        if let clip = transfer(id, snippets: snippets) { return try JSONEncoder().encode(clip) }
        return Data("null".utf8)
      }
      if head.method == .POST && head.uri == "/manifest" {
        let input = try decodeClipboardJSON(SyncManifest.self, from: data)
        return try JSONEncoder().encode(MissingResponse(missing: history.mergeManifest(input)))
      }
      if head.method == .POST && head.uri == "/clip" {
        let input = try decodeClipboardJSON(ClipTransfer.self, from: data)
        try history.receive(input, sourceDevice: peer.name)
        return Data("{\"ok\":true}".utf8)
      }
      throw PolkaCoreError.invalid("Неизвестная операция")
    }
  }
  private func request(peer: TrustedPeer, route: String, body: Data? = nil) async throws -> Data {
    let (endpoint, creds, epoch): (SyncEndpoint, SyncCredentials, Int) = try synchronized {
      try requireReady()
      guard !stopped, let endpoint = nearby[peer.id], let credentials else {
        throw PolkaCoreError.invalid("Mac не найден в локальной сети")
      }
      return (endpoint, credentials, lifecycleGeneration)
    }
    let sslContext = try NIOSSLContext(configuration: configuration(creds, server: false))
    let loop = Self.group.next()
    let response = NativeSyncRequestResponse(loop: loop)
    let headers = HTTPHeaders([
      ("Content-Type", "application/json"), ("x-everything-snippets", "1"),
      ("x-everything-id", history.deviceId), ("x-everything-token", peer.token),
      ("Host", endpoint.host), ("Connection", "close"),
      ("Content-Length", String(body?.count ?? 0)),
    ])
    let request = HTTPRequestHead(
      version: .http1_1, method: body == nil ? .GET : .POST, uri: route, headers: headers)
    let channel = try await ClientBootstrap(group: loop).connectTimeout(.seconds(30))
      .channelInitializer { channel in
        return response.initialize(loop: loop, accepted: self.track(channel, generation: epoch)) {
          let tls = try NIOSSLClientHandler(
            context: sslContext, serverHostname: nil,
            customVerificationCallback: { chain, result in
              guard let leaf = chain.first, let fingerprint = try? certificateFingerprint(leaf),
                timingSafeEqual(fingerprint, peer.fingerprint)
              else {
                result.succeed(.failed)
                return
              }
              result.succeed(.certificateVerified)
            })
          try channel.pipeline.syncOperations.addHandler(tls)
          return channel.pipeline.addHTTPClientHandlers().flatMap {
            channel.pipeline.addHandler(
              SyncClientHandler(
                head: request, body: body,
                limit: route.hasPrefix("/clip/") ? maxWireBytes : maxManifestBytes,
                response: response
              ))
          }
        }
      }.connect(host: endpoint.host, port: endpoint.port).flatMapError { error in
        response.fail(error)
        return loop.makeFailedFuture(error)
      }.get()
    guard track(channel, generation: epoch) else {
      response.fail(PolkaCoreError.invalid("Синхронизация остановлена"))
      try? await channel.close().get()
      throw PolkaCoreError.invalid("Синхронизация остановлена")
    }
    let timeout = channel.eventLoop.scheduleTask(in: .seconds(30)) { channel.close(promise: nil) }
    defer {
      timeout.cancel()
      channel.close(promise: nil)
    }
    return try await response.promise.futureResult.get()
  }
  func pair(_ code: String) async throws {
    try synchronized {
      try requireReady()
      guard server != nil, credentials?.enabled == true else {
        throw PolkaCoreError.invalid("Сначала включите синхронизацию")
      }
      guard credentials!.peers.count < 32 else {
        throw PolkaCoreError.invalid("Можно связать не больше 32 устройств")
      }
    }
    let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard code.utf16.count <= 2048, let bytes = decodeBase64URL(code) else {
      throw PolkaCoreError.invalid("Некорректный код подключения")
    }
    let invite = try decodeClipboardJSON(PairCode.self, from: bytes)
    try invite.validate()
    guard invite.id != history.deviceId else {
      throw PolkaCoreError.invalid("Введите код с другого Mac")
    }
    let token = base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    let response = try decodeClipboardJSON(
      PairResponse.self,
      from: await request(
        peer: TrustedPeer(
          id: invite.id, name: "Mac", token: invite.secret, fingerprint: invite.fingerprint),
        route: "/pair", body: JSONEncoder().encode(PairRequest(name: deviceName, token: token))))
    guard response.id == invite.id else { throw PolkaCoreError.invalid("Неверное устройство") }
    do {
      try synchronized {
        guard !stopped, credentials?.enabled == true else {
          throw PolkaCoreError.invalid("Синхронизация отключена")
        }
        try mutate { next in
          next.peers.removeAll { $0.id == response.id }
          next.peers.append(
            TrustedPeer(
              id: response.id, name: response.name, token: token, fingerprint: invite.fingerprint))
        }
      }
    } catch {
      if !storage.ready { await close() }
      throw error
    }
    await syncNow()
  }
  private func active(_ peer: TrustedPeer) -> Bool {
    synchronized {
      !stopped && storage.ready && history.storage.ready && credentials?.enabled == true
        && !history.getPreferences().paused
        && (credentials?.peers.contains {
          $0.id == peer.id && timingSafeEqual($0.token, peer.token)
        } ?? false)
    }
  }
  private func transfer(_ id: String, snippets: Bool = true) -> ClipTransfer? {
    guard var value = history.transfer(id), snippets || !value.clip.isSnippet else { return nil }
    if value.clip.sourceDevice == nil { value.clip.sourceDevice = deviceName }
    return value
  }
  func syncNow() async {
    let task: Task<Void, Never>? = synchronized {
      if let exchangeTask { return exchangeTask }
      guard storage.ready, history.storage.ready, !stopped,
        credentials?.enabled == true, !history.getPreferences().paused
      else { return nil }
      let task = Task { [weak self] in
        guard let self else { return }
        await self.exchange()
        self.synchronized {
          self.exchangeTask = nil
          self.notify()
        }
      }
      exchangeTask = task
      return task
    }
    await task?.value
  }
  private func exchange() async {
    let peers = synchronized { credentials?.peers ?? [] }
    do {
      try history.prune()
      for peer in peers where synchronized({ nearby[peer.id] != nil }) {
        synchronized {
          statuses[peer.id] = NativeSyncPeer(
            id: peer.id, name: peer.name, status: "syncing", lastSync: statuses[peer.id]?.lastSync)
          notify()
        }
        do {
          let manifest = try decodeClipboardJSON(
            SyncManifest.self, from: await request(peer: peer, route: "/manifest"))
          guard active(peer) else { continue }
          for id in try history.mergeManifest(manifest) {
            guard active(peer) else { break }
            let bytes = try await request(peer: peer, route: "/clip/\(id)")
            if bytes != Data("null".utf8), active(peer) {
              try history.receive(
                decodeClipboardJSON(ClipTransfer.self, from: bytes), sourceDevice: peer.name)
            }
          }
          guard active(peer) else { continue }
          let response = try decodeClipboardJSON(
            MissingResponse.self,
            from: await request(
              peer: peer, route: "/manifest",
              body: JSONEncoder().encode(history.manifest(snippets: manifest.snippets == true))))
          guard response.missing.count <= 400, response.missing.allSatisfy(validClipID) else {
            throw PolkaCoreError.invalid("Некорректный ответ синхронизации")
          }
          for id in response.missing {
            guard active(peer) else { break }
            if let value = transfer(id, snippets: manifest.snippets == true) {
              _ = try await request(peer: peer, route: "/clip", body: JSONEncoder().encode(value))
            }
          }
          if active(peer) {
            synchronized {
              statuses[peer.id] = NativeSyncPeer(
                id: peer.id, name: peer.name, status: "connected",
                lastSync: Date().timeIntervalSince1970 * 1000)
            }
          }
        } catch {
          if active(peer) {
            synchronized {
              statuses[peer.id] = NativeSyncPeer(
                id: peer.id, name: peer.name, status: "offline",
                lastSync: statuses[peer.id]?.lastSync, error: error.localizedDescription)
            }
          }
        }
        notify()
      }
    } catch {
      synchronized {
        errorMessage = error.localizedDescription
        notify()
      }
      if !history.storage.ready || !storage.ready { await close() }
    }
  }
  private func close() async {
    let (server, connections, discovery): (Channel?, [Channel], NativeSyncDiscovery?) = synchronized
    {
      stopped = true
      lifecycleGeneration += 1
      timer?.cancel()
      timer = nil
      invitation = nil
      let s = self.server
      self.server = nil
      let c = Array(self.connections.values)
      self.connections = [:]
      serverConnections = []
      let d = self.discovery
      self.discovery = nil
      nearby = [:]
      statuses = [:]
      return (s, c, d)
    }
    if let discovery { await MainActor.run { discovery.stop() } }
    for channel in connections { try? await channel.close().get() }
    if let server { try? await server.close().get() }
    notify()
  }
  func stop() async {
    await close()
    let pending = synchronized { exchangeTask }
    await pending?.value
  }
}

private final class SyncServerHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  weak var owner: NativeClipboardSync?
  let fingerprint: FingerprintBox
  var head: HTTPRequestHead?
  var bytes = Data()
  var timer: Scheduled<Void>?
  init(owner: NativeClipboardSync?, fingerprint: FingerprintBox) {
    self.owner = owner
    self.fingerprint = fingerprint
  }
  func channelActive(context: ChannelHandlerContext) {
    timer = context.eventLoop.scheduleTask(in: .seconds(10)) { context.close(promise: nil) }
    context.fireChannelActive()
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let value):
      guard head == nil else {
        context.close(promise: nil)
        return
      }
      head = value
      timer?.cancel()
      timer = context.eventLoop.scheduleTask(in: .seconds(30)) { context.close(promise: nil) }
    case .body(var buffer):
      let limit =
        head?.uri == "/pair" ? 4096 : head?.uri == "/manifest" ? maxManifestBytes : maxWireBytes
      guard bytes.count + buffer.readableBytes <= limit else {
        context.close(promise: nil)
        return
      }
      if let chunk = buffer.readBytes(length: buffer.readableBytes) {
        bytes.append(contentsOf: chunk)
      }
    case .end:
      guard let head else {
        context.close(promise: nil)
        return
      }
      let result: Data
      let status: HTTPResponseStatus
      do {
        guard let owner else { throw PolkaCoreError.invalid("Синхронизация отключена") }
        result = try owner.serve(head: head, data: bytes, fingerprint: fingerprint.value)
        status = .ok
      } catch {
        result = Data("{}".utf8)
        status = .forbidden
      }
      var buffer = context.channel.allocator.buffer(capacity: result.count)
      buffer.writeBytes(result)
      let response = HTTPResponseHead(
        version: .http1_1, status: status,
        headers: HTTPHeaders([
          ("Content-Type", "application/json"), ("Content-Length", String(result.count)),
          ("Connection", "close"),
        ]))
      context.write(wrapOutboundOut(.head(response)), promise: nil)
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
      context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
        context.close(promise: nil)
      }
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    timer?.cancel()
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
private final class SyncClientHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPClientResponsePart
  typealias OutboundOut = HTTPClientRequestPart
  let head: HTTPRequestHead
  let body: Data?
  let limit: Int
  let response: NativeSyncRequestResponse
  var bytes = Data()
  init(head: HTTPRequestHead, body: Data?, limit: Int, response: NativeSyncRequestResponse) {
    self.head = head
    self.body = body
    self.limit = limit
    self.response = response
  }
  func channelActive(context: ChannelHandlerContext) {
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    if let body {
      var buffer = context.channel.allocator.buffer(capacity: body.count)
      buffer.writeBytes(body)
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    context.fireChannelActive()
  }
  private func fail(_ error: Error) {
    response.fail(error)
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      guard head.status == .ok else {
        fail(
          PolkaCoreError.invalid(
            "Mac отклонил соединение. Проверьте синхронизацию и паузу истории."))
        context.close(promise: nil)
        return
      }
    case .body(var buffer):
      guard bytes.count + buffer.readableBytes <= limit else {
        fail(PolkaCoreError.invalid("Слишком большой ответ синхронизации"))
        context.close(promise: nil)
        return
      }
      if let value = buffer.readBytes(length: buffer.readableBytes) {
        bytes.append(contentsOf: value)
      }
    case .end:
      response.succeed(bytes)
      context.close(promise: nil)
    }
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    fail(error)
    context.close(promise: nil)
  }
  func channelInactive(context: ChannelHandlerContext) {
    fail(PolkaCoreError.invalid("Mac не отвечает"))
    context.fireChannelInactive()
  }
}

private final class NativeSyncDiscovery: NSObject, NetServiceDelegate, NetServiceBrowserDelegate {
  let ownID: String
  let publisher: NetService
  let browser = NetServiceBrowser()
  var services: [String: NetService] = [:]
  let up: (String, String, String, Int) -> Void
  let down: (String) -> Void
  let failed: (String) -> Void
  init(
    id: String, name: String, port: Int32, up: @escaping (String, String, String, Int) -> Void,
    down: @escaping (String) -> Void, failed: @escaping (String) -> Void
  ) {
    ownID = id
    publisher = NetService(
      domain: "local.", type: "_everyclip._tcp.", name: "Everything-\(id)", port: port)
    self.up = up
    self.down = down
    self.failed = failed
    super.init()
    publisher.delegate = self
    publisher.setTXTRecord(
      NetService.data(fromTXTRecord: [
        "id": Data(id.utf8), "name": Data(name.utf8), "version": Data("1".utf8),
      ]))
    browser.delegate = self
  }
  func start() {
    publisher.publish()
    browser.searchForServices(ofType: "_everyclip._tcp.", inDomain: "local.")
  }
  func stop() {
    browser.stop()
    publisher.stop()
    for service in services.values { service.stop() }
    services = [:]
  }
  func netServiceBrowser(
    _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
  ) {
    guard service.name != publisher.name else { return }
    services[service.name] = service
    service.delegate = self
    service.resolve(withTimeout: 10)
  }
  func netServiceBrowser(
    _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool
  ) {
    guard let previous = services.removeValue(forKey: service.name) else { return }
    previous.stop()
    if let txt = previous.txtRecordData(),
      let bytes = NetService.dictionary(fromTXTRecord: txt)["id"],
      let id = String(data: bytes, encoding: .utf8)
    {
      down(id)
    }
  }
  func netServiceDidResolveAddress(_ service: NetService) {
    guard let data = service.txtRecordData() else { return }
    let txt = NetService.dictionary(fromTXTRecord: data)
    guard let bytes = txt["id"], let id = String(data: bytes, encoding: .utf8),
      validDeviceID(id), id != ownID, let version = txt["version"],
      version == Data("1".utf8), service.port > 0
    else { return }
    let name = txt["name"].flatMap { String(data: $0, encoding: .utf8) } ?? "Mac"
    var addresses: [String] = []
    for data in service.addresses ?? [] {
      data.withUnsafeBytes { buffer in
        guard let address = buffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
          return
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
          address, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        {
          if address.pointee.sa_family == sa_family_t(AF_INET) {
            addresses.insert(String(cString: host), at: 0)
          } else if address.pointee.sa_family == sa_family_t(AF_INET6) {
            addresses.append(String(cString: host))
          }
        }
      }
    }
    if let host = addresses.first { up(id, name, host, service.port) }
  }
  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    failed(
      "Не удалось объявить Mac в локальной сети. Проверьте разрешение macOS на доступ к локальной сети."
    )
  }
  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    failed(
      "Не удалось найти Mac в локальной сети. Проверьте разрешение macOS на доступ к локальной сети."
    )
  }
}
