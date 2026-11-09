import Darwin
import Foundation
import Network

@MainActor public final class PhoneControl {
  public private(set) var status = PhoneStatus()
  public var onUpdate: ((PhoneStatus) -> Void)?
  private let paths: RuntimePaths
  private let server = PhoneHTTPServer()
  private let tunnel: NgrokTunnel
  private let router: PhoneRouter
  private var settings: PhoneSettings
  private var monitor: NWPathMonitor?
  private var file: URL { paths.directory.appendingPathComponent("phone.json") }

  init(
    paths: RuntimePaths, readStatus: @escaping () -> ServiceStatus,
    shift: @escaping (ShiftDirection, @escaping (RPCResponse) -> Void) -> Void
  ) throws {
    self.paths = paths
    let file = paths.directory.appendingPathComponent("phone.json")
    if FileManager.default.fileExists(atPath: file.path) {
      settings = try JSONDecoder().decode(PhoneSettings.self, from: Data(contentsOf: file))
    } else { settings = try PhoneSettings() }
    try settings.validate()
    tunnel = NgrokTunnel(paths: paths)
    router = PhoneRouter(token: settings.token, readStatus: readStatus, shift: shift)
    status.internetEnabled = settings.internetEnabled
    try save()
    server.handler = { [weak self] request, completion in
      guard let self else { completion(.error(503, "Controls stopped.")); return }
      self.router.handle(request, completion: completion)
    }
    server.onReady = { [weak self] port in
      guard let self else { return }
      self.status.state = "ready"
      self.refreshLocalURLs(port: port)
      self.retryInternet()
    }
    server.onFailure = { [weak self] in
      guard let self else { return }
      self.tunnel.stop()
      self.status.state = "error"
      self.status.publicURL = nil
      self.status.localURLs = []
      self.status.error = "Phone port \(self.settings.port) is unavailable. Quit other instances and relaunch."
      self.onUpdate?(self.status)
    }
    tunnel.onUpdate = { [weak self] state, url, error in
      guard let self else { return }
      self.status.tunnelState = state
      self.status.publicURL = url
      self.status.error = error
      self.onUpdate?(self.status)
    }
  }
  func start() throws {
    try server.start(port: settings.port)
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let port = self.server.boundPort else { return }
        self.refreshLocalURLs(port: port)
      }
    }
    self.monitor = monitor
    monitor.start(queue: .main)
  }
  public func link(for base: String) -> URL? {
    guard var components = URLComponents(string: base) else { return nil }
    components.fragment = "key=" + settings.token
    return components.url
  }
  public func setInternetEnabled(_ enabled: Bool) throws {
    var updated = settings
    updated.internetEnabled = enabled
    try save(updated)
    settings = updated
    status.internetEnabled = enabled
    retryInternet()
  }
  public func retryInternet() {
    tunnel.stop()
    status.publicURL = nil
    status.error = nil
    if settings.internetEnabled, let port = server.boundPort { tunnel.start(port: port) }
    else {
      status.tunnelState = "off"
      onUpdate?(status)
    }
  }
  public func resetAccess() throws {
    var updated = settings
    updated.token = try PhoneSettings.newToken()
    try save(updated)
    settings = updated
    router.resetToken(updated.token)
    onUpdate?(status)
  }
  private func save(_ value: PhoneSettings? = nil) throws {
    try paths.prepare()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value ?? settings).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  private func refreshLocalURLs(port: UInt16) {
    status.localURLs = Self.localHosts().map { "http://\($0):\(port)/" }
    onUpdate?(status)
  }
  static func localHosts() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return ["127.0.0.1"] }
    defer { freeifaddrs(head) }
    var addresses: Set<String> = []
    var item = head
    while let current = item {
      defer { item = current.pointee.ifa_next }
      let interface = current.pointee
      let name = String(cString: interface.ifa_name)
      guard name.hasPrefix("en") || name.hasPrefix("bridge"),
        interface.ifa_flags & UInt32(IFF_UP) != 0,
        let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
        socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        addresses.insert(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
    }
    return addresses.isEmpty ? ["127.0.0.1"] : addresses.sorted()
  }
  func stop() {
    monitor?.cancel()
    monitor = nil
    tunnel.stop()
    server.stop()
    status.state = "stopped"
    status.tunnelState = "off"
    status.localURLs = []
    status.publicURL = nil
    onUpdate?(status)
  }
}
