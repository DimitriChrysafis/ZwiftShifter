#!/usr/bin/env python3
"""Explicit, bounded acceptance test against the real running Zwift game.

This changes gears. It never creates power data, edits Zwift, or uploads a ride.
The evidence comes from fresh game-log lines, independently of the CLI reply.
"""

import argparse
import datetime as dt
import json
import pathlib
import re
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOG = pathlib.Path.home() / "Documents/Zwift/Logs/Log.txt"
GEAR_SHIFT = re.compile(r"Gearing: Shift (\d+)-\((\d+) -> (\d+)\)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="required: explicitly run real gear changes")
    parser.add_argument("--desktop-tests", action="store_true", help="also click app buttons and exercise default shortcuts")
    parser.add_argument("--shortcut-tests", action="store_true", help="exercise default shortcuts without moving the mouse")
    parser.add_argument("--screenshots", action="store_true", help="save only Zwift and ZwiftShift windows in the evidence folder")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    if not args.live:
        parser.error("Pass --live when Zwift is in a free ride and it is appropriate to change gears.")

    cli = ROOT / "build/zwiftshift"
    helper = ROOT / "build/desktop_probe"
    output = args.output or ROOT / "build" / ("live-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
    output.mkdir(parents=True, exist_ok=False)
    rows = []

    def status():
        return json.loads(subprocess.check_output([cli, "status", "--json"], timeout=8))["status"]

    def windows():
        return [json.loads(x) for x in subprocess.check_output([helper, "windows", "Zwift"], text=True, timeout=5).splitlines()]

    def capture(label):
        if args.screenshots:
            for window in windows():
                owner = window["kCGWindowOwnerName"]
                if owner not in ("ZwiftShift", "ZwiftAppSilicon", "ZwiftApp"):
                    continue
                target = output / f"{label}-{owner}.png"
                subprocess.run(["screencapture", "-x", "-o", f'-l{window["kCGWindowNumber"]}', str(target)], check=True, timeout=5)

    def run_case(name, direction, expected, command, hold_ms=None):
        before = status()
        offset = LOG.stat().st_size
        started = dt.datetime.now().astimezone().isoformat()
        result = subprocess.run(command, check=False, capture_output=True, text=True, timeout=30)
        time.sleep(0.7)
        after = status()
        time.sleep(0.5)
        stable = status()
        with LOG.open(errors="replace") as stream:
            stream.seek(offset)
            lines = [line.strip() for line in stream if GEAR_SHIFT.search(line)]
        changes = [tuple(map(int, GEAR_SHIFT.search(line).groups())) for line in lines]
        sign = 1 if direction == "up" else -1
        matching = [change for change in changes if change[2] - change[1] == sign]
        passed = (
            result.returncode == 0
            and len(changes) == len(matching) == expected
            and after["gear"]["rear"] - before["gear"]["rear"] == sign * expected
            and stable["gear"]["rear"] == after["gear"]["rear"]
            and not stable["busy"]
        )
        row = {"test": name, "time": started, "passed": passed, "expected_changes": expected,
               "before": before["gear"]["rear"], "after": after["gear"]["rear"],
               "stable_after_release": stable["gear"]["rear"], "game_log": lines,
               "hold_ms": hold_ms, "command_exit": result.returncode}
        rows.append(row)
        (output / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
        print(f'{"PASS" if passed else "FAIL"} {name}: {row["before"]} → {row["after"]}; {len(changes)} game-log changes', flush=True)
        capture(name)
        if not passed:
            raise RuntimeError(f"{name} failed. Evidence: {output}. No automatic retry was attempted.")

    initial = status()
    if initial["state"] != "connected" or not initial["paired"] or not initial.get("gear"):
        raise RuntimeError("Pair the controller and enter a free ride before running this check.")
    gear = initial["gear"]
    if gear.get("frontCount") != 1 or gear["rear"] <= 5 or gear.get("rearCount", 0) - gear["rear"] < 5:
        raise RuntimeError("Choose a single-chainring gear at least five steps from both ends for this symmetric test.")
    (output / "environment.json").write_text(json.dumps({
        "time": dt.datetime.now().astimezone().isoformat(), "initial_gear": gear,
        "virtual_shifting_reported_by_zwift": initial["virtualShiftingEnabled"],
        "repeat_ms": initial["settings"]["repeatMilliseconds"],
        "scope": "Actual game gear transitions; physical trainer resistance is not measured by this script."
    }, indent=2) + "\n")
    if args.desktop_tests or args.shortcut_tests or args.screenshots:
        subprocess.run(["swiftc", str(ROOT / "Experiments/input/desktop_probe.swift"), "-o", str(helper)], check=True, timeout=40)
    capture("baseline")
    for direction, count in [("up", 1), ("down", 1), ("up", 5), ("down", 5)]:
        run_case(f"cli-{direction}-{count}", direction, count, [str(cli), direction, "--count", str(count)])

    if args.desktop_tests or args.shortcut_tests:
        settings = initial["settings"]
        for direction, key in [("up", 126), ("down", 125)]:
            shortcut = settings[f"{direction}Shortcut"]
            if shortcut != {"keyCode": key, "control": True, "option": True, "command": False, "shift": False}:
                raise RuntimeError("Desktop acceptance currently requires the default Control–Option–arrow shortcuts.")
        if not settings["shortcutsEnabled"]:
            raise RuntimeError("Enable shortcuts before desktop acceptance.")
        interval = settings["repeatMilliseconds"]
        hold_ms = interval * 3 + 150
        if hold_ms > 5000:
            raise RuntimeError("Use a repeat interval below 1600 ms for this bounded desktop test.")
        if args.desktop_tests:
            app = next((w for w in windows() if w["kCGWindowOwnerName"] == "ZwiftShift"), None)
            if app is None:
                raise RuntimeError("Open the ZwiftShift dashboard for mouse tests; close its settings sheet.")
            bounds = app["kCGWindowBounds"]
            if bounds["Width"] != 880 or bounds["Height"] != 710:
                raise RuntimeError("Desktop acceptance expects the default 880 × 710 dashboard window.")
            for held in (False, True):
                for direction, dx in [("up", 648), ("down", 231)]:
                    ms = hold_ms if held else 80
                    command = [str(helper), "click-app", str(app["kCGWindowOwnerPID"]),
                               str(bounds["X"] + dx), str(bounds["Y"] + 428), str(ms)]
                    run_case(f'mouse-{"hold" if held else "tap"}-{direction}', direction, 4 if held else 1, command, ms)
        for held in (False, True):
            for direction, key in [("up", 126), ("down", 125)]:
                ms = hold_ms if held else 80
                run_case(f'shortcut-{"hold" if held else "tap"}-{direction}', direction, 4 if held else 1,
                         [str(helper), "chord", str(key), str(ms)], ms)
    final = status()
    if final["gear"]["rear"] != gear["rear"]:
        raise RuntimeError("Final observed gear differs from the starting gear.")
    print(f"All {len(rows)} live cases passed. Evidence: {output}")


if __name__ == "__main__":
    main()
