import Darwin
import Foundation

public enum RPCCodec {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value) + Data([10])
  }
  public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }
}

private func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T)
  throws -> T
{
  var value = sockaddr_un()
  let bytes = Array(path.utf8) + [UInt8(0)]
  guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else {
    throw ShiftError.message(
      "Local socket path is too long. Set ZWIFTSHIFT_HOME to a shorter project directory.")
  }
  value.sun_family = sa_family_t(AF_UNIX)
  value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of: &value.sun_path) { target in
    bytes.withUnsafeBytes { target.copyMemory(from: $0) }
  }
  return try withUnsafePointer(to: &value) { pointer in
    try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
}

public enum RPCClient {
  public static func request(
    _ request: RPCRequest, paths: RuntimePaths = .current, timeout: TimeInterval = 210
  ) throws -> RPCResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ShiftError.message("Cannot create local socket.") }
    defer { close(fd) }
    var noSignal: Int32 = 1
    setsockopt(
      fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
    let connected = try address(paths.socket) { Darwin.connect(fd, $0, $1) }
    guard connected == 0 else {
      throw ShiftError.message(
        "ZwiftShift is not running. Open build/ZwiftShift.app or run zwiftshift serve. (\(String(cString: strerror(errno))))"
      )
    }
    let data = try RPCCodec.encode(request)
    var written = 0
    while written < data.count {
      let count = data.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress!.advanced(by: written), data.count - written)
      }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw ShiftError.message("Local request could not be sent.") }
      written += count
    }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while response.count <= 131_072 {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else {
        throw ShiftError.message("Local service closed or timed out before replying.")
      }
      response.append(contentsOf: buffer.prefix(count))
      if let end = response.firstIndex(of: 10) {
        return try RPCCodec.decode(RPCResponse.self, Data(response.prefix(upTo: end)))
      }
    }
    throw ShiftError.message("Local response exceeded its size limit.")
  }
}

@MainActor public final class RPCServer {
  private final class Peer {
    let fd: Int32
    var input = Data()
    var output = Data()
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var timeout: Timer?
    var handling = false
    init(_ fd: Int32) { self.fd = fd }
  }
  private let paths: RuntimePaths
  private var listenerFD: Int32 = -1
  private var lockFD: Int32 = -1
  private var source: DispatchSourceRead?
  private var peers: [Int32: Peer] = [:]
  public var handler: ((RPCRequest, @escaping (RPCResponse) -> Void) -> Void)?
  public init(paths: RuntimePaths) { self.paths = paths }
  public func start() throws {
    guard listenerFD < 0 else { return }
    try paths.prepare()
    let lock = open(
      paths.directory.appendingPathComponent("service.lock").path, O_CREAT | O_RDWR | O_CLOEXEC,
      0o600)
    guard lock >= 0 else { throw ShiftError.message("Cannot create service lock.") }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      close(lock)
      throw ShiftError.message("Another ZwiftShift service is already running.")
    }
    var started = false
    defer {
      if !started {
        flock(lock, LOCK_UN)
        close(lock)
      }
    }
    if FileManager.default.fileExists(atPath: paths.socket) {
      // Only remove our stale socket; never replace an arbitrary file.
      let attrs = try FileManager.default.attributesOfItem(atPath: paths.socket)
      guard attrs[.type] as? FileAttributeType == .typeSocket,
        (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
      else {
        throw ShiftError.message("Refusing to replace an unexpected control.sock file.")
      }
      try FileManager.default.removeItem(atPath: paths.socket)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ShiftError.message("Cannot create local listener.") }
    do {
      guard try address(paths.socket, { Darwin.bind(fd, $0, $1) }) == 0 else {
        throw ShiftError.message("Cannot bind local socket: \(String(cString: strerror(errno)))")
      }
      chmod(paths.socket, 0o600)
      guard listen(fd, 8) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
        throw ShiftError.message("Cannot listen on local socket.")
      }
    } catch {
      close(fd)
      throw error
    }
    listenerFD = fd
    lockFD = lock
    started = true
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
    source.setCancelHandler { close(fd) }
    self.source = source
    source.resume()
  }
  private func accept() {
    while true {
      let fd = Darwin.accept(listenerFD, nil, nil)
      guard fd >= 0 else { return }
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), peers.count < 8 else {
        close(fd)
        continue
      }
      guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
        close(fd)
        continue
      }
      var value: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value)))
      let peer = Peer(fd)
      peers[fd] = peer
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
      source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(fd) } }
      peer.readSource = source
      source.resume()
      let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.closePeer(fd) }
      }
      RunLoop.main.add(timer, forMode: .common)
      peer.timeout = timer
    }
  }
  private func read(_ fd: Int32) {
    guard let peer = peers[fd], !peer.handling else { return }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = Darwin.read(fd, &buffer, buffer.count)
    if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
    guard count > 0 else {
      closePeer(fd)
      return
    }
    peer.input.append(contentsOf: buffer.prefix(count))
    guard peer.input.count <= 8192 else {
      closePeer(fd)
      return
    }
    guard let end = peer.input.firstIndex(of: 10) else { return }
    peer.handling = true
    peer.timeout?.invalidate()
    peer.timeout = nil
    peer.readSource?.cancel()
    peer.readSource = nil
    do {
      let request = try RPCCodec.decode(RPCRequest.self, Data(peer.input.prefix(upTo: end)))
      guard let handler else { throw ShiftError.message("Service unavailable.") }
      handler(request) { [weak self] response in self?.reply(fd, response) }
    } catch { reply(fd, RPCResponse(ok: false, message: error.localizedDescription)) }
  }
  private func reply(_ fd: Int32, _ response: RPCResponse) {
    guard let peer = peers[fd], let data = try? RPCCodec.encode(response) else {
      closePeer(fd)
      return
    }
    peer.output = data
    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.write(fd) } }
    peer.writeSource = source
    source.resume()
    let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.closePeer(fd) }
    }
    RunLoop.main.add(timer, forMode: .common)
    peer.timeout = timer
  }
  private func write(_ fd: Int32) {
    guard let peer = peers[fd] else { return }
    let count = peer.output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, peer.output.count) }
    if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
    guard count > 0 else {
      closePeer(fd)
      return
    }
    peer.output = Data(peer.output.dropFirst(count))
    if peer.output.isEmpty { closePeer(fd) }
  }
  private func closePeer(_ fd: Int32) {
    guard let peer = peers.removeValue(forKey: fd) else { return }
    peer.timeout?.invalidate()
    peer.readSource?.cancel()
    peer.writeSource?.cancel()
    // Sources run on the main queue, so no read/write handler can race this close.
    close(fd)
  }
  public func stop() {
    for fd in Array(peers.keys) { closePeer(fd) }
    source?.cancel()
    source = nil
    if listenerFD >= 0 {
      unlink(paths.socket)
      listenerFD = -1
    }
    if lockFD >= 0 {
      flock(lockFD, LOCK_UN)
      close(lockFD)
      lockFD = -1
    }
  }
}
