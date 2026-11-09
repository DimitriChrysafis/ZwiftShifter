# Research references and provenance

These public implementations were inspected for protocol facts and compared
against the installed game. They are not production dependencies. Reference
checkouts stay in ignored `LocalEvidence/references/`; their source and licenses
are not relicensed or bundled in this repository.

| Reference | Exact revision inspected | Useful evidence and limits |
|---|---|---|
| [OpenBikeControl/bikecontrol](https://github.com/OpenBikeControl/bikecontrol/tree/edd1e2a64e29618df475fa98b61bddfa862be793) | `edd1e2a64e29618df475fa98b61bddfa862be793` | Outer controller button maps, FC82 UUIDs, LAN discovery bootstrap, keepalive. Several `prop_public` files explicitly contain fake constants/stubs. At this revision the root license is a non-commercial source-available license, not a blanket open-source license. |
| [JuergenLeber/SHIFTR](https://github.com/JuergenLeber/SHIFTR/tree/058695971df496a00249af63e3a123af19c93830) | `058695971df496a00249af63e3a123af19c93830` | Actual DirCon header, UUID serialization, Bonjour TXT, RideOn exchange. GPL-3.0 source was read, not copied. Its ESP32/physical-controller architecture is not adopted. |
| [ajchellew/zwiftplay](https://github.com/ajchellew/zwiftplay/tree/f1c1fe42ca84df2ef3df23d4132ecc0a4aad9e56) | `f1c1fe42ca84df2ef3df23d4132ecc0a4aad9e56` | Actual Kotlin/C# BLE implementations, ECDH/HKDF/AES-CCM, controller UUIDs. Legacy BLE security is distinct from the observed LAN session. |
| [morluto/rea](https://github.com/morluto/rea) | Repository inspected as the supplied lead | General reverse-engineering tooling; not a Zwift shifting implementation and not installed as a dependency. |

Specific source entry points:

- [BikeControl LAN emulator](https://github.com/OpenBikeControl/bikecontrol/blob/edd1e2a64e29618df475fa98b61bddfa862be793/lib/bluetooth/devices/zwift/ftms_mdns_emulator.dart).
- [SHIFTR DirCon framing](https://github.com/JuergenLeber/SHIFTR/blob/058695971df496a00249af63e3a123af19c93830/src/DirConMessage.cpp)
  and [connection manager](https://github.com/JuergenLeber/SHIFTR/blob/058695971df496a00249af63e3a123af19c93830/src/DirConManager.cpp).
- [ZwiftPlay BLE UUIDs](https://github.com/ajchellew/zwiftplay/blob/f1c1fe42ca84df2ef3df23d4132ecc0a4aad9e56/zaplibrary/src/main/java/com/che/zap/device/common/ZapBleUuids.kt)
  and [crypto implementation](https://github.com/ajchellew/zwiftplay/blob/f1c1fe42ca84df2ef3df23d4132ecc0a4aad9e56/zaplibrary/src/main/java/com/che/zap/crypto/ZapCrypto.kt).

Apple SDK headers supplied primary local documentation for IOHIDUserDevice,
CoreBluetooth advertisement keys, Network.framework, CGEvent, and Carbon hotkey
registration. Installed headers specify only local-name and service-UUID keys
for CoreBluetooth peripheral advertising. The investigation did not claim an
over-the-air manufacturer-data capture.

The original Swift implementation encodes observed interoperable wire formats.
The DevInfo envelope, full battery message, device classification, callback path,
and actual gearing were independently checked against Zwift 1.125.0. Binary
extracts, proprietary resources, account data, and full process command lines are
not distributed. The MIT license covers this project's original code only.
