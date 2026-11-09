import Foundation

public enum GearEvent: Equatable {
  case dimensions(Int, Int)
  case position(Int, Int)
  case rearShift(front: Int, from: Int, to: Int)
  case frontShift(from: Int, to: Int, rear: Int)
}

public enum GearParser {
  private static let patterns: [(NSRegularExpression, Int)] = [
    (try! NSRegularExpression(pattern: #"Gearing: Front (\d+), Back (\d+)"#), 0),
    (try! NSRegularExpression(pattern: #"Gearing: (\d+)-(\d+)(?:\s|$)"#), 1),
    (try! NSRegularExpression(pattern: #"Gearing: Shift (\d+)-\((\d+) -> (\d+)\)"#), 2),
    (try! NSRegularExpression(pattern: #"Gearing: Shift \((\d+) -> (\d+)\)-(\d+)"#), 3),
  ]
  public static func parse(_ line: String) -> GearEvent? {
    guard line.contains("Gearing: ") else { return nil }
    let range = NSRange(line.startIndex..., in: line)
    for (regex, kind) in patterns {
      guard let match = regex.firstMatch(in: line, range: range) else { continue }
      let values = (1..<match.numberOfRanges).compactMap {
        Range(match.range(at: $0), in: line).flatMap { Int(line[$0]) }
      }
      guard values.count == match.numberOfRanges - 1 else { return nil }
      switch kind {
      case 0: return .dimensions(values[0], values[1])
      case 1: return .position(values[0], values[1])
      case 2: return .rearShift(front: values[0], from: values[1], to: values[2])
      default: return .frontShift(from: values[0], to: values[1], rear: values[2])
      }
    }
    return nil
  }
}

public struct GearTracker {
  public private(set) var gear: ObservedGear?
  public private(set) var frontCount: Int?
  public private(set) var rearCount: Int?
  public init() {}
  @discardableResult public mutating func consume(_ event: GearEvent, at date: Date = Date())
    -> Bool
  {
    let front: Int
    let rear: Int
    let changed: Bool
    switch event {
    case .dimensions(let f, let r):
      guard f > 0, r > 0 else { return false }
      frontCount = f
      rearCount = r
      if var current = gear {
        current.frontCount = f
        current.rearCount = r
        gear = current
      }
      return false
    case .position(let f, let r):
      front = f
      rear = r
      changed = false
    case .rearShift(let f, let from, let to):
      front = f
      rear = to
      changed = from != to
    case .frontShift(let from, let to, let r):
      front = to
      rear = r
      changed = from != to
    }
    gear = ObservedGear(
      front: front, rear: rear, frontCount: frontCount, rearCount: rearCount, observedAt: date)
    return changed
  }
}

/// Read-only, bounded, rotation-aware tail of Zwift's own log.
/// Serial access by contract: one caller queue at a time.
public final class GearTelemetry: @unchecked Sendable {
  public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/Zwift/Logs/Log.txt")
  private let url: URL
  private var handle: FileHandle?
  private var inode: UInt64?
  private var offset: UInt64 = 0
  private var pending = Data()
  public private(set) var tracker = GearTracker()
  public var onLine: ((String, Bool) -> Void)?
  public var onEvent: ((GearEvent, Bool) -> Void)?
  public init(url: URL = GearTelemetry.defaultURL) { self.url = url }
  public func reset() {
    try? handle?.close()
    handle = nil
    inode = nil
    offset = 0
    pending = Data()
    tracker = GearTracker()
  }
  public func poll() throws {
    var st = Darwin.stat()
    guard url.withUnsafeFileSystemRepresentation({ Darwin.lstat($0, &st) }) == 0 else {
      return
    }
    let size = UInt64(st.st_size)
    let newInode = st.st_ino
    let historical = handle == nil || inode != newInode || size < offset
    if historical {
      reset()
      handle = try FileHandle(forReadingFrom: url)
      inode = newInode
      offset = size > 16_777_216 ? size - 16_777_216 : 0
      try handle?.seek(toOffset: offset)
    }
    guard size > offset else { return }
    let maximum = historical ? 16_777_216 : 262_144
    let data = try handle?.read(upToCount: min(maximum, Int(size - offset))) ?? Data()
    offset += UInt64(data.count)
    pending += data
    if let end = pending.lastIndex(of: 10) {
      for raw in pending.prefix(through: end).split(separator: 10) {
        let line = String(decoding: raw, as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines)
        if let event = GearParser.parse(line) {
          tracker.consume(event)
          onEvent?(event, historical)
        }
        onLine?(line, historical)
      }
      pending = Data(pending.suffix(from: pending.index(after: end)))
    }
    // A corrupt/giant line must never grow indefinitely.
    if pending.count > 65_536 { pending = Data() }
  }
}
