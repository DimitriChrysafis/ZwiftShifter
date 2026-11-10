# Phone controls

Opening ZwiftShift starts a web server on TCP **54874**. The main window shows
its current address. Open **Phone controls** for a QR code or **Copy private
link**. The fragment in that link carries a randomly generated access key.
Typing the displayed base URL opens the page but does not grant access.

The page shows the gear read from Zwift's log and two shift buttons. A tap sends
one press; a hold sends one confirmed press at a time at the configured repeat
interval. Latency can make Internet holds slower than local controls. Release,
loss of focus, hiding the page, an error, or the 30-second limit stops repetition.
An already transmitted press can finish after release; commands are never
automatically retried or queued for later connection recovery.

## Local and Internet setup

The local URL works while the phone can reach the Mac on the same network.
Allow the app's normal macOS Local Network/firewall access when prompted. Guest
Wi-Fi client isolation may prevent direct access. Local HTTP is unencrypted;
use the ngrok HTTPS link when the network is not trusted.

For Internet access, install and authenticate the official
[ngrok agent](https://ngrok.com/docs/getting-started/) on the Mac. The application
does not create an account or rewrite an existing ngrok configuration. This Mac
already had ngrok **3.39.9** and a working account configuration during testing.

Turn on **Internet access via ngrok**. The setting is saved and reused on launch.
A new installation defaults to enabled. An installation without working ngrok
still serves local controls and shows the tunnel error with **Retry Internet**.
The currently installed user's choice is preserved, including switching it off.

The app checks `/opt/homebrew/bin/ngrok`, `/usr/local/bin/ngrok`, and
`~/.local/bin/ngrok`. `ZWIFTSHIFT_NGROK` overrides the executable. Its default
config is `~/Library/Application Support/ngrok/ngrok.yml`;
`ZWIFTSHIFT_NGROK_CONFIG` overrides that path. Version 2 and 3 config overlays are
supported. The overlay in the private runtime directory disables local traffic
inspection, the ngrok web console, and automatic updates. Only the phone HTTP
port is forwarded. DirCon and the CLI socket are not exposed through ngrok.

The public address may change after relaunch. Scan the current QR code. Free
ngrok accounts may show a **Visit Site** interstitial on first navigation; the
page's API requests include the supported bypass header so that interstitial
is not mistaken for a JSON response. Account limits and ngrok availability still
apply. Startup is bounded to 25 seconds; there is no automatic restart loop.

Both ZwiftShift and Zwift must remain open on the Mac. Normal quit closes the
HTTP server and tunnel. A small bundled CLI worker owns the ngrok process and
watches the app's lifetime through a pipe; it also shuts ngrok down after an app
crash. System sleep can interrupt access; no system sleep prevention is added.

## Access and stored data

The runtime `phone.json` stores the port, Internet preference, and 256-bit
random key. It is mode 0600 inside the existing owner-only runtime directory.
Preserve this file during builds. `ZWIFTSHIFT_HOME` changes the runtime location.

The key starts in the URL fragment, which HTTP does not send to the server. The
page saves it in browser local storage, removes the fragment from the visible
URL, then authenticates API requests with an Authorization header. **Reset links**
immediately invalidates old keys. Open a newly copied link after a reset. An
already accepted shift may finish; reset does not undo a physical input.

Anyone with the private link can shift. Do not commit or publish the key, QR,
private link, or ngrok credentials. CLI status reports only base addresses.
The endpoint does not expose account data, raw logs, arbitrary files, or the full
local RPC interface. It uses no cookies, third-party scripts, or CORS grants.
Browser and proxy responses are marked `no-store`; the ngrok traffic inspector
is disabled. Ngrok still transports the authorized requests as its HTTPS proxy.

## HTTP interface

All API requests use HTTP/1.1 and `Authorization: Bearer <key>`. When sending
requests through ngrok, also send `ngrok-skip-browser-warning: 1`. The page and
bundled `/app.js`, `/app.css`, and `/favicon.svg` are readable without a key.

| Request | Result |
| --- | --- |
| `GET /api/status` | `canShift`, `busy`, observed `gear`, optional `gearCount`, `connection`, `trainerReady`, `repeatMilliseconds`, `serverTime` |
| `POST /api/shift` | One shared-core press; response includes `ok`, `confirmed`, `message`, and updated `state` |

`serverTime` is Unix milliseconds. A shift JSON body is:

```json
{"id":"a64ea0604db64d40af7155ae20b13a5b","direction":"up","expiresAt":1794250002000}
```

Generate a fresh hexadecimal ID of 16–64 characters (hyphens are allowed).
Set `expiresAt` relative to a
fresh server status. It must be in the future and no more than 5000 ms ahead.
The supplied page uses a two-second lifetime, accounting for elapsed local time.
Direction must be `up` or `down`; the phone API deliberately has no count/hold
command. Send the next press only after the previous result.

Completed duplicate IDs return their cached response for 30 seconds and do not
send another press. Reusing an in-progress ID or changing its direction returns
409. An expired command is rejected. The cache is bounded to 256 entries; accepted
new commands are limited to eight per second. Invalid authentication returns
401, a mismatched Origin 403, invalid input 400, expired/conflicting commands
409, and rate/capacity rejection 429. A 200 shift response can still have
`ok: false` or `confirmed: false`; check the JSON and actual gear before acting.

Framing rejects duplicate headers, chunked request bodies, pipelining, and
oversized requests. Header/body limits are 8 KiB/2 KiB. There are at most 24
concurrent connections, with five-second read/write deadlines and an
eight-second handler deadline. The server closes each connection after one
response. The shared `ShiftService` rejects overlapping actions and confirms
fresh game-log changes. There is only one shifting implementation.

## Verification

```sh
swift test
node --test Tests/phone-controls.test.mjs
# Only when it is appropriate to change actual gears in a free ride:
python3 Scripts/phone_acceptance.py --live --require-trainer
# If Internet access is intentionally off:
python3 Scripts/phone_acceptance.py --live --require-trainer --local-only
```

The live script checks authentication, expiry, Origin, one upshift, duplicate
suppression, and one downshift for each selected transport. It independently
checks fresh Zwift log transitions and returns to the starting gear on success.
Do not use other controls while it runs. Evidence is saved under `build/phone-live-*`
without private links or keys.

Current evidence: **28 Swift tests and 4 browser-scheduler tests passed**. Real
local and public HTTPS requests authenticated correctly, and the public page
rendered with live observed gear. Normal quit and an idle app-crash test left no
ngrok/helper process behind. The initial scripted live run stopped at preflight
because the game was at its upper gear limit; it sent no commands. Further live
phone tests were paused to diagnose the user's zero-watt report. Physical-phone,
cellular, and sustained-riding checks are not yet claimed as verified. See
[acceptance evidence](ACCEPTANCE.md) and [KICKR power investigation](KICKR_POWER.md).
