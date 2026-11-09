import Foundation
import Security

public struct PhoneStatus: Codable, Sendable {
  public var state = "starting"
  public var localURLs: [String] = []
  public var publicURL: String?
  public var internetEnabled = true
  public var tunnelState = "starting"
  public var error: String?
  public init() {}
}

struct PhoneSettings: Codable {
  var internetEnabled = true
  var port: UInt16 = 54874
  var token: String
  init() throws { token = try Self.newToken() }
  static func newToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ShiftError.message("Cannot create a private phone link.")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
  func validate() throws {
    guard token.count == 64, token.utf8.allSatisfy({
      (48...57).contains($0) || (97...102).contains($0)
    }), port > 1024, port != 54872 else {
      throw ShiftError.message("Invalid phone settings. Preserve phone.json and check its values.")
    }
  }
}

struct PhoneRideState: Encodable {
  var canShift: Bool
  var busy: Bool
  var gear: String?
  var gearCount: Int?
  var connection: String
  var trainerReady: Bool
  var repeatMilliseconds: Int
  var serverTime: Double

  init(_ status: ServiceStatus, now: Date = Date()) {
    canShift = status.canShift
    busy = status.busy
    gear = status.gear?.label
    gearCount = status.gear?.frontCount == 1 ? status.gear?.rearCount : nil
    trainerReady = status.virtualShiftingEnabled && !status.controllerAsPowerSource
    repeatMilliseconds = status.settings.repeatMilliseconds
    serverTime = now.timeIntervalSince1970 * 1000
    if !status.zwiftRunning { connection = "Open Zwift on your Mac" }
    else if status.controllerAsPowerSource { connection = "Select your trainer in Zwift" }
    else if !canShift { connection = "Pair ZwiftShift under Controls" }
    else if !trainerReady { connection = "Trainer not ready" }
    else { connection = "Connected" }
  }
}

struct PhoneCommand: Codable {
  var id: String
  var direction: ShiftDirection
  var expiresAt: Double
}

struct PhoneShiftResult: Encodable {
  var ok: Bool
  var confirmed: Bool
  var message: String
  var state: PhoneRideState
}

@MainActor final class PhoneRouter {
  private struct CommandRecord {
    var direction: ShiftDirection
    var created: ContinuousClock.Instant
    var response: HTTPResponse?
  }
  var token: String
  var readStatus: () -> ServiceStatus
  var shift: (ShiftDirection, @escaping (RPCResponse) -> Void) -> Void
  private var commands: [String: CommandRecord] = [:]
  private var recentRequests: [ContinuousClock.Instant] = []
  private let clock = ContinuousClock()
  private let assets: [String: HTTPResponse]

  init(
    token: String, readStatus: @escaping () -> ServiceStatus,
    shift: @escaping (ShiftDirection, @escaping (RPCResponse) -> Void) -> Void
  ) {
    self.token = token
    self.readStatus = readStatus
    self.shift = shift
    var assets: [String: HTTPResponse] = [:]
    for (path, file, type) in [
      ("/", "index.html", "text/html; charset=utf-8"),
      ("/app.css", "app.css", "text/css; charset=utf-8"),
      ("/app.js", "app.js", "text/javascript; charset=utf-8"),
      ("/favicon.svg", "favicon.svg", "image/svg+xml"),
    ] {
      if let url = Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Web"),
        let bytes = try? Data(contentsOf: url)
      { assets[path] = HTTPResponse(contentType: type, body: bytes) }
    }
    self.assets = assets
  }

  func handle(_ request: HTTPRequest, completion: @escaping (HTTPResponse) -> Void) {
    if request.method == "GET", let asset = assets[request.target] {
      completion(asset)
      return
    }
    guard ["/api/status", "/api/shift"].contains(request.target) else {
      completion(.error(404, "Not found.")); return
    }
    guard Self.equalSecret(request.headers["authorization"] ?? "", "Bearer " + token) else {
      completion(.error(401, "Open the private link or scan the QR code in ZwiftShift.")); return
    }
    // No cookies and no CORS: unrelated websites cannot send an authenticated action.
    if let origin = request.headers["origin"] {
      guard let components = URLComponents(string: origin),
        ["http", "https"].contains(components.scheme), components.user == nil,
        components.password == nil, components.query == nil, components.fragment == nil,
        components.path.isEmpty, let host = components.host,
        (host + (components.port.map { ":\($0)" } ?? "")).lowercased()
          == request.headers["host"]?.lowercased()
      else { completion(.error(403, "This page cannot control ZwiftShift.")); return }
    }
    if request.method == "GET", request.target == "/api/status" {
      completion(.json(PhoneRideState(readStatus()))); return
    }
    guard request.method == "POST", request.target == "/api/shift",
      request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json",
      let command = try? JSONDecoder().decode(PhoneCommand.self, from: request.body),
      (16...64).contains(command.id.utf8.count),
      command.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || $0 == 45 }),
      command.expiresAt.isFinite
    else { completion(.error(400, "Invalid shift request.")); return }
    let instant = clock.now
    commands = commands.filter { $0.value.created.duration(to: instant) < .seconds(30) }
    if let record = commands[command.id] {
      guard record.direction == command.direction else {
        completion(.error(409, "That command ID was already used.")); return
      }
      completion(record.response ?? .error(409, "That shift is already in progress."))
      return
    }
    let remaining = command.expiresAt - Date().timeIntervalSince1970 * 1000
    guard remaining > 0, remaining <= 5000 else {
      completion(.error(409, "This press expired. Release and press again.")); return
    }
    recentRequests.removeAll { $0.duration(to: instant) >= .seconds(1) }
    guard recentRequests.count < 8, commands.count < 256 else {
      completion(.error(429, "Too many shifts. Release the button and try again.")); return
    }
    recentRequests.append(instant)
    commands[command.id] = CommandRecord(direction: command.direction, created: instant)
    let activeToken = token
    shift(command.direction) { [weak self] response in
      guard let self else { completion(.error(503, "Controls stopped.")); return }
      let reply = HTTPResponse.json(PhoneShiftResult(
        ok: response.ok, confirmed: response.confirmed, message: response.message,
        state: PhoneRideState(self.readStatus())))
      if self.token == activeToken { self.commands[command.id]?.response = reply }
      completion(reply)
    }
  }
  func resetToken(_ token: String) {
    self.token = token
    commands.removeAll()
    recentRequests.removeAll()
  }
  static func equalSecret(_ a: String, _ b: String) -> Bool {
    let lhs = Array(a.utf8), rhs = Array(b.utf8)
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
