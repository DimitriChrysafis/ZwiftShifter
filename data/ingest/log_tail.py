from datetime import datetime, timezone
from pathlib import Path

from db import mongo_db

LOG_FILE = Path.home() / "Documents" / "Zwift" / "Logs" / "Log.txt"


def run(log_file=LOG_FILE):
    db = mongo_db()
    meta = db.meta.find_one({"_id": "zwift_log_offset"}) or {}
    offset = meta.get("offset", 0)
    size = log_file.stat().st_size
    if offset > size:
        offset = 0
    n = 0
    with log_file.open("r", errors="replace") as f:
        f.seek(offset)
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            db.zwift_log.insert_one({
                "source": "zwift_log",
                "file": log_file.name,
                "line": line,
                "ingested_at": datetime.now(timezone.utc),
            })
            n += 1
        offset = f.tell()
    db.meta.update_one(
        {"_id": "zwift_log_offset"},
        {"$set": {"offset": offset}},
        upsert=True,
    )
    print(f"ingested {n} new lines (offset {offset}, "
          f"{db.zwift_log.count_documents({})} total)")


if __name__ == "__main__":
    run()
