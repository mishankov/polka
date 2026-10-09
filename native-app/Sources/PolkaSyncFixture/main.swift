// Independent clipboard-sync wire peer. No production models, stores or transport
// are imported: JSON messages are built and checked directly at the protocol boundary.
import CryptoKit
import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

private struct FixtureError: Error { let message: String }
private func required<T>(_ value: Any?, _ type: T.Type = T.self) throws -> T {
  guard let result = value as? T else { throw FixtureError(message: "Invalid fixture input") }
  return result
}
private func base64URL(_ data: Data) -> String {
  data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
private func randomToken() -> String {
  base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
}
private func decodeURL(_ string: String) throws -> Data {
  var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
    of: "_", with: "/")
  value += String(repeating: "=", count: (4 - value.count % 4) % 4)
  guard let bytes = Data(base64Encoded: value) else {
    throw FixtureError(message: "Invalid invitation")
  }
  return bytes
}
private func fingerprint(_ certificate: NIOSSLCertificate) throws -> String {
  SHA256.hash(data: Data(try certificate.toDERBytes())).map { String(format: "%02X", $0) }.joined(
    separator: ":")
}
private func contentID(_ content: String) -> String {
  SHA256.hash(data: Data(("text\0" + content).utf8)).map { String(format: "%02x", $0) }.joined()
}
private func encode(_ value: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
private func emit(_ value: Any) throws {
  try FileHandle.standardOutput.write(contentsOf: encode(value) + Data([10]))
  fflush(stdout)
}
private func tlsConfiguration(_ input: [String: Any], server: Bool) throws -> TLSConfiguration {
  let cert = try NIOSSLCertificate(
    bytes: Array(required(input["cert"], String.self).utf8), format: .pem)
  let key = try NIOSSLPrivateKey(
    bytes: Array(required(input["key"], String.self).utf8), format: .pem)
  var configuration =
    server
    ? TLSConfiguration.makeServerConfiguration(
      certificateChain: [.certificate(cert)], privateKey: .privateKey(key))
    : TLSConfiguration.makeClientConfiguration()
  configuration.certificateChain = [.certificate(cert)]
  configuration.privateKey = .privateKey(key)
  configuration.minimumTLSVersion = .tlsv13
  configuration.maximumTLSVersion = .tlsv13
  configuration.certificateVerification = .noHostnameVerification
  configuration.applicationProtocols = ["http/1.1"]
  return configuration
}
private final class CertificateIdentity { var fingerprint = "" }
private final class PeerState {
  let id: String, name: String, invitation = randomToken()
  var peerID: String?, peerToken: String?, peerFingerprint: String?
  var clips: [String: [String: Any]] = [:], entries: [String: Any] = [:]
  init(_ configuration: [String: Any]) throws {
    id = try required(configuration["id"])
    name = try required(configuration["name"])
    let content = "Independent peer to native fixture"
    let clip = contentID(content)
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let stamp: [String: Any] = ["counter": now, "device": id]
    clips[clip] = [
      "id": clip, "kind": "text", "content": content, "preview": content, "createdAt": now,
      "pinned": false,
    ]
    entries[clip] = ["added": stamp, "pin": ["stamp": stamp, "value": false]]
  }
  func respond(_ head: HTTPRequestHead, bytes: Data, certificate: String, tls13: Bool) throws
    -> Data
  {
    guard !certificate.isEmpty, tls13 else {
      throw FixtureError(message: "Unauthenticated transport")
    }
    let id = head.headers.first(name: "x-polka-id") ?? ""
    let token = head.headers.first(name: "x-polka-token") ?? ""
    let body =
      bytes.isEmpty
      ? [:] : try required(JSONSerialization.jsonObject(with: bytes), [String: Any].self)
    let value: [String: Any]
    if head.method == .POST && head.uri == "/pair" {
      let newToken: String = try required(body["token"])
      guard peerID == nil, token == invitation, !id.isEmpty,
        newToken.range(of: #"^[A-Za-z0-9_-]{43}\z"#, options: .regularExpression) != nil
      else {
        throw FixtureError(message: "Invalid invitation")
      }
      peerID = id
      peerToken = newToken
      peerFingerprint = certificate
      value = ["id": self.id, "name": name]
    } else {
      guard peerID == id, peerToken == token, peerFingerprint == certificate else {
        throw FixtureError(message: "Untrusted peer")
      }
      if head.method == .GET && head.uri == "/manifest" {
        value = [
          "version": 1, "snippets": true, "entries": entries, "available": clips.keys.sorted(),
        ]
      } else if head.method == .GET && head.uri.hasPrefix("/clip/") {
        let key = String(head.uri.dropFirst(6))
        guard let clip = clips[key], let entry = entries[key] as? [String: Any],
          let stamp = entry["added"]
        else {
          throw FixtureError(message: "Unknown clip")
        }
        value = ["clip": clip, "stamp": stamp]
      } else if head.method == .POST && head.uri == "/manifest" {
        let other: [String: Any] = try required(body["entries"])
        for (key, entry) in other { entries[key] = entry }
        let available: [String] = try required(body["available"])
        value = ["missing": available.filter { clips[$0] == nil }]
      } else if head.method == .POST && head.uri == "/clip" {
        var clip: [String: Any] = try required(body["clip"])
        let key: String = try required(clip["id"])
        clips[key] = clip
        value = ["ok": true]
        if clip["content"] as? String == "Native to independent peer fixture" {
          clip["tls"] = "TLSv1.3"
          try emit(clip)
        }
      } else {
        throw FixtureError(message: "Unknown route")
      }
    }
    return try encode(value)
  }
}
private final class PeerHTTP: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let state: PeerState, identity: CertificateIdentity
  var head: HTTPRequestHead?, bytes = Data()
  init(state: PeerState, identity: CertificateIdentity) {
    self.state = state
    self.identity = identity
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let request): head = request
    case .body(var buffer):
      guard bytes.count + buffer.readableBytes <= 2_097_152 else {
        context.close(promise: nil)
        return
      }
      bytes.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
    case .end:
      let result: Data
      let status: HTTPResponseStatus
      do {
        guard let head else { throw FixtureError(message: "Missing request") }
        let tls13 = (try context.channel.pipeline.syncOperations.nioSSL_tlsVersion()) == .tlsv13
        result = try state.respond(
          head, bytes: bytes, certificate: identity.fingerprint, tls13: tls13)
        status = .ok
      } catch {
        result = Data("{}".utf8)
        status = .forbidden
      }
      var buffer = context.channel.allocator.buffer(capacity: result.count)
      buffer.writeBytes(result)
      let headers = HTTPHeaders([
        ("Content-Type", "application/json"), ("Content-Length", String(result.count)),
        ("Connection", "close"),
      ])
      context.write(
        wrapOutboundOut(
          .head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
        promise: nil)
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
      context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
        context.close(promise: nil)
      }
    }
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
private func serve(_ configuration: [String: Any], group: EventLoopGroup) throws {
  let state = try PeerState(configuration)
  let ssl = try NIOSSLContext(configuration: tlsConfiguration(configuration, server: true))
  let channel = try ServerBootstrap(group: group).childChannelInitializer { channel in
    let identity = CertificateIdentity()
    let tls = NIOSSLServerHandler(
      context: ssl,
      customVerificationCallback: { certificates, promise in
        guard let cert = certificates.first, let value = try? fingerprint(cert) else {
          promise.succeed(.failed)
          return
        }
        identity.fingerprint = value
        promise.succeed(.certificateVerified)
      })
    return channel.pipeline.addHandler(tls).flatMap {
      channel.pipeline.configureHTTPServerPipeline()
    }.flatMap { channel.pipeline.addHandler(PeerHTTP(state: state, identity: identity)) }
  }.bind(host: "127.0.0.1", port: 0).wait()
  let certificate = try NIOSSLCertificate(
    bytes: Array(required(configuration["cert"], String.self).utf8), format: .pem)
  let code: [String: Any] = [
    "version": 1, "id": state.id, "fingerprint": try fingerprint(certificate),
    "secret": state.invitation,
  ]
  try emit(["id": state.id, "port": channel.localAddress!.port!, "code": base64URL(encode(code))])
  try channel.closeFuture.wait()
}
private final class ClientHTTP: ChannelInboundHandler {
  typealias InboundIn = HTTPClientResponsePart
  typealias OutboundOut = HTTPClientRequestPart
  let head: HTTPRequestHead, body: Data?, promise: EventLoopPromise<Data>
  var bytes = Data(), complete = false
  init(head: HTTPRequestHead, body: Data?, promise: EventLoopPromise<Data>) {
    self.head = head
    self.body = body
    self.promise = promise
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
  func fail(_ error: Error) {
    if !complete {
      complete = true
      promise.fail(error)
    }
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let response):
      if response.status != .ok {
        fail(
          FixtureError(message: "Rejected HTTP request: \(head.uri) status \(response.status.code)")
        )
        context.close(promise: nil)
      }
    case .body(var buffer):
      guard bytes.count + buffer.readableBytes <= 2_097_152 else {
        fail(FixtureError(message: "Too much data"))
        context.close(promise: nil)
        return
      }
      bytes.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
    case .end:
      if !complete {
        complete = true
        promise.succeed(bytes)
      }
      context.close(promise: nil)
    }
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    fail(error)
    context.close(promise: nil)
  }
  func channelInactive(context: ChannelHandlerContext) {
    fail(FixtureError(message: "Peer disconnected"))
    context.fireChannelInactive()
  }
}
private func client(_ configuration: [String: Any], group: EventLoopGroup) throws {
  let code: [String: Any] = try required(
    JSONSerialization.jsonObject(with: decodeURL(required(configuration["code"], String.self))))
  let certificatePin: String = try required(code["fingerprint"])
  let invitation: String = try required(code["secret"])
  let token = randomToken()
  let id: String = try required(configuration["id"])
  let port: Int = try required(configuration["port"])
  let ssl = try NIOSSLContext(configuration: tlsConfiguration(configuration, server: false))
  func request(_ route: String, token: String, body: [String: Any]? = nil) throws -> [String: Any] {
    let encoded = try body.map(encode)
    let loop = group.next()
    let result = loop.makePromise(of: Data.self)
    let headers = HTTPHeaders([
      ("Host", "127.0.0.1"), ("Connection", "close"), ("Content-Type", "application/json"),
      ("Content-Length", String(encoded?.count ?? 0)), ("x-polka-id", id),
      ("x-polka-token", token), ("x-polka-snippets", "1"),
    ])
    let head = HTTPRequestHead(
      version: .http1_1, method: body == nil ? .GET : .POST, uri: route, headers: headers)
    let connection = try ClientBootstrap(group: loop).connectTimeout(.seconds(8)).channelInitializer
    { channel in
      do {
        let tls = try NIOSSLClientHandler(
          context: ssl, serverHostname: nil,
          customVerificationCallback: { certs, verified in
            guard let leaf = certs.first, (try? fingerprint(leaf)) == certificatePin else {
              verified.succeed(.failed)
              return
            }
            verified.succeed(.certificateVerified)
          })
        return channel.pipeline.addHandler(tls).flatMap { channel.pipeline.addHTTPClientHandlers() }
          .flatMap {
            channel.pipeline.addHandler(ClientHTTP(head: head, body: encoded, promise: result))
          }
      } catch { return channel.eventLoop.makeFailedFuture(error) }
    }.connect(host: "127.0.0.1", port: port).wait()
    let timer = loop.scheduleTask(in: .seconds(8)) { connection.close(promise: nil) }
    defer {
      timer.cancel()
      connection.close(promise: nil)
    }
    return try required(JSONSerialization.jsonObject(with: result.futureResult.wait()))
  }
  let paired = try request(
    "/pair", token: invitation, body: ["name": "Independent client fixture", "token": token])
  let initial = try request("/manifest", token: token)
  let content = "Independent client to native fixture"
  let clip = contentID(content)
  let now = Int64(Date().timeIntervalSince1970 * 1000)
  let stamp: [String: Any] = ["counter": now, "device": id]
  let merged = try request(
    "/manifest", token: token,
    body: [
      "version": 1, "snippets": true,
      "entries": [clip: ["added": stamp, "pin": ["stamp": stamp, "value": false]]],
      "available": [clip],
    ])
  guard (merged["missing"] as? [String])?.contains(clip) == true else {
    throw FixtureError(message: "Server did not request new content")
  }
  _ = try request(
    "/clip", token: token,
    body: [
      "clip": [
        "id": clip, "kind": "text", "content": content, "preview": content,
        "createdAt": now, "pinned": false, "ocr": "remote OCR must be ignored",
      ], "stamp": stamp,
    ])
  let response = try request("/clip/" + clip, token: token)
  let received: [String: Any] = try required(response["clip"])
  try emit([
    "paired": try required(paired["id"], String.self), "initial": initial["available"] ?? [],
    "content": try required(received["content"], String.self),
    "sourceDevice": received["sourceDevice"] ?? NSNull(), "hasOCR": received["ocr"] != nil,
  ])
}

private func main() throws {
  guard let line = readLine(), line.utf8.count <= 1_048_576 else {
    throw FixtureError(message: "Missing bounded fixture input")
  }
  let configuration: [String: Any] = try required(
    JSONSerialization.jsonObject(with: Data(line.utf8)))
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  defer { try? group.syncShutdownGracefully() }
  if CommandLine.arguments.dropFirst().first == "server" {
    try serve(configuration, group: group)
  } else if CommandLine.arguments.dropFirst().first == "client" {
    try client(configuration, group: group)
  } else {
    throw FixtureError(message: "Choose server or client fixture")
  }
}
do { try main() } catch {
  try? emit(["error": "Independent TLS fixture failed: \(error)"])
  exit(1)
}
