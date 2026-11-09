#!/usr/bin/env python3
"""Verify phone HTTP controls against fresh Zwift game-log transitions.

Requires the running app and a free ride. Sends one up/down pair over the LAN
and another through ngrok. Authentication, expiry, and replay checks must not
produce additional gear changes. Never writes private links into the evidence.
"""

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG = Path.home() / "Documents/Zwift/Logs/Log.txt"
SHIFT = re.compile(r"Gearing: Shift (\d+)-\((\d+) -> (\d+)\)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="required: authorize real gear changes")
    parser.add_argument("--require-trainer", action="store_true")
    parser.add_argument("--local-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.live:
        parser.error("Pass --live when Zwift is in a free ride and it is appropriate to shift.")
    output = args.output or ROOT / "build" / ("phone-live-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
    output.mkdir(parents=True, exist_ok=False)
    runtime = Path(os.environ.get("ZWIFTSHIFT_HOME", ROOT / "build/runtime"))
    token = json.loads((runtime / "phone.json").read_text())["token"]
    rows = []

    def status():
        return json.loads(subprocess.check_output([ROOT / "build/zwiftshift", "status", "--json"], timeout=8))["status"]

    def trainer_ready(state):
        return state["virtualShiftingEnabled"] and not state["controllerAsPowerSource"]

    def request(base, path, body=None, auth=True, origin=None):
        headers = {"ngrok-skip-browser-warning": "1"}
        if auth:
            headers["Authorization"] = "Bearer " + token
        if origin:
            headers["Origin"] = origin
        if body is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(base + path, json.dumps(body).encode() if body is not None else None, headers)
        try:
            response = urllib.request.urlopen(req, timeout=8)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

    def command(base, direction, expired=False):
        code, state = request(base, "api/status")
        if code != 200:
            raise RuntimeError("Cannot read the authenticated phone status.")
        return {"id": uuid.uuid4().hex, "direction": direction,
                "expiresAt": state["serverTime"] + (-1000 if expired else 2000)}

    initial = status()
    gear = initial.get("gear")
    if initial["state"] != "connected" or not initial["paired"] or not gear or initial["busy"]:
        raise RuntimeError("Open ZwiftShift, pair Controls, and enter a free ride first.")
    if args.require_trainer and not trainer_ready(initial):
        raise RuntimeError("Keep the actual trainer under Power/Resistance and enable virtual shifting.")
    if gear.get("frontCount") != 1 or gear["rear"] < 2 or gear["rear"] >= gear.get("rearCount", 0):
        raise RuntimeError("Choose a single-chainring gear away from the limits.")
    phone = initial.get("phone", {})
    targets = [("local-network", phone["localURLs"][0])]
    if not args.local_only:
        if not phone.get("publicURL"):
            raise RuntimeError("Wait for ngrok to connect, or use --local-only.")
        targets.append(("ngrok-https", phone["publicURL"]))

    def case(name, operation, expected_http, delta=0, confirmed=None):
        before = status()
        offset = LOG.stat().st_size
        stamp = dt.datetime.now().astimezone().isoformat()
        code, response = operation()
        time.sleep(0.6)
        after = status()
        time.sleep(0.5)
        stable = status()
        with LOG.open("rb") as stream:
            stream.seek(offset)
            lines = [line for line in stream.read().decode(errors="replace").splitlines() if SHIFT.search(line)]
        changes = [tuple(map(int, SHIFT.search(line).groups())) for line in lines]
        readiness = all(trainer_ready(s) for s in (before, after, stable))
        passed = (
            code == expected_http
            and len(changes) == abs(delta)
            and all(new - old == delta for _, old, new in changes)
            and after.get("gear", {}).get("rear") == before["gear"]["rear"] + delta
            and stable.get("gear", {}).get("rear") == after.get("gear", {}).get("rear")
            and stable["sentPresses"] - before["sentPresses"] == abs(delta)
            and not stable["busy"]
            and (confirmed is None or response.get("confirmed") == confirmed)
            and (not args.require_trainer or readiness)
        )
        row = {"test": name, "time": stamp, "passed": passed, "http": code,
               "before": before["gear"]["rear"], "after": after.get("gear", {}).get("rear"),
               "stable_after_release": stable.get("gear", {}).get("rear"),
               "expected_changes": abs(delta), "fresh_game_log": lines,
               "confirmed": response.get("confirmed"), "trainer_ready": readiness}
        rows.append(row)
        (output / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
        print(f'{"PASS" if passed else "FAIL"} {name}: {row["before"]} → {row["after"]}', flush=True)
        if not passed:
            raise RuntimeError(f"{name} failed. No retry attempted. Evidence: {output}")

    (output / "environment.json").write_text(json.dumps({
        "time": dt.datetime.now().astimezone().isoformat(), "initial_gear": gear["rear"],
        "repeat_ms": initial["settings"]["repeatMilliseconds"],
        "require_trainer": args.require_trainer,
        "scope": "Real game transitions via HTTP; does not measure resistance or use a physical phone.",
    }, indent=2) + "\n")
    for transport, base in targets:
        case(transport + "-unauthorized", lambda base=base: request(base, "api/shift", command(base, "up"), auth=False), 401)
        case(transport + "-expired", lambda base=base: request(base, "api/shift", command(base, "up", expired=True)), 409)
        case(transport + "-cross-origin", lambda base=base: request(base, "api/shift", command(base, "up"), origin="https://example.invalid"), 403)
        up = command(base, "up")
        case(transport + "-up", lambda base=base, up=up: request(base, "api/shift", up), 200, 1, True)
        case(transport + "-duplicate", lambda base=base, up=up: request(base, "api/shift", up), 200, 0, True)
        case(transport + "-down", lambda base=base: request(base, "api/shift", command(base, "down")), 200, -1, True)
    if status().get("gear", {}).get("rear") != gear["rear"]:
        raise RuntimeError("Final gear differs from the starting gear.")
    print(f"All {len(rows)} phone cases passed. Evidence: {output}")


if __name__ == "__main__":
    main()
