"""Attach temporarily, observe one explicit mouse click, then detach."""
import json
import subprocess
import time
from pathlib import Path

import frida

pid = int(subprocess.check_output(["pgrep", "-x", "ZwiftAppSilicon"]))
session = frida.attach(pid)
try:
    script = session.create_script(Path("Experiments/input/trace_events.js").read_text())
    script.on("message", lambda message, data: print(json.dumps(message), flush=True))
    script.load()
    subprocess.run(["build/desktop_probe", "click", "980", "107"], check=True)
    time.sleep(1)
finally:
    session.detach()
