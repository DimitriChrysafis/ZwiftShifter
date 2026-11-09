import Foundation

public struct DirConFrame: Equatable, Sendable {
  public let kind: UInt8
  public let sequence: UInt8
  public let result: UInt8
  public let payload: Data
  public init(kind: UInt8, sequence: UInt8 = 0, result: UInt8 = 0, payload: Data = Data()) {
    self.kind = kind
    self.sequence = sequence
    self.result = result
    self.payload = payload
  }
  public func encoded() throws -> Data {
    guard payload.count <= 4096 else {
      throw ShiftError.message("DirCon payload exceeds 4096 bytes.")
    }
    return Data([1, kind, sequence, result, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
      + payload
  }
}

public struct FrameDecoder {
  private var buffer = Data()
  public init() {}
  public mutating func append(_ data: Data) throws -> [DirConFrame] {
    guard buffer.count + data.count <= 16_384 else {
      throw ShiftError.message("DirCon receive buffer exceeded.")
    }
    buffer.append(data)
    var frames: [DirConFrame] = []
    while buffer.count >= 6 {
      let header = Array(buffer.prefix(6))
      let length = Int(header[4]) * 256 + Int(header[5])
      guard header[0] == 1, length <= 4096 else {
        throw ShiftError.message("Unsupported or oversized DirCon frame.")
      }
      guard buffer.count >= length + 6 else { break }
      frames.append(
        DirConFrame(
          kind: header[1], sequence: header[2], result: header[3],
          payload: Data(buffer.dropFirst(6).prefix(length))))
      buffer = Data(buffer.dropFirst(length + 6))
    }
    return frames
  }
}

public enum Proto {
  public static func varint(_ value: UInt64) -> Data {
    var v = value
    var result = Data()
    while v >= 128 {
      result.append(UInt8(v & 127) | 128)
      v >>= 7
    }
    result.append(UInt8(v))
    return result
  }
  public static func field(_ number: Int, _ value: UInt64) -> Data {
    varint(UInt64(number << 3)) + varint(value)
  }
  public static func field(_ number: Int, _ data: Data) -> Data {
    varint(UInt64(number << 3 | 2)) + varint(UInt64(data.count)) + data
  }
  public static func integerField(_ field: Int, in data: Data) throws -> UInt64? {
    let bytes = Array(data)
    var offset = 0
    func read() throws -> UInt64 {
      var value: UInt64 = 0
      for n in 0..<10 {
        guard offset < bytes.count else { throw ShiftError.message("Truncated protobuf varint.") }
        let b = bytes[offset]
        offset += 1
        if n == 9 && b > 1 { throw ShiftError.message("Protobuf integer overflow.") }
        value |= UInt64(b & 127) << (7 * n)
        if b & 128 == 0 { return value }
      }
      throw ShiftError.message("Invalid protobuf varint.")
    }
    while offset < bytes.count {
      let tag = try read()
      guard tag >> 3 > 0 else { throw ShiftError.message("Invalid protobuf field.") }
      switch tag & 7 {
      case 0:
        let value = try read()
        if tag >> 3 == field { return value }
      case 1: offset += 8
      case 2:
        let count = try read()
        guard count <= UInt64(bytes.count - offset) else {
          throw ShiftError.message("Truncated protobuf bytes.")
        }
        offset += Int(count)
      case 5: offset += 4
      default: throw ShiftError.message("Unsupported protobuf wire type.")
      }
      guard offset <= bytes.count else { throw ShiftError.message("Truncated protobuf field.") }
    }
    return nil
  }
}

public enum ZwiftWire {
  public static func uuid(_ string: String) -> Data {
    let full = string.count == 4 ? "0000\(string)-0000-1000-8000-00805f9b34fb" : string
    var bytes = UUID(uuidString: full)!.uuid
    return withUnsafeBytes(of: &bytes) { Data($0) }
  }
  public static let service = uuid("fc82")
  public static let async = uuid("00000002-19ca-4651-86e5-fa29dcdd09d1")
  public static let rx = uuid("00000003-19ca-4651-86e5-fa29dcdd09d1")
  public static let tx = uuid("00000004-19ca-4651-86e5-fa29dcdd09d1")
  public static let serviceType = "_wahoo-fitness-tnp._tcp."
  public static let services: [(Data, [(Data, UInt8)])] = [
    (service, [(async, 4), (rx, 2), (tx, 4)]),
    (uuid("180d"), [(uuid("2a37"), 4), (uuid("2a38"), 1)]),
    (uuid("180a"), ["2a29", "2a24", "2a25", "2a26", "2a27"].map { (uuid($0), 1) }),
    (uuid("180f"), [(uuid("2a19"), 5)]),
  ]
  public static func read(_ characteristic: Data, identity: Settings) -> Data? {
    let values: [Data: Data] = [
      uuid("2a65"): Data(repeating: 0, count: 4), uuid("2a5d"): Data([0]),
      uuid("2a29"): Data("ZwiftShift".utf8), uuid("2a24"): Data("Software Controller".utf8),
      uuid("2a25"): Data(identity.serialNumber.utf8), uuid("2a26"): Data("1.0.0".utf8),
      uuid("2a27"): Data("1".utf8), uuid("2a19"): Data([100]), tx: Data(),
    ]
    return values[characteristic]
  }
  public static func button(_ direction: ShiftDirection?) -> Data {
    let mask: UInt64 = direction == .up ? 0x1000 : direction == .down ? 0x100 : 0
    return Data([0x23]) + Proto.field(1, UInt64(0xffff_ffff) ^ mask)
  }
  /// Validated against Zwift 1.125.0. DO 0 requires the DevInfo envelope.
  public static func response(to request: Data) throws -> Data? {
    if request.starts(with: Data("RideOn".utf8)) {
      guard request == Data("RideOn".utf8) + Data([2, 4]) else {
        throw ShiftError.message("Unsupported Zwift handshake; expected RideOn 02 04.")
      }
      return Data("RideOn".utf8) + Data([2, 0])
    }
    guard request.first == 0, let page = try Proto.integerField(1, in: Data(request.dropFirst()))
    else { return nil }
    let value: Data
    switch page {
    case 0:
      let page =
        Proto.field(1, 0x200) + Proto.field(8, Proto.field(1, 2) + Proto.field(2, 1))
        + Proto.field(9, 0xffff) + Proto.field(10, 1)
      value = Proto.field(1, page)
    case 0x10: value = Data()
    case 0x400: value = Proto.field(1, 0x1100) + Proto.field(2, 0)
    case 0x303:
      value = Proto.field(1, 0) + Proto.field(2, 100) + Proto.field(3, 0) + Proto.field(4, 0)
    default: return nil
    }
    return Data([0x3c]) + Proto.field(1, page) + Proto.field(2, value)
  }
}
