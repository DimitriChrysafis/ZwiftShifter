import Darwin
import Foundation
import XCTest

@testable import ZwiftShiftCore

@MainActor final class PulseTests: XCTestCase {
  func testMinimumPressAndRelease() async throws {
    var buttons: [ShiftDirection?] = []
    var elapsed: Duration?
    try await ButtonPulse.perform(.up, send: { buttons.append($0) }, sleep: { elapsed = $0 })
    XCTAssertEqual(buttons, [.up, nil])
    XCTAssertEqual(elapsed, .milliseconds(120))
  }

  func testCancellationAlwaysReleasesButton() async {
    var buttons: [ShiftDirection?] = []
    do {
      try await ButtonPulse.perform(
        .down, send: { buttons.append($0) }, sleep: { _ in throw CancellationError() })
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(buttons, [.down, nil])
  }

  func testTransportFailureStillAttemptsRelease() async {
    var buttons: [ShiftDirection?] = []
    do {
      try await ButtonPulse.perform(
        .up,
        send: {
          buttons.append($0)
          if $0 != nil { throw ShiftError.message("Disconnected") }
        }, sleep: { _ in XCTFail("A failed send must not start a timer") })
      XCTFail("Expected transport error")
    } catch { XCTAssertEqual(error.localizedDescription, "Disconnected") }
    XCTAssertEqual(buttons, [.up, nil])
  }

  func testRealPulseDurationAndCancellation() async throws {
    let clock = ContinuousClock()
    var buttons: [ShiftDirection?] = []
    let start = clock.now
    try await ButtonPulse.perform(.up, send: { buttons.append($0) })
    XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(110))
    let task = Task { @MainActor in
      try await ButtonPulse.perform(.down, send: { buttons.append($0) })
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
      try await task.value
      XCTFail("Cancelled pulse completed")
    } catch {}
    XCTAssertEqual(buttons, [.up, nil, .down, nil])
  }
}

private struct TestTCP {
  let fd: Int32
  init(port: UInt16) throws {
    fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ShiftError.message("socket failed") }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(
      fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(
      fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var noSIGPIPE: Int32 = 1
    setsockopt(
      fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout.size(ofValue: noSIGPIPE)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(fd)
      throw ShiftError.message("connect failed")
    }
  }
  func close() { Darwin.close(fd) }
  func write(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
      }
      guard count > 0 else { throw ShiftError.message("TCP write failed") }
      offset += count
    }
  }
  func read(_ count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let n = data.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset)
      }
      guard n > 0 else { throw ShiftError.message("TCP read ended") }
      offset += n
    }
    return data
  }
  func frame() throws -> DirConFrame {
    let header = try read(6)
    let length = Int(header[4]) << 8 | Int(header[5])
    guard length <= 4096 else { throw ShiftError.message("Oversized frame") }
    var decoder = FrameDecoder()
    return try XCTUnwrap(decoder.append(header + read(length)).first)
  }
  func handshake() throws {
    for characteristic in [ZwiftWire.async, ZwiftWire.tx] {
      try write(DirConFrame(kind: 5, payload: characteristic + Data([1])).encoded())
      XCTAssertEqual(try frame().result, 0)
    }
    let hello = try DirConFrame(
      kind: 4, payload: ZwiftWire.rx + Data("RideOn".utf8) + Data([2, 4])
    ).encoded()
    try write(Data(hello.prefix(3)))
    try write(Data(hello.dropFirst(3)))
    XCTAssertEqual(try frame().kind, 4)
    XCTAssertEqual(try frame().payload, ZwiftWire.tx + Data("RideOn".utf8) + Data([2, 0]))
    try write(
      DirConFrame(kind: 4, payload: ZwiftWire.rx + Data([0]) + Proto.field(1, 0x400)).encoded())
    XCTAssertEqual(try frame().kind, 4)
    XCTAssertEqual(try frame().kind, 6)
  }
}

@MainActor final class NetworkIntegrationTests: XCTestCase {
  func testRealTCPHandshakeButtonDeliveryDisconnectAndReconnect() async throws {
    var settings = Settings()
    settings.networkPort = 0
    let backend = NetworkBackend(settings: settings)
    defer { backend.stop() }
    // Tests never advertise a fake controller to the user's running Zwift.
    try backend.start(advertise: false)
    for _ in 0..<100 where backend.boundPort == nil { try await Task.sleep(for: .milliseconds(10)) }
    let port = try XCTUnwrap(backend.boundPort)
    for direction in [ShiftDirection.up, .down] {
      try await Task.detached {
        let peer = try TestTCP(port: port)
        defer { peer.close() }
        try peer.handshake()
        try await backend.sendButton(direction)
        let press = try peer.frame()
        XCTAssertEqual(press.kind, 6)
        XCTAssertEqual(press.payload, ZwiftWire.async + ZwiftWire.button(direction))
        try await backend.sendButton(nil)
        XCTAssertEqual(try peer.frame().payload, ZwiftWire.async + ZwiftWire.button(nil))
        // The malformed length must close this session, not the listener.
        try peer.write(Data([1, 1, 0, 0, 255, 255]))
        XCTAssertThrowsError(try peer.read(1))
      }.value
      for _ in 0..<100 where backend.readyCount != 0 {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(backend.readyCount, 0)
    }
  }
}
