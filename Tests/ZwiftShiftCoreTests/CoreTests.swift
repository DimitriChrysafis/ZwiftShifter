import Foundation
import XCTest

@testable import ZwiftShiftCore

private func hex(_ value: String) -> Data {
  let pairs = stride(from: 0, to: value.count, by: 2).map { offset -> UInt8 in
    let start = value.index(value.startIndex, offsetBy: offset)
    return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
  }
  return Data(pairs)
}

final class CoreTests: XCTestCase {
  func testCLIValidation() throws {
    XCTAssertEqual(try CLIArguments(["up", "--count", "5"]).command, .shift(.up, 5))
    XCTAssertEqual(try CLIArguments(["--json", "down"]).command, .shift(.down, 1))
    for args in [
      ["up", "--count", "0"], ["down", "--count", "-2"], ["up", "--count", "101"],
      ["down", "--count", "NaN"], ["up", "--wat"], ["status", "extra"], ["send-packet"],
    ] {
      XCTAssertThrowsError(try CLIArguments(args), "\(args)")
    }
  }
  func testFragmentedAndCoalescedFrames() throws {
    let first = DirConFrame(
      kind: 4, sequence: 255, payload: ZwiftWire.rx + Data("RideOn".utf8) + Data([2, 4]))
    let second = DirConFrame(kind: 1, sequence: 0)
    let data = try first.encoded() + second.encoded()
    for split in 0...data.count {
      var decoder = FrameDecoder()
      let result =
        try decoder.append(Data(data.prefix(split))) + decoder.append(Data(data.dropFirst(split)))
      XCTAssertEqual(result, [first, second], "split \(split)")
    }
    var decoder = FrameDecoder()
    var result: [DirConFrame] = []
    for byte in data { result += try decoder.append(Data([byte])) }
    XCTAssertEqual(result, [first, second])
  }
  func testFrameBounds() {
    var decoder = FrameDecoder()
    XCTAssertThrowsError(try decoder.append(Data([2, 1, 0, 0, 0, 0])))
    decoder = FrameDecoder()
    XCTAssertThrowsError(try decoder.append(Data([1, 1, 0, 0, 0xff, 0xff])))
    XCTAssertThrowsError(
      try DirConFrame(kind: 6, payload: Data(repeating: 0, count: 4097)).encoded())
  }
  func testProtobufRejectsTruncationAndOverflow() throws {
    XCTAssertEqual(try Proto.integerField(1, in: Proto.field(1, UInt64.max)), UInt64.max)
    for data in [
      Data([8, 128]), Data([10, 8, 1]), Data([0]), Data([8] + Array(repeating: 255, count: 10)),
    ] {
      XCTAssertThrowsError(try Proto.integerField(1, in: data))
    }
  }
  func testCapturedHandshakeAndCapabilities() throws {
    XCTAssertEqual(try ZwiftWire.response(to: hex("526964654f6e0204")), hex("526964654f6e0200"))
    XCTAssertEqual(
      try ZwiftWire.response(to: hex("000800")), hex("3c080012110a0f08800442040802100148ffff035001")
    )
    XCTAssertEqual(try ZwiftWire.response(to: hex("00088008")), hex("3c08800812050880221000"))
    XCTAssertEqual(try ZwiftWire.response(to: hex("00088306")), hex("3c08830612080800106418002000"))
    XCTAssertThrowsError(try ZwiftWire.response(to: Data("RideOn".utf8) + Data([1, 2])))
    XCTAssertNil(try ZwiftWire.response(to: hex("0008ffff03")))
  }
  func testCapturedButtonTransitions() {
    XCTAssertEqual(ZwiftWire.button(.up), hex("2308ffdfffff0f"))
    XCTAssertEqual(ZwiftWire.button(.down), hex("2308fffdffff0f"))
    XCTAssertEqual(ZwiftWire.button(nil), hex("2308ffffffff0f"))
  }
  func testSessionRequiresSubscriptionsAndHandshake() throws {
    var session = DirConSession(identity: Settings())
    XCTAssertFalse(session.ready)
    XCTAssertNil(session.notification(ZwiftWire.async, ZwiftWire.button(.up)))
    for characteristic in [ZwiftWire.async, ZwiftWire.tx] {
      _ = try session.handle(DirConFrame(kind: 5, payload: characteristic + Data([1])))
    }
    XCTAssertFalse(session.ready)
    let replies = try session.handle(
      DirConFrame(kind: 4, sequence: 33, payload: ZwiftWire.rx + hex("526964654f6e0204")))
    XCTAssertEqual(replies.first?.sequence, 33)
    XCTAssertEqual(replies.last?.payload, ZwiftWire.tx + hex("526964654f6e0200"))
    XCTAssertFalse(session.ready)
    _ = try session.handle(DirConFrame(kind: 4, payload: ZwiftWire.rx + hex("00088008")))
    XCTAssertTrue(session.ready)
    _ = try session.handle(DirConFrame(kind: 5, payload: ZwiftWire.async + Data([0])))
    XCTAssertFalse(session.ready)
    XCTAssertFalse(
      DirConSession(identity: Settings()).ready, "Reconnect must start a fresh session")
  }
  func testUnknownCharacteristicsAreRejectedAndNoPowerIsFabricated() throws {
    var session = DirConSession(identity: Settings())
    let response = try session.handle(DirConFrame(kind: 3, payload: ZwiftWire.uuid("ffff")))
    XCTAssertEqual(response.first?.result, 4)
    let subscribe = try session.handle(
      DirConFrame(kind: 5, payload: ZwiftWire.uuid("2a63") + Data([1])))
    XCTAssertEqual(subscribe.count, 1, "Power bootstrap must not send measurements")
    XCTAssertNil(ZwiftWire.read(ZwiftWire.uuid("2a63"), identity: Settings()))
  }
  func testObservedGearAndDynamicDimensions() throws {
    var tracker = GearTracker()
    XCTAssertNil(tracker.gear)
    tracker.consume(.dimensions(1, 37))
    tracker.consume(
      try XCTUnwrap(
        GearParser.parse("[10:33:56] INFO LEVEL: [Connectivity] Gearing: Shift 0-(8 -> 9)")))
    XCTAssertEqual(tracker.gear?.rear, 9)
    XCTAssertEqual(tracker.gear?.rearCount, 37)
    tracker.consume(try XCTUnwrap(GearParser.parse("Gearing: Shift 0-(9 -> 8)")))
    XCTAssertEqual(tracker.gear?.label, "8")
    XCTAssertFalse(tracker.consume(.rearShift(front: 0, from: 8, to: 8)))
    XCTAssertNil(GearParser.parse("Gearing: Shift 0-(8 -> 999999999999999999999999999)"))
    XCTAssertNil(GearParser.parse("Sent shift up"))
  }
  func testSettingsBoundsAndShortcutConflicts() throws {
    var settings = Settings()
    try settings.validate()
    settings.repeatMilliseconds = 199
    XCTAssertThrowsError(try settings.validate())
    settings.repeatMilliseconds = 350
    settings.downShortcut = settings.upShortcut
    XCTAssertThrowsError(try settings.validate())
  }
}

@MainActor final class LocalIntegrationTests: XCTestCase {
  private func temporaryPaths() throws -> RuntimePaths {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let paths = RuntimePaths(
      directory: root.appendingPathComponent("build/test-\(UUID().uuidString.prefix(8))"))
    try paths.prepare()
    return paths
  }
  func testRealUnixRPCRoundTripAndExclusiveOwnership() async throws {
    let paths = try temporaryPaths()
    let server = RPCServer(paths: paths)
    defer {
      server.stop()
      try? FileManager.default.removeItem(at: paths.directory)
    }
    server.handler = { request, completion in
      completion(RPCResponse(ok: true, message: request.command))
    }
    try server.start()
    let duplicate = RPCServer(paths: paths)
    XCTAssertThrowsError(try duplicate.start())
    let result = try await Task.detached {
      try RPCClient.request(RPCRequest(command: "diagnostics"), paths: paths, timeout: 3)
    }.value
    XCTAssertTrue(result.ok)
    XCTAssertEqual(result.message, "diagnostics")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: paths.socket)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket))
    try server.start()
    let restarted = try await Task.detached {
      try RPCClient.request(RPCRequest(command: "status"), paths: paths, timeout: 3)
    }.value
    XCTAssertTrue(restarted.ok)
  }
  func testRefusesToReplaceUnexpectedFile() throws {
    let paths = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    try Data("preserve me".utf8).write(to: URL(fileURLWithPath: paths.socket))
    XCTAssertThrowsError(try RPCServer(paths: paths).start())
    XCTAssertEqual(try String(contentsOfFile: paths.socket, encoding: .utf8), "preserve me")
  }
  func testTailHandlesPartialLinesAndRotation() throws {
    let paths = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let url = paths.directory.appendingPathComponent("Zwift.log")
    try Data("Gearing: Front 1, Back 31\nGearing: 0-8\n".utf8).write(to: url)
    let tail = GearTelemetry(url: url)
    defer { tail.reset() }
    try tail.poll()
    XCTAssertEqual(tail.tracker.gear?.rear, 8)
    let writer = try FileHandle(forWritingTo: url)
    defer { try? writer.close() }
    try writer.seekToEnd()
    try writer.write(contentsOf: Data("Gearing: Shift 0-(8 -> ".utf8))
    try tail.poll()
    XCTAssertEqual(tail.tracker.gear?.rear, 8)
    try writer.write(contentsOf: Data("9)\n".utf8))
    try tail.poll()
    XCTAssertEqual(tail.tracker.gear?.rear, 9)
    try Data("Gearing: Front 1, Back 12\nGearing: 0-4\n".utf8).write(to: url, options: .atomic)
    try tail.poll()
    XCTAssertEqual(tail.tracker.gear?.rear, 4)
    XCTAssertEqual(tail.tracker.gear?.rearCount, 12)
  }
}
