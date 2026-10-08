import Darwin
import Foundation

func emit(_ value: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
}

final class Discovery: NSObject, NetServiceDelegate, NetServiceBrowserDelegate {
  let ownID: String
  let publisher: NetService
  let browser = NetServiceBrowser()
  var services: [String: NetService] = [:]

  init(id: String, name: String, port: Int32) {
    ownID = id
    publisher = NetService(
      domain: "local.", type: "_everyclip._tcp.", name: "Everything-\(id)", port: port)
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
    emit(["type": "ready"])
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
    guard let previous = services.removeValue(forKey: service.name),
      let txt = previous.txtRecordData(),
      let id = NetService.dictionary(fromTXTRecord: txt)["id"],
      let value = String(data: id, encoding: .utf8)
    else { return }
    previous.stop()
    emit(["type": "down", "id": value])
  }
  func netServiceDidResolveAddress(_ service: NetService) {
    guard let data = service.txtRecordData() else { return }
    let txt = NetService.dictionary(fromTXTRecord: data)
    guard let idData = txt["id"], let id = String(data: idData, encoding: .utf8), id != ownID,
      let version = txt["version"], String(data: version, encoding: .utf8) == "1"
    else { return }
    let name = txt["name"].flatMap { String(data: $0, encoding: .utf8) } ?? "Mac"
    var addresses: [String] = []
    for data in service.addresses ?? [] {
      data.withUnsafeBytes { bytes in
        guard let address = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
          return
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
          address, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        {
          let value = String(cString: host)
          if address.pointee.sa_family == sa_family_t(AF_INET) {
            addresses.insert(value, at: 0)
          } else {
            addresses.append(value)
          }
        }
      }
    }
    guard let host = addresses.first, service.port > 0 else { return }
    emit(["type": "up", "id": id, "name": name, "host": host, "port": service.port])
  }
  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    emit([
      "type": "error",
      "message":
        "Не удалось объявить Mac в локальной сети. Проверьте разрешение macOS на доступ к локальной сети.",
    ])
  }
  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    emit([
      "type": "error",
      "message":
        "Не удалось найти Mac в локальной сети. Проверьте разрешение macOS на доступ к локальной сети.",
    ])
  }
}

guard CommandLine.arguments.count == 4, let port = Int32(CommandLine.arguments[3]), port > 0 else {
  exit(1)
}
let discovery = Discovery(id: CommandLine.arguments[1], name: CommandLine.arguments[2], port: port)
discovery.start()
RunLoop.main.run()
