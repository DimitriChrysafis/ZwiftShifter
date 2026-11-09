import Foundation
import Network

struct HTTPRequest {
  let method: String
  let target: String
  let headers: [String: String]
  let body: Data
}

/// A deliberately small HTTP/1.1 server: one bounded request per connection.
/// There is no file serving, proxying, chunked request body, or RPC passthrough.
struct HTTPRequestDecoder {
  private var buffer = Data()
  static let maximumHeader = 8192
  static let maximumBody = 2048

  mutating func append(_ data: Data) throws -> HTTPRequest? {
    buffer.append(data)
    guard buffer.count <= Self.maximumHeader + Self.maximumBody else {
      throw ShiftError.message("Request too large.")
    }
    guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
      guard buffer.count <= Self.maximumHeader else { throw ShiftError.message("Header too large.") }
      return nil
    }
    guard end.upperBound <= Self.maximumHeader,
      let text = String(data: buffer.prefix(upTo: end.lowerBound), encoding: .ascii)
    else { throw ShiftError.message("Invalid HTTP header.") }
    let lines = text.components(separatedBy: "\r\n")
    let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard request.count == 3, request[2] == "HTTP/1.1",
      ["GET", "POST"].contains(String(request[0])), request[1].hasPrefix("/"),
      request[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 })
    else { throw ShiftError.message("Unsupported HTTP request.") }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { throw ShiftError.message("Invalid header.") }
      let name = String(line[..<colon]).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, name.utf8.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45
      }), value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }), headers[name] == nil
      else { throw ShiftError.message("Invalid or duplicate header.") }
      headers[name] = value
    }
    guard let host = headers["host"], !host.isEmpty,
      !host.contains(where: { "/\\@, \t".contains($0) }),
      headers["transfer-encoding"] == nil, headers["expect"] == nil
    else { throw ShiftError.message("Unsupported request framing.") }
    let rawLength = headers["content-length"] ?? "0"
    guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
      let length = Int(rawLength), length <= Self.maximumBody,
      request[0] != "GET" || length == 0
    else { throw ShiftError.message("Invalid content length.") }
    let total = end.upperBound + length
    guard buffer.count <= total else { throw ShiftError.message("Pipelining is not supported.") }
    guard buffer.count == total else { return nil }
    return HTTPRequest(
      method: String(request[0]), target: String(request[1]), headers: headers,
      body: Data(buffer.suffix(length)))
  }
}

struct HTTPResponse {
  var code: Int = 200
  var contentType = "application/json; charset=utf-8"
  var body: Data

  static func json<T: Encodable>(_ value: T, code: Int = 200) -> HTTPResponse {
    HTTPResponse(code: code, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
  }
  static func error(_ code: Int, _ message: String) -> HTTPResponse {
    json(["error": message], code: code)
  }
  func encoded() -> Data {
    let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
      404: "Not Found", 409: "Conflict", 413: "Content Too Large", 429: "Too Many Requests",
      503: "Service Unavailable"][code] ?? "Error"
    let headers = [
      "HTTP/1.1 \(code) \(reason)", "Content-Type: \(contentType)",
      "Content-Length: \(body.count)", "Connection: close", "Cache-Control: no-store",
      "X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer",
      "X-Frame-Options: DENY",
      "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
    ]
    return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
  }
}

@MainActor final class PhoneHTTPServer {
  private final class Peer {
    let connection: NWConnection
    var decoder = HTTPRequestDecoder()
    var timeout: Timer?
    init(_ connection: NWConnection) { self.connection = connection }
  }
  private var listener: NWListener?
  private var peers: [UUID: Peer] = [:]
  private(set) var boundPort: UInt16?
  var onReady: ((UInt16) -> Void)?
  var onFailure: (() -> Void)?
  var handler: ((HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?

  func start(port: UInt16) throws {
    guard listener == nil else { return }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      MainActor.assumeIsolated {
        guard let self, self.listener === listener else { return }
        switch state {
        case .ready:
          self.boundPort = listener?.port?.rawValue
          if let port = self.boundPort { self.onReady?(port) }
        case .failed:
          self.stop()
          self.onFailure?()
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      MainActor.assumeIsolated { self?.accept(connection) }
    }
    listener.start(queue: .main)
  }
  private func accept(_ connection: NWConnection) {
    guard peers.count < 24 else { connection.cancel(); return }
    let id = UUID()
    let peer = Peer(connection)
    peers[id] = peer
    deadline(id, seconds: 5)
    connection.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        switch state {
        case .ready: self?.receive(id)
        case .cancelled, .failed: self?.remove(id)
        default: break
        }
      }
    }
    connection.start(queue: .main)
  }
  private func receive(_ id: UUID) {
    guard let peer = peers[id] else { return }
    peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, complete, error in
      MainActor.assumeIsolated {
        guard let self, let peer = self.peers[id] else { return }
        do {
          if let data, let request = try peer.decoder.append(data) {
            self.deadline(id, seconds: 8)
            guard let handler = self.handler else {
              self.respond(.error(503, "Controls unavailable."), to: id)
              return
            }
            handler(request) { [weak self] response in self?.respond(response, to: id) }
          } else if complete || error != nil {
            self.remove(id)
          } else { self.receive(id) }
        } catch { self.respond(.error(400, "Invalid HTTP request."), to: id) }
      }
    }
  }
  private func deadline(_ id: UUID, seconds: TimeInterval) {
    guard let peer = peers[id] else { return }
    peer.timeout?.invalidate()
    let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.remove(id) }
    }
    RunLoop.main.add(timer, forMode: .common)
    peer.timeout = timer
  }
  private func respond(_ response: HTTPResponse, to id: UUID) {
    guard let peer = peers[id] else { return }
    deadline(id, seconds: 5)
    peer.connection.send(content: response.encoded(), completion: .contentProcessed { [weak self] _ in
      MainActor.assumeIsolated { self?.remove(id) }
    })
  }
  private func remove(_ id: UUID) {
    guard let peer = peers.removeValue(forKey: id) else { return }
    peer.timeout?.invalidate()
    peer.connection.cancel()
  }
  func stop() {
    listener?.cancel()
    listener = nil
    boundPort = nil
    for id in Array(peers.keys) { remove(id) }
  }
}
