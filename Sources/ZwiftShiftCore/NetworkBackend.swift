import Darwin
import Foundation
import Network

private func localAddresses() -> Set<String> {
  var result: Set<String> = ["127.0.0.1", "::1"]
  var head: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&head) == 0 else { return result }
  defer { freeifaddrs(head) }
  var p = head
  while let current = p {
    defer { p = current.pointee.ifa_next }
    guard let address = current.pointee.ifa_addr,
      [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family))
    else { continue }
    var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    if getnameinfo(
      address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0,
      NI_NUMERICHOST) == 0
    {
      result.insert(
        String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
          .components(separatedBy: "%")[0])
    }
  }
  return result
}

@MainActor public final class NetworkBackend: NSObject, NetServiceDelegate {
  @MainActor private final class Client {
    let connection: NWConnection
    var decoder = FrameDecoder()
    var session: DirConSession
    var announcedReady = false
    init(_ connection: NWConnection, settings: Settings) {
      self.connection = connection
      session = DirConSession(identity: settings)
    }
  }
  private var listener: NWListener?
  private var listening = false
  private var advertisement: NetService?
  private var clients: [UUID: Client] = [:]
  private var keepalive: Timer?
  private var pressed: ShiftDirection?
  private let settings: Settings
  public var onEvent: ((String, String) -> Void)?
  public var onState: ((String, Int) -> Void)?
  public var readyCount: Int { clients.values.filter { $0.session.ready }.count }
  public var boundPort: UInt16? { listening ? listener?.port?.rawValue : nil }
  public init(settings: Settings) { self.settings = settings }

  public func start(advertise: Bool = true) throws {
    guard listener == nil else { return }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(
      using: parameters, on: NWEndpoint.Port(rawValue: settings.networkPort)!)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        guard let self else { return }
        switch state {
        case .ready:
          self.listening = true
          if advertise { self.publish() }
          self.onState?("advertising", 0)
          self.onEvent?(
            "info", "Listening for Zwift on port \(self.boundPort ?? self.settings.networkPort).")
        case .failed(let error):
          self.onEvent?("error", "Network listener failed: \(error)")
          self.stop()
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      MainActor.assumeIsolated { self?.accept(connection) }
    }
    listener.start(queue: .main)
    let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { if self?.pressed == nil { try? self?.sendButton(nil) } }
    }
    RunLoop.main.add(timer, forMode: .common)
    keepalive = timer
  }
  private func publish() {
    let service = NetService(
      domain: "local.", type: ZwiftWire.serviceType, name: settings.deviceName,
      port: Int32(settings.networkPort))
    service.delegate = self
    service.setTXTRecord(
      NetService.data(fromTXTRecord: [
        "mac-address": Data(settings.macAddress.utf8),
        "serial-number": Data(settings.serialNumber.utf8),
        "ble-service-uuids": Data("fc82,180d,180a,180f".utf8),
      ]))
    advertisement = service
    service.publish(options: .noAutoRename)
  }
  nonisolated public func netServiceDidPublish(_ sender: NetService) {
    let name = sender.name
    MainActor.assumeIsolated { onEvent?("info", "Advertising \(name) on this Mac’s network.") }
  }
  nonisolated public func netService(
    _ sender: NetService, didNotPublish errorDict: [String: NSNumber]
  ) {
    MainActor.assumeIsolated {
      onEvent?(
        "error", "Bonjour publication failed: \(errorDict). Check for another running instance.")
      stop()
    }
  }
  private func accept(_ connection: NWConnection) {
    guard case .hostPort(let host, _) = connection.endpoint,
      localAddresses().contains(String(describing: host).components(separatedBy: "%")[0]),
      clients.count < 4
    else {
      connection.cancel()
      onEvent?("warning", "Rejected a connection from outside this Mac or beyond the client limit.")
      return
    }
    let id = UUID()
    let client = Client(connection, settings: settings)
    clients[id] = client
    connection.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        guard let self else { return }
        switch state {
        case .ready:
          self.onEvent?("info", "Zwift opened a local device connection.")
          self.receive(id)
        case .failed(let error): self.remove(id, "Connection failed: \(error)")
        case .cancelled: self.remove(id, "Zwift disconnected.")
        default: break
        }
      }
    }
    connection.start(queue: .main)
    onState?(readyCount > 0 ? "connected" : "handshaking", readyCount)
  }
  private func receive(_ id: UUID) {
    guard let client = clients[id] else { return }
    client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, done, error in
      MainActor.assumeIsolated {
        guard let self, self.clients[id] != nil else { return }
        do {
          if let data {
            let previouslyReady = client.session.ready
            for frame in try client.decoder.append(data) {
              for response in try client.session.handle(frame) {
                try self.send(response, to: client)
              }
            }
            if client.session.ready && !client.announcedReady {
              client.announcedReady = true
              self.onEvent?(
                "info", "Zwift accepted the controller handshake and input capabilities.")
            }
            if !client.session.ready { client.announcedReady = false }
            if previouslyReady != client.session.ready {
              self.onState?(self.readyCount > 0 ? "connected" : "handshaking", self.readyCount)
            }
          }
          if done || error != nil {
            self.remove(id, error.map { "Connection ended: \($0)" } ?? "Zwift disconnected.")
          } else {
            self.receive(id)
          }
        } catch { self.remove(id, "Protocol error: \(error.localizedDescription)") }
      }
    }
  }
  private func send(_ frame: DirConFrame, to client: Client) throws {
    client.connection.send(
      content: try frame.encoded(),
      completion: .contentProcessed { [weak self, weak client] error in
        MainActor.assumeIsolated {
          if let error, let self, let client,
            let id = self.clients.first(where: { $0.value === client })?.key
          {
            self.remove(id, "Send failed: \(error)")
          }
        }
      })
  }
  public func sendButton(_ direction: ShiftDirection?) throws {
    let ready = clients.values.filter { $0.session.ready }
    guard !ready.isEmpty else {
      throw ShiftError.message("Zwift has not connected to the software controller.")
    }
    pressed = direction
    for client in ready {
      if let frame = client.session.notification(ZwiftWire.async, ZwiftWire.button(direction)) {
        try send(frame, to: client)
      }
    }
  }
  private func remove(_ id: UUID, _ reason: String) {
    guard let client = clients.removeValue(forKey: id) else { return }
    client.connection.cancel()
    onEvent?("info", reason)
    onState?(readyCount > 0 ? "connected" : listener == nil ? "stopped" : "advertising", readyCount)
  }
  public func stop() {
    keepalive?.invalidate()
    keepalive = nil
    advertisement?.stop()
    advertisement = nil
    listener?.cancel()
    listener = nil
    listening = false
    for client in clients.values {
      if let frame = client.session.notification(ZwiftWire.async, ZwiftWire.button(nil)),
        let bytes = try? frame.encoded()
      {
        let connection = client.connection
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
      } else {
        client.connection.cancel()
      }
    }
    clients.removeAll()
    onState?("stopped", 0)
  }
}
