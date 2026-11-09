import Foundation

/// Pure per-connection protocol state. UI and CLI never serialize controller bytes.
public struct DirConSession {
  public private(set) var subscriptions: Set<Data> = []
  public private(set) var handshakeComplete = false
  public private(set) var inputConfigurationRead = false
  public var ready: Bool {
    handshakeComplete && inputConfigurationRead && subscriptions.contains(ZwiftWire.async)
  }
  private let identity: Settings
  public init(identity: Settings) { self.identity = identity }

  public func notification(_ characteristic: Data, _ data: Data) -> DirConFrame? {
    guard subscriptions.contains(characteristic) else { return nil }
    return DirConFrame(kind: 6, payload: characteristic + data)
  }
  public mutating func handle(_ frame: DirConFrame) throws -> [DirConFrame] {
    let payload = frame.payload
    let characteristic = Data(payload.prefix(16))
    func reply(_ data: Data = Data(), result: UInt8 = 0) -> DirConFrame {
      DirConFrame(kind: frame.kind, sequence: frame.sequence, result: result, payload: data)
    }
    switch frame.kind {
    case 1:
      guard payload.isEmpty else { return [reply(result: 6)] }
      return [reply(ZwiftWire.services.reduce(into: Data()) { $0 += $1.0 })]
    case 2:
      guard payload.count == 16 else { return [reply(result: 6)] }
      guard let service = ZwiftWire.services.first(where: { $0.0 == payload }) else {
        return [reply(result: 3)]
      }
      return [reply(service.1.reduce(into: payload) { $0 += $1.0 + Data([$1.1]) })]
    case 3:
      guard payload.count == 16 else { return [reply(result: 6)] }
      guard let data = ZwiftWire.read(characteristic, identity: identity) else {
        return [reply(characteristic, result: 4)]
      }
      return [reply(characteristic + data)]
    case 5:
      guard payload.count == 17, let enabled = payload.last, enabled <= 1 else {
        return [reply(result: 6)]
      }
      guard
        ZwiftWire.services.flatMap(\.1).contains(where: { $0.0 == characteristic && $0.1 & 4 != 0 })
      else {
        return [reply(characteristic, result: 5)]
      }
      if enabled == 1 {
        subscriptions.insert(characteristic)
      } else {
        subscriptions.remove(characteristic)
      }
      return [reply(characteristic)]
    case 4:
      guard payload.count >= 17 else { return [reply(result: 6)] }
      guard characteristic == ZwiftWire.rx else { return [reply(characteristic, result: 5)] }
      let request = Data(payload.dropFirst(16))
      var result = [reply(characteristic)]
      if let response = try ZwiftWire.response(to: request) {
        if request.starts(with: Data("RideOn".utf8)) { handshakeComplete = true }
        if request.first == 0, try Proto.integerField(1, in: Data(request.dropFirst())) == 0x400 {
          inputConfigurationRead = true
        }
        if let notification = notification(ZwiftWire.tx, response) { result.append(notification) }
      }
      return result
    case 7: return [reply(payload)]
    default: return [reply(result: 1)]
    }
  }
}
