import json
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

from db import mongo_db

SETTINGS = Path.home() / "Library" / "Application Support" / "ZwiftShift" / "settings.json"


def status_url():
    port = 54872
    try:
        port = json.loads(SETTINGS.read_text()).get("networkPort", port)
    except Exception:
        pass
    return f"http://127.0.0.1:{port}/api/status"


def run(poll_s=1.0):
    db = mongo_db()
    url = status_url()
    print(f"streaming {url} -> mongo telemetry (ctrl-c to stop)")
    n = 0
    try:
        while True:
            doc = {
                "source": "telemetry",
                "ts": datetime.now(timezone.utc),
            }
            try:
                r = requests.get(url, timeout=2)
                doc["ok"] = r.ok
                try:
                    doc["payload"] = r.json()
                except ValueError:
                    doc["payload"] = {"raw": r.text[:2000]}
            except requests.RequestException as e:
                doc["ok"] = False
                doc["error"] = str(e)
            db.telemetry.insert_one(doc)
            n += 1
            time.sleep(poll_s)
    except KeyboardInterrupt:
        print(f"\n{n} samples written")


if __name__ == "__main__":
    run()
