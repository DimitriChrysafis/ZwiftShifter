import Foundation

public enum ShiftDirection: String, Codable, Sendable { case up, down }

public enum ShiftError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    if case .message(let s) = self { return s }
    return nil
  }
}

public struct Shortcut: Codable, Equatable, Sendable {
  public var keyCode: UInt32
  public var control: Bool
  public var option: Bool
  public var command: Bool
  public var shift: Bool
  public init(
    keyCode: UInt32, control: Bool = true, option: Bool = true,
    command: Bool = false, shift: Bool = false
  ) {
    self.keyCode = keyCode
    self.control = control
    self.option = option
    self.command = command
    self.shift = shift
  }
  public static let keys: [(String, UInt32)] = [
    ("↑", 126), ("↓", 125), ("→", 124), ("←", 123),
    ("]", 30), ("[", 33), ("F13", 105), ("F14", 107),
  ]
  public var label: String {
    (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
      + (Self.keys.first { $0.1 == keyCode }?.0 ?? "Key \(keyCode)")
  }
  public var isValid: Bool {
    Self.keys.contains { $0.1 == keyCode } && (control || option || command)
  }
}

public struct Settings: Codable, Equatable, Sendable {
  public var repeatMilliseconds = 350
  public var upShortcut = Shortcut(keyCode: 126)
  public var downShortcut = Shortcut(keyCode: 125)
  public var shortcutsEnabled = true
  public var deviceName = "ZwiftShift"
  public var serialNumber = String(UInt32.random(in: 100_000_000...999_999_999))
  public var macAddress: String =
    "02:5A:53:"
    + (0..<3).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: ":")
  public var networkPort: UInt16 = 54872
  public init() {}
  public func validate() throws {
    guard (200...2_000).contains(repeatMilliseconds) else {
      throw ShiftError.message("Repeat interval must be 200–2000 ms.")
    }
    guard upShortcut.isValid, downShortcut.isValid, upShortcut != downShortcut else {
      throw ShiftError.message("Choose different shortcuts with Control, Option, or Command.")
    }
    guard !deviceName.isEmpty, deviceName.utf8.count <= 32,
      deviceName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
      serialNumber.utf8.allSatisfy({ (48...57).contains($0) }), !serialNumber.isEmpty,
      macAddress.range(of: #"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"#, options: .regularExpression)
        != nil,
      networkPort > 1024
    else {
      throw ShiftError.message("Invalid device identity or network port.")
    }
  }
}

public struct ObservedGear: Codable, Equatable, Sendable {
  public var front: Int
  public var rear: Int
  public var frontCount: Int?
  public var rearCount: Int?
  public var observedAt: Date
  public var source = "Zwift Log.txt"
  public var label: String { frontCount == 1 ? String(rear) : "\(front + 1) · \(rear)" }
}

public struct LogEntry: Codable, Identifiable, Sendable {
  public var id = UUID()
  public var date = Date()
  public var level: String
  public var message: String
}

public struct ServiceStatus: Codable, Sendable {
  public var state = "stopped"
  public var zwiftRunning = false
  public var paired = false
  public var virtualShiftingEnabled = false
  public var controllerAsPowerSource = false
  public var connectedClients = 0
  public var backend = "Local network · DirCon / Zwift Protocol"
  public var gear: ObservedGear?
  public var settings: Settings
  public var busy = false
  public var sentPresses = 0
  public var observedChanges = 0
  public var lastError: String?
  public var events: [LogEntry] = []
  public var phone: PhoneStatus?
  public var canShift: Bool {
    zwiftRunning && paired && connectedClients > 0 && state == "connected"
  }
  public init(settings: Settings) { self.settings = settings }

  mutating func observeConnectionLine(_ line: String) {
    let controller = "device: \(settings.deviceName), role: "
    if line.contains(controller + "ZP User Input)") {
      if line.contains("Device selected for role") { paired = true }
      if line.contains("Device unselected for role") { paired = false }
    }
    if line.contains("Unpair \"\(settings.deviceName)\"") { paired = false }
    if line.contains("Non-Selected: \(settings.deviceName) (") { paired = false }
    if line.contains("Device selected for role"), line.contains(", role: Power)") {
      controllerAsPowerSource = line.contains(controller + "Power)")
    }
    if line.contains("Device unselected for role"), line.contains(controller + "Power)") {
      controllerAsPowerSource = false
    }
    if line.contains("Enabled virtual shifting on") { virtualShiftingEnabled = true }
    if line.contains("Disabled virtual shifting on") { virtualShiftingEnabled = false }
  }
}

public struct RPCRequest: Codable, Sendable {
  public var command: String
  public var direction: ShiftDirection?
  public var count: Int?
  public var settings: Settings?
  public init(
    command: String, direction: ShiftDirection? = nil, count: Int? = nil, settings: Settings? = nil
  ) {
    self.command = command
    self.direction = direction
    self.count = count
    self.settings = settings
  }
}

public struct RPCResponse: Codable, Sendable {
  public var ok: Bool
  public var message: String
  public var status: ServiceStatus?
  public var confirmed: Bool
  public init(ok: Bool, message: String, status: ServiceStatus? = nil, confirmed: Bool = false) {
    self.ok = ok
    self.message = message
    self.status = status
    self.confirmed = confirmed
  }
}

public struct RuntimePaths: Sendable {
  public let directory: URL
  public var socket: String { directory.appendingPathComponent("control.sock").path }
  public var settings: URL { directory.appendingPathComponent("settings.json") }
  public var log: URL { directory.appendingPathComponent("events.jsonl") }
  public init(directory: URL) { self.directory = directory }
  public static var current: RuntimePaths {
    if let custom = ProcessInfo.processInfo.environment["ZWIFTSHIFT_HOME"] ?? Bundle.main.object(
      forInfoDictionaryKey: "ZwiftShiftRuntimeDirectory") as? String
    {
      return RuntimePaths(directory: URL(fileURLWithPath: custom))
    }
    return RuntimePaths(
      directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/ZwiftShift"))
  }
  public func prepare() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
    if (attrs[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
  }
  public func loadSettings() throws -> Settings {
    guard FileManager.default.fileExists(atPath: settings.path) else { return Settings() }
    let result = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settings))
    try result.validate()
    return result
  }
  public func save(_ value: Settings) throws {
    try value.validate()
    try prepare()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: settings, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
  }
}
