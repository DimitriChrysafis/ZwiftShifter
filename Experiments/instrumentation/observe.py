"""Bounded read-only tracing; always unload and detach on exit."""
import argparse
import json
import time
from pathlib import Path

import frida

parser = argparse.ArgumentParser()
parser.add_argument("--pid", type=int, required=True)
parser.add_argument("--script", type=Path, required=True)
parser.add_argument("--seconds", type=float, default=15)
args = parser.parse_args()
session = frida.attach(args.pid)
script = session.create_script(args.script.read_text())
script.on("message", lambda message, data: print(json.dumps(message), flush=True))
try:
    script.load()
    time.sleep(args.seconds)
finally:
    script.unload()
    session.detach()
    print(json.dumps({"event": "detached"}), flush=True)
