"""Bounded, local-only DirCon experiment. A sent frame is NOT proof of a shift.

Run with .venv/bin/python Experiments/network/dircon_probe.py --address LOCAL_IPV4
Control with a newline-delimited up/down/status on 127.0.0.1:54873.
Protocol independently implemented from framing evidence and observed requests.
"""

import argparse
import asyncio
import contextlib
import datetime
import json
import socket
import struct
import uuid

from zeroconf import IPVersion, ServiceInfo
from zeroconf.asyncio import AsyncZeroconf


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    return varint((number << 3) | 2) + varint(len(value)) + value


def read_varint(data, offset=0):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError("truncated varint")
        b = data[offset]
        offset += 1
        value |= (b & 127) << shift
        if b < 128:
            return value, offset
    raise ValueError("oversized varint")


def uid(value):
    if len(value) == 4:
        value = f"0000{value}-0000-1000-8000-00805f9b34fb"
    return uuid.UUID(value).bytes


SERVICE = uid("fc82")
ASYNC = uid("00000002-19ca-4651-86e5-fa29dcdd09d1")
RX = uid("00000003-19ca-4651-86e5-fa29dcdd09d1")
TX = uid("00000004-19ca-4651-86e5-fa29dcdd09d1")
SERVICES = {
    SERVICE: [(ASYNC, 4), (RX, 2), (TX, 4)],
    # Discovery bootstrap only: no power samples are generated or transmitted.
    uid("1818"): [(uid("2a63"), 4), (uid("2a65"), 1), (uid("2a5d"), 1)],
    uid("180a"): [(uid(x), 1) for x in ["2a29", "2a24", "2a25", "2a26", "2a27"]],
    uid("180f"): [(uid("2a19"), 5)],
}
READ_VALUES = {
    uid("2a65"): bytes(4),
    uid("2a5d"): bytes([0]),
    uid("2a29"): b"ZwiftShift Research",
    uid("2a24"): b"Software Controller",
    uid("2a25"): b"100000001",
    uid("2a26"): b"1.0.0",
    uid("2a27"): b"1",
    uid("2a19"): bytes([100]),
    TX: b"",
}


def log(event, **values):
    print(json.dumps({"time": datetime.datetime.now().isoformat(), "event": event, **values}), flush=True)


class Probe:
    def __init__(self, address):
        self.address = address
        self.clients = {}
        self.handshakes = 0

    async def frame(self, writer, kind, seq, payload=b"", result=0):
        data = struct.pack(">BBBBH", 1, kind, seq, result, len(payload)) + payload
        log("tx", packet=data.hex())
        writer.write(data)
        await writer.drain()

    async def notify(self, writer, characteristic, payload):
        if characteristic in self.clients.get(writer, set()):
            await self.frame(writer, 6, 0, characteristic + payload)
        else:
            log("not_subscribed", characteristic=str(uuid.UUID(bytes=characteristic)))

    async def zp(self, writer, data):
        log("zp_request", data=data.hex())
        if data.startswith(b"RideOn"):
            self.handshakes += 1
            await self.notify(writer, TX, b"RideOn\x02\x00")
        elif data[:1] == b"\x00" and len(data) >= 3:
            page, _ = read_varint(data, 2)
            if page == 0:
                # Installed nanopb decoder has strict byte-array lengths. Start
                # with optional strings omitted; only classify capabilities.
                info = (field(1, 0x200) + field(8, field(1, 2) + field(2, 1))
                        + field(9, 0xffff) + field(10, 1))
                # Zwift 1.125 expects DevInfo { devInfo: DevInfoPage } for DO 0.
                info = field(1, info)
            elif page == 0x400:
                info = field(1, 0x1100) + field(2, 0)
            elif page == 0x303:
                info = field(1, 0) + field(2, 100) + field(3, 0) + field(4, 0)
            else:
                info = b""
            await self.notify(writer, TX, b"\x3c" + field(1, page) + field(2, info))
        else:
            log("unhandled_zp", data=data.hex())

    async def client(self, reader, writer):
        peer = writer.get_extra_info("peername")
        if peer[0] not in ("127.0.0.1", self.address):
            writer.close()
            return
        log("connected", peer=peer)
        self.clients[writer] = set()
        try:
            while True:
                header = await reader.readexactly(6)
                version, kind, seq, _, length = struct.unpack(">BBBBH", header)
                if version != 1 or length > 4096:
                    raise ValueError("invalid frame header")
                payload = await asyncio.wait_for(reader.readexactly(length), 5)
                log("rx", packet=(header + payload).hex())
                characteristic = payload[:16]
                if kind == 1:
                    await self.frame(writer, kind, seq, b"".join(SERVICES))
                elif kind == 2 and len(payload) == 16:
                    entries = SERVICES.get(payload)
                    await self.frame(writer, kind, seq,
                                     payload + b"".join(c + bytes([p]) for c, p in entries) if entries else b"",
                                     0 if entries else 3)
                elif kind == 3:
                    value = READ_VALUES.get(characteristic)
                    await self.frame(writer, kind, seq, characteristic + (value or b""), 0 if value is not None else 4)
                elif kind == 5 and len(payload) == 17:
                    if payload[16]:
                        self.clients[writer].add(characteristic)
                    else:
                        self.clients[writer].discard(characteristic)
                    await self.frame(writer, kind, seq, characteristic)
                elif kind == 4 and len(payload) >= 16:
                    await self.frame(writer, kind, seq, characteristic)
                    if characteristic == RX:
                        await self.zp(writer, payload[16:])
                elif kind == 7:
                    await self.frame(writer, kind, seq, payload)
                else:
                    await self.frame(writer, kind, seq, result=1)
        except (asyncio.IncompleteReadError, TimeoutError, ConnectionError, ValueError) as error:
            log("disconnected", reason=str(error))
        finally:
            self.clients.pop(writer, None)
            writer.close()
            with contextlib.suppress(ConnectionError):
                await writer.wait_closed()

    async def control(self, reader, writer):
        try:
            command = (await asyncio.wait_for(reader.readline(), 2)).decode().strip()
            if command.startswith("notify "):
                for client in list(self.clients):
                    await self.notify(client, TX, bytes.fromhex(command[7:]))
            if command in ("up", "down"):
                mask = 0x1000 if command == "up" else 0x100
                for client in list(self.clients):
                    await self.notify(client, ASYNC, b"\x23" + field(1, 0xffffffff ^ mask))
                    await asyncio.sleep(0.08)
                    await self.notify(client, ASYNC, b"\x23" + field(1, 0xffffffff))
            writer.write(json.dumps({"clients": len(self.clients), "handshakes": self.handshakes,
                                     "command": command, "gear_change_verified": False}).encode() + b"\n")
            await writer.drain()
        finally:
            writer.close()

    async def keepalive(self):
        while True:
            await asyncio.sleep(5)
            for writer in list(self.clients):
                with contextlib.suppress(ConnectionError):
                    await self.notify(writer, ASYNC, b"\x23" + field(1, 0xffffffff))


async def main(args):
    probe = Probe(args.address)
    service_type = "_wahoo-fitness-tnp._tcp.local."
    service = ServiceInfo(service_type, "ZwiftShift Input." + service_type,
                          addresses=[socket.inet_aton(args.address)], port=54872,
                          properties={"mac-address": "02:5A:53:48:49:47", "serial-number": "100000002",
                                      "ble-service-uuids": "fc82,1818,180a,180f"},
                          server="zwiftshift-research.local.")
    zeroconf = AsyncZeroconf(interfaces=[args.address], ip_version=IPVersion.V4Only)
    server = await asyncio.start_server(probe.client, "0.0.0.0", 54872, limit=8192)
    control = await asyncio.start_server(probe.control, "127.0.0.1", 54873, limit=1024)
    task = asyncio.create_task(probe.keepalive())
    try:
        await zeroconf.async_register_service(service, strict=False)
        log("advertised", type=service_type, port=54872, duration=args.seconds)
        await asyncio.sleep(args.seconds)
    finally:
        task.cancel()
        await zeroconf.async_unregister_service(service)
        await zeroconf.async_close()
        server.close()
        control.close()
        for writer in list(probe.clients):
            writer.close()
        await server.wait_closed()
        await control.wait_closed()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", required=True)
    parser.add_argument("--seconds", type=int, default=600)
    options = parser.parse_args()
    try:
        asyncio.run(main(options))
    except KeyboardInterrupt:
        pass
