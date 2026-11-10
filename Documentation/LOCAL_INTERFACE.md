# Local app / CLI interface

The desktop application and `zwiftshift serve` expose the same current-user Unix
socket at `~/Library/Application Support/ZwiftShift/control.sock` by default.
The directory is mode 0700, socket 0600;
the server checks the peer UID. `flock(service.lock)` prevents duplicate services.
It refuses to replace a regular file masquerading as its socket.

`ZWIFTSHIFT_HOME=/absolute/path` overrides the runtime directory. App and CLI must
use the same directory. Keep it short enough for macOS's Unix-socket path limit.
Installed symlinks resolve to the project's shared runtime directory.

Each connection accepts **one UTF-8 JSON line** and returns **one JSON line**,
then closes. Maximum request size is 8 KiB, response reader limit 128 KiB.
Incomplete requests and stalled writes time out after five seconds. Shift
processing is bounded by 100 shifts at a maximum two-second interval plus a
2.5-second feedback window; the CLI waits at most 210 seconds.

## Requests

```json
{"command":"status"}
{"command":"diagnostics"}
{"command":"shift","direction":"up","count":5}
{"command":"shift","direction":"down","count":1}
```

`count` defaults to 1 and must be 1–100. Only `up` and `down` are accepted.
`settings` accepts a complete validated settings object copied from status:

```text
{"command":"settings","settings":{...complete settings object...}}
```

The status field `controllerAsPowerSource` reports whether Zwift selected this
software controller for Power Source. This is a pairing mistake once discovery
is complete; select the real trainer for power and resistance. It is independent
of controller connectivity and `virtualShiftingEnabled`.

Controls/repeat settings may change while running; an active hold is cancelled
when settings change. Device identity and listening port require a service restart
and cannot be changed through the live settings command.

## Responses

```json
{
  "ok": true,
  "confirmed": true,
  "message": "Confirmed 1 up shift in Zwift. Gear 9.",
  "status": { "state": "connected", "gear": { "rear": 9 } }
}
```

This example abbreviates `status`. The actual status also includes process
detection, Controls pairing, ready client count, backend, observed gear dimensions
and observation time, settings, busy state, sent-press count, observed-change
count, and up to 100 events. Dates use ISO 8601.

`confirmed` applies to shift requests. A successful status read has `ok: true`
and `confirmed: false`. A rejected/unconfirmed shift has `ok: false`, a reason,
and no fabricated gear increment. The CLI maps this to exit code 2; transport or
usage errors use 1. A shift already in progress rejects another request.

## Example client

```python
import json, pathlib, socket

path = pathlib.Path.home() / "Library/Application Support/ZwiftShift/control.sock"
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(210)
    client.connect(str(path))
    client.sendall(b'{"command":"shift","direction":"up","count":1}\n')
    with client.makefile("r") as response:
        print(json.loads(response.readline(131072)))
```

The RPC interface is a control interface, not a second shifting implementation.
Wire encoding and controller lifecycle remain in `ZwiftShiftCore`.
