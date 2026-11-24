from elasticsearch.helpers import bulk

from db import es, mongo_db


def naive(ts):
    return ts.replace(tzinfo=None) if ts and ts.tzinfo else ts


def log_actions(db):
    for d in db.zwift_log.find():
        yield {
            "_index": "zwift-logs",
            "_id": str(d["_id"]),
            "file": d["file"],
            "line": d["line"],
            "ingested_at": naive(d["ingested_at"]).isoformat(),
        }


def workout_actions(db):
    for d in db.activities.find():
        s = d.get("session") or {}
        start = s.get("start_time")
        dist = s.get("total_distance")
        km = f"{dist/1000:.1f}" if dist else "0.0"
        doc = {
            "filename": d["filename"],
            "sport": s.get("sport"),
            "start_time": naive(start).isoformat() if start else None,
            "distance_m": dist,
            "elapsed_s": s.get("total_elapsed_time"),
            "avg_power": s.get("avg_power"),
            "max_power": s.get("max_power"),
            "avg_hr": s.get("avg_heart_rate"),
            "text": (f"{s.get('sport') or 'ride'} on "
                     f"{naive(start)} {km} km avg "
                     f"{s.get('avg_power')} W"),
        }
        yield {"_index": "workouts", "_id": str(d["_id"]), **doc}


def run():
    db = mongo_db()
    client = es()
    ok, errs = bulk(client, log_actions(db))
    print(f"zwift-logs: {ok} indexed")
    ok, errs = bulk(client, workout_actions(db))
    print(f"workouts: {ok} indexed")


if __name__ == "__main__":
    run()
