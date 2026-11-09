import AppKit
import Foundation

@MainActor public final class ShiftService {
  public private(set) var status: ServiceStatus
  public var onUpdate: ((ServiceStatus) -> Void)?
  public let paths: RuntimePaths
  private let backend: NetworkBackend
  private let rpc: RPCServer
  private let telemetry: GearTelemetry
  private var timer: Timer?
  private var job: Task<Void, Never>?
  private var holdSource: String?
  private var holdReleased = false
  private var activePID: pid_t?
  private var batchDirection: ShiftDirection?
  private var batchObserved = 0
  private var batchUnexpected = false
  private var stopped = false
  private var telemetryError: String?
  public init(paths: RuntimePaths = .current, logURL: URL = GearTelemetry.defaultURL) throws {
    self.paths = paths
    let settings = try paths.loadSettings()
    status = ServiceStatus(settings: settings)
    backend = NetworkBackend(settings: settings)
    rpc = RPCServer(paths: paths)
    telemetry = GearTelemetry(url: logURL)
    backend.onEvent = { [weak self] in self?.log($0, $1) }
    backend.onState = { [weak self] state, count in
      guard let self else { return }
      self.status.state = state
      self.status.connectedClients = count
      if count == 0 { self.cancelShifting() }
      self.publish()
    }
    telemetry.onEvent = { [weak self] event, historical in
      self?.observe(event, historical: historical)
    }
    telemetry.onLine = { [weak self] line, _ in self?.observeLine(line) }
    rpc.handler = { [weak self] request, completion in
      guard let self else {
        completion(RPCResponse(ok: false, message: "Service stopped."))
        return
      }
      self.handle(request, completion: completion)
    }
  }
  public func start() throws {
    try status.settings.validate()
    try paths.prepare()
    try paths.save(status.settings)
    try rpc.start()
    do { try backend.start() } catch {
      rpc.stop()
      throw error
    }
    stopped = false
    poll()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    log("info", "ZwiftShift started. Gear feedback comes from Zwift’s log.")
  }
  public func stop() {
    guard !stopped else { return }
    stopped = true
    cancelShifting()
    timer?.invalidate()
    timer = nil
    backend.stop()
    rpc.stop()
    telemetry.reset()
    status.gear = nil
    log("info", "Service stopped; all buttons released.")
  }
  private func poll() {
    let app = NSWorkspace.shared.runningApplications.first {
      ["ZwiftAppSilicon", "ZwiftApp"].contains($0.executableURL?.lastPathComponent ?? "")
    }
    let pid = app?.processIdentifier
    if pid != activePID {
      activePID = pid
      telemetry.reset()
      status.gear = nil
      status.paired = false
      status.virtualShiftingEnabled = false
      status.controllerAsPowerSource = false
      status.zwiftRunning = pid != nil
      if pid == nil {
        cancelShifting()
        log("info", "Zwift closed. Waiting for its next connection.")
      } else {
        log("info", "Zwift detected (PID \(pid!)).")
      }
    }
    if pid != nil {
      do {
        try telemetry.poll()
        telemetryError = nil
        status.gear = telemetry.tracker.gear
      } catch {
        if telemetryError != error.localizedDescription {
          telemetryError = error.localizedDescription
          log("warning", "Cannot read Zwift gear feedback: \(error.localizedDescription)")
        }
      }
    }
    publish()
  }
  private func observeLine(_ line: String) {
    let wasPaired = status.paired
    status.observeConnectionLine(line)
    if wasPaired && !status.paired { cancelShifting() }
  }
  private func observe(_ event: GearEvent, historical: Bool) {
    status.gear = telemetry.tracker.gear
    guard !historical else { return }
    let from: Int
    let to: Int
    switch event {
    case .rearShift(_, let old, let new):
      from = old
      to = new
    case .frontShift(let old, let new, _):
      from = old
      to = new
    default: return
    }
    guard from != to else { return }
    status.observedChanges += 1
    if let expected = batchDirection {
      if (to > from ? ShiftDirection.up : .down) == expected, abs(to - from) == 1 {
        batchObserved += 1
      } else {
        batchUnexpected = true
      }
    }
    log("observed", "Zwift gear \(from) → \(to)")
  }
  public func updateSettings(_ settings: Settings) throws {
    guard settings.deviceName == status.settings.deviceName,
      settings.serialNumber == status.settings.serialNumber,
      settings.macAddress == status.settings.macAddress,
      settings.networkPort == status.settings.networkPort
    else {
      throw ShiftError.message(
        "Device identity changes require stopping the app and editing settings.json.")
    }
    try paths.save(settings)
    cancelShifting()
    status.settings = settings
    log("info", "Controls updated.")
  }
  public func shift(
    _ direction: ShiftDirection, count: Int = 1, completion: @escaping (RPCResponse) -> Void
  ) {
    poll()
    guard (1...100).contains(count) else {
      completion(reply(false, "Count must be 1–100."))
      return
    }
    guard status.canShift else {
      completion(
        reply(
          false,
          "Connect ZwiftShift under Zwift Controls, keep your trainer paired, and enter a ride."))
      return
    }
    guard job == nil else {
      completion(reply(false, "A shift or hold is already in progress."))
      return
    }
    batchDirection = direction
    batchObserved = 0
    batchUnexpected = false
    status.busy = true
    publish()
    job = Task(priority: .userInitiated) { @MainActor [weak self] in
      guard let self else { return }
      let activity = self.beginInputActivity()
      var sent = 0
      defer {
        ProcessInfo.processInfo.endActivity(activity)
        try? self.backend.sendButton(nil)
        self.batchDirection = nil
        self.job = nil
        self.status.busy = false
        self.publish()
      }
      do {
        for i in 0..<count {
          try Task.checkCancellation()
          try await self.pulse(direction)
          sent += 1
          if i + 1 < count {
            try await Task.sleep(
              for: .milliseconds(
                self.status.settings.repeatMilliseconds - ButtonPulse.milliseconds),
              tolerance: .milliseconds(5)
            )
          }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(2500))
        while self.batchObserved < count && clock.now < deadline {
          try await Task.sleep(for: .milliseconds(100))
          self.poll()
        }
        let confirmed = self.batchObserved == count && !self.batchUnexpected
        let message =
          confirmed
          ? "Confirmed \(count) \(direction.rawValue) shift\(count == 1 ? "" : "s") in Zwift. Gear \(self.status.gear?.label ?? "unknown")."
          : "Sent \(sent) presses; observed \(self.batchObserved) matching gear changes. Check the ride, gear limits, and trainer connection."
        self.log(confirmed ? "success" : "warning", message)
        self.status.busy = false
        completion(self.reply(confirmed, message, confirmed: confirmed))
      } catch {
        let message =
          error is CancellationError
          ? "Shifting cancelled; buttons released." : error.localizedDescription
        self.log("warning", message)
        self.status.busy = false
        completion(self.reply(false, message))
      }
    }
  }
  private func pulse(_ direction: ShiftDirection) async throws {
    guard status.canShift else { throw ShiftError.message("Zwift controller connection was lost.") }
    try await ButtonPulse.perform(direction) { [self] button in
      try backend.sendButton(button)
      if button != nil { status.sentPresses += 1 }
    }
  }
  public func beginHold(_ direction: ShiftDirection, source: String) {
    guard job == nil, status.canShift else { return }
    holdSource = source
    holdReleased = false
    status.busy = true
    publish()
    log("info", "Holding shift \(direction.rawValue) (\(source)).")
    job = Task(priority: .userInitiated) { @MainActor [weak self] in
      guard let self else { return }
      let activity = self.beginInputActivity()
      defer {
        ProcessInfo.processInfo.endActivity(activity)
        try? self.backend.sendButton(nil)
        self.job = nil
        self.holdSource = nil
        self.status.busy = false
        self.publish()
      }
      do {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        repeat {
          try Task.checkCancellation()
          try await self.pulse(direction)
          if self.holdReleased { break }
          try await Task.sleep(
            for: .milliseconds(self.status.settings.repeatMilliseconds - ButtonPulse.milliseconds),
            tolerance: .milliseconds(5))
        } while !self.holdReleased && clock.now < deadline
        if clock.now >= deadline {
          self.log("info", "30-second hold limit reached. Release and press again to continue.")
        }
      } catch {
        if !(error is CancellationError) { self.log("warning", error.localizedDescription) }
      }
    }
  }
  public func endHold(source: String) { if holdSource == source { holdReleased = true } }
  private func beginInputActivity() -> NSObjectProtocol {
    // A controller must stay responsive while Zwift is in front. The assertion
    // exists only during a bounded user action and does not prevent system sleep.
    ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
      reason: "Delivering requested Zwift gear shifts")
  }
  public func cancelShifting() {
    job?.cancel()
    try? backend.sendButton(nil)
  }
  private func handle(_ request: RPCRequest, completion: @escaping (RPCResponse) -> Void) {
    switch request.command {
    case "status", "diagnostics":
      poll()
      completion(reply(true, "\(status.state); observed gear \(status.gear?.label ?? "unknown")."))
    case "shift":
      guard let direction = request.direction else {
        completion(reply(false, "A shift direction is required."))
        return
      }
      shift(direction, count: request.count ?? 1, completion: completion)
    case "settings":
      do {
        guard let settings = request.settings else {
          throw ShiftError.message("Settings are required.")
        }
        try updateSettings(settings)
        completion(reply(true, "Settings saved."))
      } catch { completion(reply(false, error.localizedDescription)) }
    default: completion(reply(false, "Unknown command: \(request.command)"))
    }
  }
  private func reply(_ ok: Bool, _ message: String, confirmed: Bool = false) -> RPCResponse {
    RPCResponse(ok: ok, message: message, status: status, confirmed: confirmed)
  }
  private func publish() { onUpdate?(status) }
  public func log(_ level: String, _ message: String) {
    let entry = LogEntry(level: level, message: message)
    status.events.append(entry)
    if status.events.count > 100 { status.events.removeFirst(status.events.count - 100) }
    if level == "error" { status.lastError = message }
    if let data = try? RPCCodec.encode(entry) {
      let fm = FileManager.default
      if let size = (try? fm.attributesOfItem(atPath: paths.log.path)[.size]) as? NSNumber,
        size.intValue > 1_048_576
      {
        let previous = paths.log.appendingPathExtension("1")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: paths.log, to: previous)
      }
      if !fm.fileExists(atPath: paths.log.path) {
        fm.createFile(atPath: paths.log.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      if let file = try? FileHandle(forWritingTo: paths.log) {
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data)
      }
    }
    publish()
  }
}
