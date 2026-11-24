import argparse
import io
import struct
from datetime import datetime, timezone
from pathlib import Path

from garmin_fit_sdk import Decoder, Stream

from db import mongo_db

FIT_DIR = Path.home() / "Documents" / "Zwift" / "Activities"

SESSION_FIELDS = {
    "sport", "start_time", "total_elapsed_time", "total_timer_time",
    "total_distance", "avg_power", "max_power", "avg_heart_rate",
    "max_heart_rate", "avg_cadence", "max_cadence", "avg_speed",
    "max_speed", "total_ascent", "total_calories",
}
RECORD_FIELDS = {
    "timestamp", "power", "cadence", "heart_rate", "speed", "enhanced_speed",
    "altitude", "enhanced_altitude", "distance", "position_lat", "position_long",
}


def patch_data_size(path):
    data = path.read_bytes()
    if len(data) < 14 or data[8:12] != b".FIT":
        return None
    header_size = data[0]
    declared = struct.unpack("<I", data[4:8])[0]
    actual = len(data) - header_size - 2
    if declared == actual:
        return None
    fixed = bytearray(data)
    fixed[4:8] = struct.pack("<I", max(actual, 0))
    return bytes(fixed)


def pick(msg, fields):
    return {k: v for k, v in msg.items() if k in fields and v is not None}


def parse(path):
    patched = patch_data_size(path)
    if patched is not None:
        stream = Stream.from_bytes_io(io.BytesIO(patched))
    else:
        stream = Stream.from_file(str(path))
    messages, errors = Decoder(stream).read(enable_crc_check=False)
    sessions = messages.get("session_mesgs") or []
    session = pick(sessions[-1], SESSION_FIELDS) if sessions else {}
    laps = [pick(m, SESSION_FIELDS) for m in messages.get("lap_mesgs") or []]
    records = [pick(m, RECORD_FIELDS)
               for m in messages.get("record_mesgs") or []]
    return session, laps, records, [str(e) for e in errors]


def load(fit_dir=FIT_DIR, dry_run=False):
    db = mongo_db()
    loaded = already = skipped = 0
    for path in sorted(fit_dir.glob("*.fit")):
        session, laps, records, errors = parse(path)
        if not records and not session:
            print(f"skip   {path.name}: no usable messages")
            skipped += 1
            continue
        exists = db.activities.find_one({"filename": path.name}, {"_id": 1})
        if dry_run:
            tag = "would-update" if exists else "would-load"
            print(f"{tag} {path.name}: {len(records)} records, "
                  f"{len(laps)} laps, errors={len(errors)}")
            continue
        doc = {
            "source": "fit",
            "filename": path.name,
            "ingested_at": datetime.now(timezone.utc),
            "file_bytes": path.stat().st_size,
            "session": session,
            "laps": laps,
            "records": records,
            "decode_errors": errors,
        }
        if exists:
            db.activities.replace_one({"_id": exists["_id"]}, doc)
            already += 1
            print(f"update {path.name}: {len(records)} records"
                  + (f" ({len(errors)} decode errors)" if errors else ""))
        else:
            db.activities.insert_one(doc)
            loaded += 1
            print(f"load   {path.name}: {len(records)} records"
                  + (f" ({len(errors)} decode errors)" if errors else ""))
    print(f"\n{loaded} loaded, {already} refreshed, {skipped} skipped "
          f"({db.activities.count_documents({})} total in mongo)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, default=FIT_DIR)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    load(args.dir, args.dry_run)
