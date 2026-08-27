import Testing
@testable import ZwiftShifterCore

@Test func easierPacketUsesVerifiedLeftMask() {
    #expect(ShiftDirection.easier.pressPacket == [0x23, 0x08, 0xff, 0xfb, 0xff, 0xff, 0x0f])
    #expect(ShiftDirection.easier.bridgeCommand == UInt8(ascii: "D"))
}

@Test func harderPacketUsesVerifiedRightMask() {
    #expect(ShiftDirection.harder.pressPacket == [0x23, 0x08, 0xff, 0xdf, 0xff, 0xff, 0x0f])
    #expect(ShiftDirection.harder.bridgeCommand == UInt8(ascii: "U"))
}

@Test func releasePacketClearsEveryButton() {
    #expect(ShiftDirection.releasePacket == [0x23, 0x08, 0xff, 0xff, 0xff, 0xff, 0x0f])
}
