# Zwift Shifter investigation and maintenance guide

This file is the detailed project journal and tutorial requested for this repository. It explains what was investigated, what was measured, why the final mechanism works, why earlier mechanisms failed, and how to reproduce the discovery process on a fresh Zwift client.

The notes are deliberately detailed, but session credentials, account identifiers, Bluetooth MAC addresses, the live peripheral UUID, and ASLR-dependent addresses are represented with placeholders. Those values are not needed to understand or build the project and should not be committed.

## 1. Goal and acceptance test

The goal was not to make a theoretical protocol decoder. The acceptance test was:

```text
press a button in a Mac app
    -> the currently running Zwift session receives a shift event
    -> the displayed gear changes by exactly one
```

The final live acceptance test was run on an active Zwift map:

1. The clean session displayed gear 8.
2. The rebuilt app's `SHIFT LEFT` changed it to gear 7.
3. The app's `SHIFT RIGHT` changed it back to gear 8.
4. Six rapid alternating app commands ended at the expected gear 8.
5. KICKR CORE and Click remained Bluetooth-connected.
6. The shifter app was terminated and reopened while Zwift remained open.
7. The reopened app immediately reused the resident bridge and changed gear 8 to gear 7.

The slower first implementation had already proved the protocol bytes. The fast implementation was accepted only after the clean-session test and the app-reopen test passed.

## 2. The actual local setup

The initial process inspection found a running Apple Silicon Zwift game process named:

```text
ZwiftAppSilicon
```

The app was running from Zwift's user Application Support directory. The important user data locations were:

```text
~/Documents/Zwift/Logs/Log.txt
~/Documents/Zwift/prefs.xml
~/Documents/Zwift/knowndevices.xml
~/Documents/Zwift/Gear/<player-id>/gearing.files
~/Library/Application Support/Zwift/
```

The running session had:

- a Wahoo KICKR CORE connected over Bluetooth
- a Click controller connected over Bluetooth
- the controller selected in Zwift as `ZP User Input`
- virtual shifting enabled by Zwift
- a Click device with `BC2`/Click v2 indicators in the local preferences and log
- Click firmware shown by Zwift as `1.1.0`

The process command line contained authentication material. It was inspected only to identify the process and was never copied into the project or documentation. Do not paste Zwift process arguments into a public issue or commit.

The current app intentionally does not parse or store any token. It only runs `pgrep -x ZwiftAppSilicon` and reads a controller UUID pattern from `Log.txt`.

## 3. First protocol investigation

### 3.1 Zwift keyboard support

The Zwift keyboard-shortcut documentation and the local client behavior were checked first. Zwift supports keyboard actions such as navigation, camera changes, power-ups, menu controls, and action-bar operations. The left and right arrow keys normally choose a turn at an intersection; they are not virtual gear commands.

The research result was:

```text
CGEvent or a normal keyboard mapper can make Zwift perform keyboard actions,
but keyboard input does not expose the virtual-shifting action.
```

Therefore the app does not map its buttons to `+`, `-`, `I`, `K`, or arrow keys and claim that this is shifting. The arrow shortcuts in the UI trigger the app's own bridge command, not Zwift's normal arrow-key behavior.

### 3.2 Existing protocol research

The following public projects and technical references were reviewed:

- Zwift Click Handler: https://github.com/jat255/zwift_click_handling
- Zwift Play reverse engineering: https://github.com/ajchellew/zwiftplay
- Makinolo's Play protocol write-up: https://www.makinolo.com/blog/2023/10/08/connecting-to-zwift-play-controllers/
- OpenBikeControl/BikeControl: https://github.com/OpenBikeControl/bikecontrol
- Current protocol definitions: https://github.com/jonasbark/swiftcontrol/blob/f7bfd8c2/lib/bluetooth/protocol/zwift.proto
- QZ Direct Connect discussion: https://github.com/cagnulein/qdomyos-zwift/discussions/2967
- DirCon library: https://github.com/Berg0162/DirCon
- SHIFTR: https://github.com/JuergenLeber/SHIFTR
- Zwift keyboard shortcuts: https://support.zwift.com/en_us/keyboard-shortcuts-rkGrgwd4B
- Zwift virtual shifting overview: https://zwiftinsider.com/virtual-shifting/
- Zwift shift style and gear range: https://support.zwift.com/en_us/shift-style-and-gear-range-rksYezzIC

The important distinction was between three protocols:

1. Legacy Click v1 uses a `0x37` Click keypad protobuf-like message.
2. Play uses encrypted proprietary traffic with ECDH/HKDF/AES-CCM.
3. Current Click v2 uses the Ride-style `0x23` controller bitmap path over the `FC82` service.

The active device was not the legacy v1 path. Zwift's own log showed `FC82`, BC2 state, firmware 1.1.0, and the selected input role. Sending a valid-looking `0x37` frame produced no gear change, which was an important negative result.

### 3.3 Why not connect to the physical Click from the app

CoreBluetooth can query system presence and can connect as a central, but it cannot passively mirror notifications owned by Zwift. A second central connection would also risk disturbing the active device and would require the Click handshake/session behavior.

The original local `ZwiftClickSafe` project was intentionally passive. It confirmed that the Click appeared as BLE and that the Click notification stream was not globally exposed as HID input. That project was useful evidence, but its no-op shift sink could never satisfy the acceptance test.

The final app therefore does not connect to the Click. It reuses Zwift's existing selected-device identity after Zwift has already completed Bluetooth setup.

## 4. Local Zwift inspection

### 4.1 Runtime log evidence

Targeted searches in `~/Documents/Zwift/Logs/Log.txt` showed the relevant sequence:

```text
... adding component type: 23 (BLE)
... Device selected for role ... ZP User Input
... Zwift Click ... connected
... Did discover service ... FC82
... firmware version: 1.1.0
... Comms established with Zwift Click
... Requesting input configuration
... Enabled virtual shifting on KICKR CORE
```

The actual UUIDs and addresses were not committed. In the tutorial they are represented as:

```text
<CLICK_PERIPHERAL_UUID>
<TRAINER_PERIPHERAL_UUID>
```

The selected Click's normal battery notification reached Zwift's bridge as a three-byte `NSData` value equivalent to:

```text
19 10 64
```

That was useful because it supplied a safe, recurring event for locating the bridge. `0x19` is the battery notification opcode and the value represented 100 percent in the live session.

### 4.2 Preferences and device role

Targeted preference entries showed:

```xml
<LASTZPUSERINPUTDEVICE>...</LASTZPUSERINPUTDEVICE>
<VIRTUAL_SHIFTING_ENABLED>1</VIRTUAL_SHIFTING_ENABLED>
```

The preferences also contained a BC2 orientation entry. This established that the selected controller was a Click v2 device rather than a generic keyboard or HID gamepad.

The key consequence is that the app can send a controller event only because Zwift already has a live ZP User Input device and has enabled virtual shifting. This is why the app is not fully hardware-independent.

## 5. Attempts that were not used in the final implementation

### 5.1 Keyboard injection

Tried/researched:

- macOS `CGEvent` keyboard events
- normal Zwift arrow keys
- documented keyboard shortcuts
- existing gamepad-to-keyboard mappers

Result:

- standard keyboard actions work
- virtual gear shifting is not exposed as a standard Zwift keyboard action
- not used for shifting

### 5.2 Generic gamepad and virtual HID

Tried/researched:

- generic SDL/gamepad mappings
- `IOHIDUserDevice`
- CoreHID virtual devices
- DriverKit virtual HID

Result:

- a generic gamepad is not automatically a Zwift ZP User Input controller
- CoreHID/virtual HID routes require restricted entitlements or a system extension for a distributable production device
- even a virtual gamepad descriptor would not prove that Zwift maps its buttons to virtual gears
- not used

### 5.3 macOS BLE peripheral emulation

A temporary CoreBluetooth `CBPeripheralManager` test was compiled and run. It showed that the peripheral manager could contact the macOS Bluetooth service, but the system logged:

```text
The advertisement key 'Manufacturer Data' is not allowed
```

A same-Mac CoreBluetooth central-to-peripheral loopback was not established. Apple also restricts some HID-over-GATT advertisement behavior. A real separate radio/device or a tested network bridge would be needed to make this reliable.

The temporary test source was outside this repository and was not committed.

### 5.4 Zwift Click/Play encrypted GATT emulation

Play and newer controller paths use a handshake involving:

- secp256r1 ECDH
- HKDF-SHA256
- AES-CCM
- session counters and authentication tags

This was researched from the public Play reverse engineering work. It was not implemented because the live device path exposed a simpler post-BLE bridge and because direct GATT emulation would either require replacing Zwift's device connection or a second Bluetooth peripheral.

### 5.5 Wahoo Direct Connect / mDNS controller emulation

DirCon and QZ were researched as possible network-presented trainer/controller devices. The Direct Connect transport can expose BLE-style services over TCP, and public projects implement trainer proxy behavior.

What was not proven here:

- that a minimal macOS-local DirCon server advertising only a Zwift controller would be accepted as the selected ZP User Input role
- the full Wahoo KICKR Bike Shift controller handshake and identity requirements
- a stable same-host mDNS/TCP controller emulator for this Zwift build

It was not used because the internal bridge reached the actual HUD with much less unverified protocol work.

### 5.6 Direct trainer resistance writes

The proprietary trainer protocol contains a gear-ratio/physical parameter path. Directly changing trainer resistance could make the ride feel different, but it would not necessarily update Zwift's selected gear HUD. Since the acceptance test explicitly required the displayed in-game gear to change, direct trainer writes were not chosen as the primary path.

### 5.7 Memory-only gear-variable edits

A memory edit to a displayed gear integer would be cosmetic and would not necessarily send the correct resistance command to the trainer. No such edit is used.

## 6. Finding the live event path

This section records the exact debugging trail.

### 6.1 LLDB attachment test

The Zwift binary was not hardened with code-signing flags that prevented this experiment. A non-destructive attach/detach test succeeded:

```sh
lldb -p <ZWIFT_PID> -o 'process detach' -o quit
```

The process was stopped briefly and resumed after detaching. SIP remained enabled; Developer Mode was disabled, but the signed-in user could attach to the owned Zwift process with the installed Xcode LLDB.

Always detach before quitting LLDB. A mistaken early experiment quit while still attached and caused Zwift to perform a clean save/logout. No activity data was lost, but the correct rule is:

```text
process detach
quit
```

### 6.2 Finding SwiftBLEInterface

The Objective-C runtime was queried from LLDB. The visible class list included:

```text
ble_middleware.SwiftBLEInterface
BLEDelegate
CBPeripheral
CBPeripheralManager
```

The visible methods of `ble_middleware.SwiftBLEInterface` included:

```text
peripheral:didUpdateValueForCharacteristic:error:
peripheral:didDiscoverServices:
peripheral:didDiscoverCharacteristicsForService:error:
centralManager:didDiscoverPeripheral:advertisementData:RSSI:
writeCharacteristic:characteristicUUIDString:value:
```

The callback entry point was useful for tracing, but its call stack stopped at CoreBluetooth and then entered a Swift bridge/thunk. It did not itself expose a convenient stable public function to call.

### 6.3 Finding BridgeInterface

The next search looked for the bridge selector that appeared in the call path. The exact runtime selector was:

```text
addCharacteristicNotificationEvent:serviceId:characteristicId:characteristicFlags:value:length:
```

The following LLDB-style runtime enumeration was used. It is a discovery procedure, not a build-time requirement:

```text
expr -l objc++ -- @import ObjectiveC
expr -l objc++ -- @import Foundation
expr -l objc++ -- SEL $targetSel = sel_registerName("addCharacteristicNotificationEvent:serviceId:characteristicId:characteristicFlags:value:length:")
expr -l objc++ -- int $n = (int)objc_getClassList(NULL, 0)
expr -l objc++ -- Class *$classes = (Class *)malloc(sizeof(Class) * $n)
expr -l objc++ -- (void)objc_getClassList($classes, $n)
```

Each class's direct method list was inspected with `class_copyMethodList`. The relevant result was:

```text
BridgeInterface | <IMP> | v64@0:8@16@24@32Q40@48q56
```

The method type encoding means:

```text
return: void
self:    @ at offset 0
_cmd:    : at offset 8
arg 1:   @ at offset 16
arg 2:   @ at offset 24
arg 3:   @ at offset 32
arg 4:   Q at offset 40
arg 5:   @ at offset 48
arg 6:   q at offset 56
```

On arm64, the live call registers at the method's entry are therefore:

```text
x0 = BridgeInterface receiver
x1 = selector
x2 = peripheral identifier string
x3 = service identifier string
x4 = characteristic identifier string
x5 = UInt64 characteristic flags
x6 = NSData value
x7 = Int64 value length
```

### 6.4 Breakpoint at the bridge call

The callback's implementation was disassembled. The code built the bridge arguments and called the Objective-C method. A breakpoint at that `objc_msgSend` call showed a live event equivalent to:

```text
x2 = <CLICK_PERIPHERAL_UUID>
x3 = FC82
x4 = 00000002-19CA-4651-86E5-FA29DCDD09D1
x5 = 0x10
x6 = NSData(<19 10 64>)
x7 = 3
```

This was the decisive point: Zwift was already accepting controller events through a plain in-process bridge object. There was no need to own a second GATT connection.

### 6.5 Runtime action-string inspection

The Zwift binary contained readable action names including:

```text
gameplay_ztap_shiftup_down
gameplay_ztap_shiftup_up
gameplay_ztap_shiftdown_down
gameplay_ztap_shiftdown_up
gameplay_direct_cassette_shiftup
gameplay_direct_cassette_shiftdown
```

The strings were found with:

```sh
strings -a -n 5 "/Users/<you>/Library/Application Support/Zwift/ZwiftAppSilicon"
```

The action names appeared in the string section around file offsets equivalent to:

```text
0x228ed1f
0x228ed3a
0x228ed53
0x228ed70
```

Those offsets and any resulting pointers are ASLR/build-version dependent. They are included here only to explain the investigation; the app does not use them.

The executable was stripped of useful named symbols, so an initial `nm` search for `shift`, `gear`, or `zp_user_input` did not produce callable symbols. `otool` showed the relevant `__TEXT`, `__TEXT.__cstring`, `__DATA_CONST`, and `__DATA` sections.

A temporary Capstone-based disassembler was used to inspect arm64 `ADRP` references. There were no simple direct references for each action string; the strings were accessed through tables/relative data instead.

The loaded `__DATA_CONST` and writable regions were dumped through LLDB and a temporary Python scanner searched for pointers to the runtime action strings. A table was found with entries approximately 0x28 bytes apart. Candidate function/data addresses were identified around the action names, but breakpoints on those candidates did not fire for the live injected event. They were registration/table metadata, not the final gear action entry point. This line of investigation was abandoned once the bridge-level injection was proven.

The scanner read many readable process regions. It was used only for this locally running process and its output was not placed in the repository. Never commit a memory dump.

## 7. First working packet experiment

The first packet attempt deliberately used the legacy Click v1 frame:

```text
37 10 01
```

It reached the bridge call but did not change the HUD because the live device was Click v2/BC2 and Zwift was using the Ride-style `0x23` path.

The current Ride-style frames were then generated from a `uint32 ButtonMap`:

```text
released = 0xffffffff
pressed = 0xffffffff & ~mask
```

The varint results were:

```text
mask 0x0200 -> 23 08 ff fb ff ff 0f
mask 0x1000 -> 23 08 ff df ff ff 0f
release     -> 23 08 ff ff ff ff 0f
```

With the live bridge receiver and the selected Click peripheral UUID supplied as `x2`, a direct LLDB expression sent the press and release frames. The exact live result was:

```text
GEAR 8 -> GEAR 7 for 0x0200
GEAR 7 -> GEAR 8 for 0x1000
```

The direction names in the app are based on this observed result.

The successful one-shot LLDB call used the Objective-C message send form below. The real UUID is intentionally replaced:

```text
expr -l objc++ -- (void)({
  SEL $event = NSSelectorFromString(@"addCharacteristicNotificationEvent:serviceId:characteristicId:characteristicFlags:value:length:");
  unsigned char $pressBytes[] = {0x23, 0x08, 0xff, 0xfb, 0xff, 0xff, 0x0f};
  NSData *$press = [NSData dataWithBytes:$pressBytes length:7];
  ((void (*)(id, SEL, id, id, id, unsigned long, id, long))objc_msgSend)(
    (id)$x0,
    $event,
    @"<CLICK_PERIPHERAL_UUID>",
    @"FC82",
    @"00000002-19CA-4651-86E5-FA29DCDD09D1",
    16,
    $press,
    7
  );
  unsigned char $releaseBytes[] = {0x23, 0x08, 0xff, 0xff, 0xff, 0xff, 0x0f};
  NSData *$release = [NSData dataWithBytes:$releaseBytes length:7];
  ((void (*)(id, SEL, id, id, id, unsigned long, id, long))objc_msgSend)(
    (id)$x0,
    $event,
    @"<CLICK_PERIPHERAL_UUID>",
    @"FC82",
    @"00000002-19CA-4651-86E5-FA29DCDD09D1",
    16,
    $release,
    7
  );
})
```

That expression was a prototype only. Keeping it on every button press caused the lag, which led to the resident bridge.

## 8. Resident bridge iterations

### 8.1 Failed permanent swizzle

The first resident dynamic library replaced the BridgeInterface method and ran on every event. It performed original-event forwarding, packet inspection, a command queue, and synthetic event forwarding.

Under rapid input it caused Zwift's BLE module to destabilize. The live log showed a Bluetooth disconnect and Zwift singleton/BLE initialization assertions. One no-delay direct-socket command could also be interpreted as three gear changes.

This implementation was discarded. It is not part of the final source.

### 8.2 Capture-and-restore bridge

The final library uses a much smaller lifecycle:

1. A constructor starts a hook-install thread and a socket-server thread.
2. The hook-install thread waits for `BridgeInterface` and the exact selector.
3. It records the original IMP and replaces the selector temporarily.
4. The first `CaptureEvent` call stores the live receiver.
5. It immediately restores the original IMP.
6. It forwards that original event unchanged.
7. Later commands call the stored original IMP directly; the replacement is no longer installed.

This prevents the bridge from touching every future BLE event.

The socket protocol is:

```text
S
D|<CLICK_PERIPHERAL_UUID>
U|<CLICK_PERIPHERAL_UUID>
```

The library's command sender creates immutable `NSData` objects, then performs:

```text
originalEvent(..., pressFrame, 7)
sleep 80 ms
originalEvent(..., releaseFrame, 7)
sleep 80 ms
```

The first direct-socket prototype omitted those delays. One command changed three gears. Adding the delays produced exactly one gear per command.

The final bridge does not keep a permanent method hook. That change was the main stability fix.

## 9. App implementation details

### 9.1 `ZwiftBridge.swift`

The Swift actor is responsible for:

- finding the PID with `pgrep -x ZwiftAppSilicon`
- finding the most recent Click connection UUID with this log pattern:

```text
\[ UUID: ([0-9A-Fa-f-]{36}) \] Zwift Click
```

- connecting to `/tmp/zwift-shifter-<uid>.sock`
- loading the bundled dylib exactly once for a new PID
- polling for the bridge's `R` status
- sending `D|UUID` or `U|UUID`

The bundle path is resolved as:

```text
Bundle.main.resourceURL/ZwiftShiftBridge.dylib
```

The one-time load command is conceptually:

```text
xcrun lldb -p <PID>
expr -l objc++ -- @import Darwin
expr -l objc++ -- (void *)dlopen("<BUNDLED_BRIDGE_PATH>", 2)
process detach
quit
```

The code intentionally verifies that LLDB detached and did not report an error. It does not leave a debugger attached.

### 9.2 `ZwiftShiftBridge.m`

The Objective-C library:

- uses Objective-C runtime lookup, not a hardcoded Zwift function address
- uses `method_setImplementation` only long enough to capture a receiver
- restores the original method after the first event
- uses a Unix stream socket rather than a network port
- sets socket mode to `0600`
- accepts one request per connection
- passes the Click UUID supplied by the app
- sends exact `0x23` frames
- spaces press and release by 80 ms

The library has no account/network API, no Bluetooth central, and no HID device.

### 9.3 UI

`ContentView.swift` is intentionally small. The buttons use SwiftUI keyboard shortcuts:

```text
left arrow  -> easier
right arrow -> harder
```

The UI shows:

- bridge/ Zwift status
- last command
- number of commands sent

The arrow shortcuts are attached to the same `model.shift()` calls as the buttons. They are not forwarded as normal keyboard events to Zwift.

## 10. Exact verification journal

### 10.1 One-shot prototype

The one-shot LLDB prototype was run while Zwift showed a live gear HUD. It proved:

```text
v2 left/easier frame -> one downshift
v2 right/harder frame -> one upshift
```

The legacy `0x37` frame did nothing.

### 10.2 No-delay resident attempt

A resident library was loaded and sent a single direct-socket command with no press/release delay. The HUD moved several gears instead of one and the session later showed a Bluetooth disconnect. This was the failed implementation that motivated the capture-and-restore redesign.

### 10.3 Delayed resident test

The redesigned test library was loaded into a clean enough process and the local client measured:

```text
status:       approximately 0 ms socket response
one command:  approximately 161–170 ms
six commands: each approximately 160–170 ms
```

The gear changes were exactly one step each:

```text
D: 3 -> 2
U: 2 -> 3
D U D U D U: final gear unchanged from its starting point
```

The KICKR CORE and Click remained connected after the sequence.

### 10.4 Clean final bridge test

Because several experimental dylibs had been loaded during investigation, Zwift was closed through its normal window control and relaunched. This removed the experimental libraries from the process.

The final bundled app then loaded only the final bridge. On the active map:

```text
starting HUD: GEAR 8
app SHIFT LEFT:  GEAR 8 -> GEAR 7
app SHIFT RIGHT: GEAR 7 -> GEAR 8
rapid D U D U D U: final GEAR 8
Bluetooth: KICKR CORE and Click connected
```

### 10.5 App quit/reopen test

The shifter app was terminated while Zwift remained on the map. The socket file remained because the bridge belongs to the Zwift process, not the UI process. The app was reopened and reported ready without a second LLDB load. One app click changed:

```text
GEAR 8 -> GEAR 7
```

This confirms that quitting/reopening the app works as long as Zwift remains running and the selected Click v2 session remains available.

## 11. What was not claimed

The following claims would be inaccurate and should not be added without a new test:

- “Works with no Click hardware connected.”
- “Uses the legacy Click v1 protocol.”
- “Uses Zwift's public shifting API.”
- “Works with every Zwift version.”
- “Never touches Zwift's process.”
- “Has no debugger dependency.”
- “Can be distributed through the Mac App Store unchanged.”
- “The virtual HID path was proven.”
- “The mDNS/DirCon controller path was proven.”

The accurate claim is:

```text
On the tested Zwift Apple Silicon build, with a selected connected Click v2
providing Zwift's ZP User Input capability, the app injects the verified
controller frames after Zwift's BLE bridge and shifts the displayed gear.
```

## 12. Troubleshooting procedure

### App says `Zwift is not running`

Check:

```sh
pgrep -x ZwiftAppSilicon
```

The app intentionally targets the game process, not only the launcher.

### App says `Zwift Click session not found`

Check that Zwift has selected the controller as `ZP User Input`, then inspect only the relevant log lines:

```sh
grep -nE 'ZP User Input|BLE CONNECTED.*Zwift Click|firmware version|Enabled virtual shifting' \
  "$HOME/Documents/Zwift/Logs/Log.txt"
```

Do not paste the complete log into a public report; it may contain account/session metadata.

### App says `Could not load bridge`

Check:

```sh
xcrun lldb --version
ls -l build/ZwiftShifter.app/Contents/Resources/ZwiftShiftBridge.dylib
```

Also confirm that the signed-in user owns the Zwift process. The app is not sandboxed and the bundle is ad-hoc signed.

### App says `Bridge did not start` or stays connecting

The library may not have captured the first event yet. Confirm the trainer/controller is actively connected and wait for Zwift's normal BLE traffic. A Zwift update may also have removed or renamed `BridgeInterface` or the notification selector.

### Command fails in ERG mode

Zwift may reject virtual shifts during an ERG workout block. Test in free ride or another Zwift mode where the client permits virtual shifting.

### Gear changes by more than one

Do not remove the 80 ms press/release spacing. Check that only one copy of the bridge is loaded in a fresh Zwift process. Experimental libraries from debugging should be removed by restarting Zwift.

## 13. Repeating the reverse-engineering work after a Zwift update

If a future build stops working:

1. Locate the new `ZwiftAppSilicon` PID.
2. Confirm the selected device role and controller service in `Log.txt`.
3. Attach LLDB and enumerate `ble_middleware.SwiftBLEInterface` methods.
4. Locate the bridge callback that forwards characteristic notifications.
5. Find the `BridgeInterface` method receiving peripheral/service/characteristic/value arguments.
6. Inspect its Objective-C type encoding.
7. Break at the method entry or call site and inspect the registers for a normal battery event.
8. Confirm whether the current controller still uses `0x23` and whether the mask direction is unchanged.
9. Run the packet experiment with a single shift and a screenshot/HUD check.
10. Restart Zwift before testing a revised resident library.
11. Test one command, opposite direction, six alternating commands, and app quit/reopen.

Do not jump directly to changing packets based on an old public enum. First identify the live service, characteristic, method encoding, and HUD result.

## 14. Source and protocol references

Public references used during investigation:

- https://github.com/jat255/zwift_click_handling
- https://github.com/ajchellew/zwiftplay
- https://www.makinolo.com/blog/2023/10/08/connecting-to-zwift-play-controllers/
- https://github.com/OpenBikeControl/bikecontrol
- https://github.com/jonasbark/swiftcontrol/blob/f7bfd8c2/lib/bluetooth/protocol/zwift.proto
- https://github.com/cagnulein/qdomyos-zwift/discussions/2967
- https://github.com/Berg0162/DirCon
- https://github.com/JuergenLeber/SHIFTR
- https://support.zwift.com/en_us/keyboard-shortcuts-rkGrgwd4B
- https://zwiftinsider.com/virtual-shifting/
- https://support.zwift.com/en_us/shift-style-and-gear-range-rksYezzIC

The most useful implementation reference was the current OpenBikeControl source for the Ride-style emulator. The most useful live evidence was not a public enum; it was the actual gear HUD response after sending each candidate frame.

## 15. Maintenance rules

- Do not add real Zwift tokens, refresh tokens, account IDs, MAC addresses, or full process command lines to this repository.
- Do not commit memory dumps, screenshots containing personal data, or generated `.app` bundles.
- Do not remove the 80 ms timing without a live one-gear-per-command test.
- Do not replace the runtime selector lookup with an ASLR-dependent address.
- Restart Zwift after testing a resident bridge iteration.
- Keep the README's hardware dependency statement accurate.
- Run `swift test`, `./build-app.sh`, and code-signature verification before committing.
