# Observed LAN controller protocol

Verified against Zwift 1.125.0 (168455), 2026-11-09. These are interoperable wire
facts checked against the running game. Production code is an original Swift
implementation, not a bundled third-party emulator.

## Discovery and transport

Bonjour service: `_wahoo-fitness-tnp._tcp.local.`; default TCP port **54872**.
TXT keys:

| Key | Value |
|---|---|
| `mac-address` | Stable generated locally administered address |
| `serial-number` | Stable generated decimal identity |
| `ble-service-uuids` | `fc82,1818,180a,180f` |

Identity is saved in `build/runtime/settings.json`. Zwift caches discovery
metadata; changing capabilities under an existing identity may not refresh its
classification immediately. The app permits only same-host TCP peers. Bonjour
advertising itself is visible on the LAN.

FC82-only advertisements were discovered but not selectable as Controls. Service
1818 enables initial Power Source selection and capability interrogation. This
is a discovery bootstrap: **the app never sends Cycling Power measurements**.
The actual trainer must supply power, cadence, and resistance during a ride.

## DirCon framing

Every TCP frame is a six-byte header followed by `length` payload bytes:

| Byte | Meaning |
|---|---|
| 0 | Protocol version `01` |
| 1 | Message kind |
| 2 | Request sequence, echoed in response |
| 3 | Result code; `00` success |
| 4–5 | Payload length, big-endian UInt16 |

Kinds implemented: `01` services, `02` characteristics, `03` read, `04` write,
`05` enable/disable notifications, `06` notification, `07` echo. UUIDs are 16-byte
canonical UUID bytes. Characteristic entries carry a one-byte property mask:
read `01`, write `02`, notify `04`. Frames may be fragmented or coalesced in TCP.
The implementation bounds payloads to 4096 bytes and the decoder to 16 KiB.

Services exposed:

| Service | Characteristics |
|---|---|
| FC82 Zwift Protocol | `00000002-19ca-4651-86e5-fa29dcdd09d1` notify; `...03...` write; `...04...` notify |
| 1818 Cycling Power | 2A63 notify (never emitted), 2A65 feature read, 2A5D location read |
| 180A Device Information | Manufacturer, model, serial, firmware, hardware |
| 180F Battery | 2A19 read/notify, software controller reports 100% |

## Handshake and data objects

Zwift subscribes to characteristics 02 and 04, then writes to 03. Responses
are notifications on 04, separate from the DirCon write acknowledgement.

```text
Zwift → controller: 52 69 64 65 4f 6e 02 04  ("RideOn" 02 04)
controller → Zwift: 52 69 64 65 4f 6e 02 00  ("RideOn" 02 00)
```

This is the unencrypted LAN handshake actually accepted by this build. It does
not establish that BLE controllers use the same handshake. Unknown handshake
variants are rejected rather than silently treated as compatible.

GET requests begin with opcode `00`, then protobuf field 1 containing a data
object ID. GET responses begin `3c`, field 1 = object ID, field 2 = bytes.

| Object | Response contents |
|---|---|
| `0x000` DevInfo | **DevInfo envelope field 1 containing DevInfoPage** |
| `0x010` ClientCfg | Empty bytes, accepted by the tested build |
| `0x400` InputConfig | Field 1 digital mask `0x1100`; field 2 analog mask `0` |
| `0x303` Battery | Fields 1–4: state `0`, percent `100`, time-to-empty `0`, time-to-full `0` |

The minimal DevInfoPage has field 1 protocol `0x200`, field 8 nested capability
{field 1 device type `2`, field 2 capabilities `1`}, field 9 manufacturer `65535`,
field 10 product `1`. Manufacturer/model strings clearly identify software.

The outer DevInfo envelope is essential. Sending the raw page caused the actual
Zwift nanopb decoder to report a wire-type error. Bounded runtime observation
identified the error; wrapping the page made real Controls pairing succeed.
Battery fields 3 and 4 are included explicitly because the tested decoder expects
the complete representation.

Captured/verified response fixtures:

```text
DO 000: 3c080012110a0f08800442040802100148ffff035001
DO 400: 3c08800812050880221000
DO 303: 3c08830612080800106418002000
```

## Button notifications

Characteristic 02 notifications begin with opcode **23**, followed by protobuf
field 1 holding a 32-bit **active-low** button map. Neutral is all ones.

| State | Cleared bit | Notification bytes |
|---|---|---|
| Neutral | none | `2308ffffffff0f` |
| Shift up | `0x1000` | `2308ffdfffff0f` |
| Shift down | `0x0100` | `2308fffdffff0f` |

The input-config mask declares exactly those two bits. A complete shift is a
press for 120 ms followed by neutral. Repeated shifts use repeated transitions,
with a configurable interval between press starts. A neutral keepalive is sent
every four seconds when no pulse is active. Buttons are released on cancellation
and shutdown.

The production backend does not expose arbitrary notification injection. All UI
and CLI shifting passes through the same bounded scheduler and serialization.

## Independent confirmation

Zwift's cassette action logs `Gearing: Shift 0-(8 -> 9)` on upshift and
`Gearing: Shift 0-(9 -> 8)` on downshift. The app reads these lines without
modifying the game. A command is confirmed only if fresh matching one-step
transitions equal its requested count, with no contradictory observed transition.
The gear dimensions come from `Gearing: Front F, Back R`.

There is no command ID in this feedback, so concurrent physical/manual inputs
can make attribution ambiguous. Exact acceptance tests must run without other
controls. Physical trainer resistance is not measured by these log events.
