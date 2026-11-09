# KICKR connected but reporting zero watts

Investigation on **2026-11-09**, America/Chicago. **Not yet a verified repair.**
The user reported that pedaling their KICKR CORE 2 did not produce watts in
Zwift. Earlier shifting acceptance was stationary, so it did not establish
working power measurements or trainer load while riding.

## Direct observations

- Zwift 1.125.0 selected **KICKR CORE CED4**, firmware **3.5.24**, over Bluetooth
  for Power Source, Resistance, and Cadence. The software controller was under
  Controls. Saved preferences agreed. The virtual controller sends no power.
- After the user said they would begin pedaling, five captures at
  **14:59:15–14:59:28 CST** still showed **0 watts** on the actual KICKR card.
  These captures do not independently prove when the physical flywheel moved.
- Refreshing Power Source alone left other roles connected to the same BLE
  peripheral. A full reconnect therefore unpaired all KICKR roles, with the
  final physical BLE disconnect logged at **15:03:13**.
- The actual KICKR was then reselected, with a fresh connection and characteristic
  subscriptions. Zwift logged protocol communication established at **15:03:48**.
  Power, Resistance, Cadence, and the previously selected heart-rate bridge were
  restored. The software Controls pairing remained. No shift commands were sent
  during this investigation; the game stayed at gear **5**.
- A bounded, read-only Frida observer watched **Zwift's existing BLE callback**
  for 20 seconds. It did not create another connection, change subscriptions,
  write a characteristic, patch game state, or send a shift. It unloaded and
  detached afterward.
- The KICKR delivered new Cycling Power (`2A63`), FTMS Indoor Bike Data (`2AD2`),
  and Zwift Protocol notifications throughout the capture. Ten sampled Cycling
  Power values at **15:04:24–15:04:42** decoded to **0 watts**. FTMS also carried
  zero speed, cadence, and power. The sampled Cycling Power wheel/crank counters
  were unchanged. This is explicit zero data, not absence of packets.
- A new pedaling confirmation after the reconnect was requested. It is pending
  at this record's creation. Do not label this later capture as a confirmed
  pedaling test or assert a hardware defect from stationary zero measurements.

The game also logged an unknown-device-type capability warning while talking to
the KICKR. That warning's causal relevance is **not established**; the physical
power notifications above arrived independently. Do not change device identity,
trainer firmware, or protocol behavior merely to suppress it.

Reviewed evidence: [sampled power values and detach result](Evidence/kickr-zero-power.json).
The following is an unaltered crop of the game HUD after reconnect, showing
zero watts and the unchanged gear. It is not a successful riding test.

![Zwift still displaying zero watts](../Screenshots/kickr-zero-power.png)

## Reproducible observation

Discover the current Zwift PID with executable-name-only process inspection.
Never print full process arguments; Zwift's launch arguments can include account
credentials. Then, in an appropriate debugging session:

```sh
.venv/bin/python Experiments/instrumentation/observe.py \
  --pid CURRENT_PID \
  --script Experiments/instrumentation/trace_trainer_values.js \
  --seconds 20 > build/kickr-values.jsonl
```

The observer targets the previously inspected
`_TtC14ble_middleware17SwiftBLEInterface` callback and fails if that class/method
is absent. It filters KICKR CORE peripherals, samples selected characteristics
at most once per second, and retains bounded byte prefixes. It is an isolated
diagnostic tool, not a product dependency. Use the existing experiment environment
documented in [Experiments](../Experiments/README.md).

Private originals: `build/power-live-samples/`,
`build/kickr-values-after-reconnect.jsonl`, and `build/kickr-*.png`. Before the
pairing refresh, the three existing configuration XMLs were backed up with hashes
under `LocalEvidence/backups/power-repair-20261109-145750/`. All pairing changes
used Zwift's UI; the installed binary and macOS security settings were preserved.

## 2026-11-09 evening update

Additional same-day findings, after the captures above:

- Zwift logs showed the software device **was selected under Power Source** at
  16:41:50, then the KICKR experienced a real BLE link timeout
  (`CBErrorDomain 6`, link supervision timeout) at 16:44:31 and reconnected at
  16:45:45. Zwift's instant reconnection is normal warm-link behavior, not a
  fake connection.
- A second bounded observer capture (~75 s, 46 Cycling Power notifications)
  delivered byte-identical zero payloads with frozen wheel/crank counters.
  Physical pedaling during that window was **not** confirmed; the zeros are
  consistent with a stationary trainer.
- Comparing the two captures, the KICKR's cumulative revolution counters did
  change between 15:04 and ~16:42, so its measurement path has been alive.
- The wrong-role pairing was manually corrected through Zwift's UI: KICKR for
  Power Source, Resistance, Cadence, and Heart Rate; the software device under
  Controls only. `prefs.xml` was verified to already record the KICKR as
  `LASTPOWERDEVICE` etc., so the wrong Power assignment was live session state.
- The software controller's advertised services were changed from Cycling Power
  `1818` to Heart Rate `180d`. Verified live: the device lists under the Heart
  Rate picker, pairing it there triggers TCP connect and grants component 23
  (Controls), and a `zwiftshift up` produced `Shift 0-(10 -> 11)`. The device no
  longer advertises a power service, although Zwift's Power picker still lists a
  connected ZP device under RECOMMENDED — do not select it there.
- The `ZwiftShift Input` name stayed classified as a power device in Zwift's
  known-device cache (keyed by device name) even after the service swap, so the
  controller identity was renamed to `ZwiftShift` (serial `100000004`, MAC
  `02:5A:53:48:49:49`). With the production app: HR select → Controls pairing →
  `Shift 0-(11 -> 12)` at 17:52:42, with the KICKR holding all four data roles.
- A true pedaling interval is still outstanding. The remaining zero-watt
  question is only whether the trainer emits nonzero values while the flywheel
  turns.

## Next decisive checks

1. Coordinate a fresh 15-second pedaling interval with the user and compare
   trainer notifications and the game's watts. Zero while stationary is expected.
2. If the flywheel is turning and fresh packets still report zero, close other
   trainer-controlling apps on nearby devices and power-cycle the KICKR by
   unplugging it for **30–35 seconds**. This requires a physical action the agent
   cannot perform. Recheck the actual KICKR roles afterward.
3. If it still sends zeros, compare the same physical pedaling in the Wahoo app
   and check firmware using Wahoo's supported workflow. Do not infer that a
   firmware update is required or perform one without a concrete reason.

Steps 2–3 follow [Wahoo's connected-but-no-data troubleshooting](https://support.wahoofitness.com/hc/en-us/articles/115000502070-KICKR-is-connected-but-no-speed-cadence-or-power-data),
read on this date. They are proposed checks, not completed actions or a promised
fix. The current software-only reconnect is complete; a successful watts/riding
test is still required before reporting this issue resolved.
