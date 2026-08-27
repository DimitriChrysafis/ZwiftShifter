import Foundation

public enum ShiftDirection: String, Sendable {
    case easier
    case harder

    public var bridgeCommand: UInt8 {
        switch self {
        case .easier: UInt8(ascii: "D")
        case .harder: UInt8(ascii: "U")
        }
    }

    public var pressPacket: [UInt8] {
        switch self {
        case .easier: [0x23, 0x08, 0xff, 0xfb, 0xff, 0xff, 0x0f]
        case .harder: [0x23, 0x08, 0xff, 0xdf, 0xff, 0xff, 0x0f]
        }
    }

    public static let releasePacket: [UInt8] = [0x23, 0x08, 0xff, 0xff, 0xff, 0xff, 0x0f]
}
