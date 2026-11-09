# Isolated research tools

These are bounded experiments, not production backends. The app and CLI need
none of these Python dependencies, external checkouts, or instrumentation.
Results and limitations are recorded in the root `RESEARCH.md` / `FINDINGS.md`.

Run from the project root. Optional Python setup:

```sh
python3 -m venv .venv
.venv/bin/pip install -r Experiments/requirements.txt
```

## HID and desktop input

```sh
clang Experiments/hid/user_device.c -framework CoreFoundation -framework IOKit -o build/hid-probe
build/hid-probe
swiftc Experiments/input/desktop_probe.swift -o build/desktop_probe
build/desktop_probe permissions
build/desktop_probe windows Zwift
```

HID registration is attempted without a driver install and remains alive at most
five seconds. It returned NULL on the test Mac. The desktop probe supports
explicit clicks, key delivery, bounded shortcut holds, and eight-second input
observations. `watch-chords` prints only arrow/modifier codes; `watch-mouse`
prints event origins and coordinates. Input/screenshot permissions apply to this
test utility, not the app's Carbon hotkeys. `direct-click` is an exploratory
PID-directed route that did not activate SwiftUI buttons; it is not used by
acceptance tests.

`activate PID` sets and verifies foreground state through Accessibility.
`element PID IDENTIFIER` returns a native control's screen bounds and enabled
state; `press-element` invokes its accessible press action. A `label:NAME` query
matches a native label/title for ordinary menu and sheet controls. Live mouse
tests activate the app before resolving `shift-up` / `shift-down`, so moving the
window does not require editing test coordinates.

`trace_delivery.py` observes a single explicit click through Cocoa/GLFW and
detaches in `finally`. Its fixed screen coordinates are historical research
coordinates, not a general-purpose pairing automation.

## Bluetooth

`bluetooth/loopback_probe.swift` is a bounded CoreBluetooth central/peripheral
experiment. Its `Info.plist` supplies a Bluetooth usage description for a local
probe bundle. Successful advertisement was observed, but there was no same-Mac
discovery or subscriber. No manufacturer-data or over-the-air claim is made.

## Network

Quit the native app before running the prototype because they use the same
port and this test installation's identity:

```sh
.venv/bin/python Experiments/network/dircon_probe.py --address YOUR_MAC_LAN_IPV4 --seconds 120
```

The prototype advertises a software controller, accepts same-host game peers,
and has a loopback research control port 54873. It sends no power measurements.
Its raw `notify` command exists only to diagnose data-object responses and is
absent from the product. Ctrl-C and the duration limit close its listeners and
withdraw the advertisement. A reported send is explicitly not a gear proof.

## Static analysis and bounded observation

`instrumentation/macho_xrefs.py --help` describes the original read-only Mach-O
cross-reference tool. It uses Capstone and LC_FUNCTION_STARTS to locate string
references and containing functions in the installed arm64 binary.

```sh
.venv/bin/python Experiments/instrumentation/observe.py \
  --pid GAME_PID --script Experiments/instrumentation/trace_shifts.js --seconds 5
```

The offset-based scripts are valid only for **Zwift 1.125.0 (168455)**, UUID
`BEF66B12-36AE-3B61-BAB6-A8FF70F24319`. Confirm that exact build before using
them; offsets are not a stable API. They observe calls and decoder failures,
never invoke a shift function or patch persistent files. Normal LLDB/Frida
attachment worked on the tested signed build without security changes. The
production app uses neither.

`trace_trainer_values.js` observes the existing KICKR BLE value callback without
making another Bluetooth connection or changing subscriptions. Use it through
`observe.py --seconds 20`; it samples selected measurement characteristics at
most once per second and decodes Cycling Power watts. Unlike the offset-based
scripts, it finds the inspected Objective-C class/method and fails if absent.
See [the power investigation](../Documentation/KICKR_POWER.md) for the exact
scope and remaining physical test. Keep raw output in ignored local storage.
