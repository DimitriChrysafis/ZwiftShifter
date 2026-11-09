import Darwin
import Foundation

/// The small CLI child owns ngrok and watches a pipe from the app. EOF also
/// happens on an app crash, so a public tunnel cannot outlive its owner.
public enum NgrokWorker {
  nonisolated(unsafe) private static var stopping: Int32 = 0
  public static func run(_ arguments: [String]) -> Int32 {
    guard let executable = arguments.first else { return 64 }
    var info = stat()
    guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { return 64 }
    stopping = 0
    signal(SIGTERM) { _ in NgrokWorker.stopping = 1 }
    signal(SIGINT) { _ in NgrokWorker.stopping = 1 }
    let owner = getppid()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = Array(arguments.dropFirst())
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    do { try child.run() } catch { return 70 }
    while child.isRunning && stopping == 0 && owner > 1 && getppid() == owner {
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
      let result = Darwin.poll(&descriptor, 1, 250)
      if result > 0 {
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
        if descriptor.revents & Int16(POLLIN) != 0 {
          var byte: UInt8 = 0
          if Darwin.read(STDIN_FILENO, &byte, 1) <= 0 { break }
        }
      } else if result < 0 && errno != EINTR { break }
    }
    if child.isRunning {
      child.terminate()
      for _ in 0..<50 where child.isRunning { usleep(20_000) }
      if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }
    child.waitUntilExit()
    return child.terminationStatus
  }
}

struct NgrokLogEvent {
  var publicURL: String?
  var errorCode: String?
  init(_ data: Data) {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = object["msg"] as? String, message == "started tunnel",
      let value = object["url"] as? String, let url = URLComponents(string: value),
      url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/"
    { publicURL = value.hasSuffix("/") ? value : value + "/" }
    let text = String(decoding: data, as: UTF8.self)
    if let range = text.range(of: #"ERR_NGROK_[0-9]+"#, options: .regularExpression) {
      errorCode = String(text[range])
    }
  }
}

@MainActor final class NgrokTunnel {
  var onUpdate: ((String, String?, String?) -> Void)?
  private let paths: RuntimePaths
  private var process: Process?
  private var input: Pipe?
  private var output: Pipe?
  private var buffer = Data()
  private var deadline: Timer?
  private var generation = UUID()
  private var lastCode: String?
  init(paths: RuntimePaths) { self.paths = paths }

  static func overlay(version: String) throws -> String {
    switch version {
    case "2": return "version: \"2\"\nweb_addr: false\nconsole_ui: false\nupdate_check: false\n"
    case "3": return "version: \"3\"\nagent:\n  web_addr: false\n  console_ui: false\n  update_check: false\n"
    default: throw ShiftError.message("Update the ngrok configuration with ‘ngrok config upgrade’.")
    }
  }
  private func arguments(port: UInt16) throws -> [String] {
    let environment = ProcessInfo.processInfo.environment
    let binaryCandidates = [environment["ZWIFTSHIFT_NGROK"], "/opt/homebrew/bin/ngrok",
      "/usr/local/bin/ngrok", FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/ngrok").path].compactMap { $0 }
    guard let binary = binaryCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { throw ShiftError.message("Install ngrok, then choose Retry Internet. Local phone access is ready.") }
    let config = URL(fileURLWithPath: environment["ZWIFTSHIFT_NGROK_CONFIG"] ?? FileManager.default
      .homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ngrok/ngrok.yml").path)
    var configs: [String] = []
    var version = "3"
    if FileManager.default.fileExists(atPath: config.path) {
      let bytes = try Data(contentsOf: config)
      guard bytes.count <= 131_072 else { throw ShiftError.message("Ngrok configuration is too large.") }
      let text = String(decoding: bytes, as: UTF8.self)
      if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("version:") }) {
        version = line.dropFirst(8).trimmingCharacters(in: .whitespaces)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      }
      configs.append(config.path)
    }
    let overlay = paths.directory.appendingPathComponent("ngrok-phone.yml")
    try Self.overlay(version: version).write(to: overlay, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: overlay.path)
    configs.append(overlay.path)
    guard configs.allSatisfy({ !$0.contains(",") }) else {
      throw ShiftError.message("Ngrok config paths cannot contain commas.")
    }
    return [binary, "http", "http://127.0.0.1:\(port)", "--config", configs.joined(separator: ","),
      "--inspect=false", "--log=stdout", "--log-format=json", "--log-level=info"]
  }
  private func helper() throws -> URL {
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zwiftshift"),
      paths.directory.deletingLastPathComponent().appendingPathComponent("zwiftshift"),
      Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("zwiftshift"),
    ].compactMap { $0 }
    guard let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    else { throw ShiftError.message("Rebuild ZwiftShift to install its tunnel helper.") }
    return result
  }
  func start(port: UInt16) {
    stop()
    onUpdate?("starting", nil, nil)
    do {
      let child = Process()
      child.executableURL = try helper()
      child.arguments = ["__ngrok"] + (try arguments(port: port))
      let input = Pipe(), output = Pipe()
      child.standardInput = input
      child.standardOutput = output
      child.standardError = output
      let id = UUID()
      generation = id
      lastCode = nil
      buffer.removeAll()
      child.terminationHandler = { [weak self] _ in
        Task { @MainActor in
          guard let self, self.generation == id else { return }
          let suffix = self.lastCode.map { " (\($0))" } ?? ""
          self.fail("Ngrok stopped\(suffix). Check ‘ngrok config check’, then retry.")
        }
      }
      output.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        Task { @MainActor in
          guard let self, self.generation == id else { return }
          self.consume(data)
        }
      }
      self.process = child
      self.input = input
      self.output = output
      try child.run()
      try? input.fileHandleForReading.close()
      let timer = Timer(timeInterval: 25, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.fail("Ngrok could not connect. Check your Internet connection and retry.")
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      deadline = timer
    } catch { fail(error.localizedDescription) }
  }
  private func consume(_ data: Data) {
    buffer.append(data)
    guard buffer.count <= 65_536 else { fail("Ngrok returned too much output. Retry the connection."); return }
    while let end = buffer.firstIndex(of: 10) {
      let line = Data(buffer.prefix(upTo: end))
      buffer.removeSubrange(...end)
      let event = NgrokLogEvent(line)
      if let code = event.errorCode { lastCode = code }
      if let url = event.publicURL {
        deadline?.invalidate()
        deadline = nil
        onUpdate?("online", url, nil)
      }
    }
  }
  private func fail(_ message: String) {
    stop()
    onUpdate?("error", nil, message)
  }
  func stop() {
    generation = UUID()
    deadline?.invalidate()
    deadline = nil
    output?.fileHandleForReading.readabilityHandler = nil
    try? input?.fileHandleForWriting.close()  // The worker terminates and reaps ngrok.
    input = nil
    output = nil
    process = nil
    buffer.removeAll()
  }
}
