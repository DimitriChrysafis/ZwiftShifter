from datetime import datetime

from db import mongo_db, mysql_conn

DDL = [
    """
    create table if not exists activities (
        id varchar(32) not null primary key,
        filename varchar(128) not null unique,
        sport varchar(32),
        start_time datetime,
        elapsed_s double,
        timer_s double,
        distance_m double,
        avg_power int,
        max_power int,
        norm_power int,
        avg_hr int,
        max_hr int,
        avg_cadence int,
        max_cadence int,
        avg_speed_mps double,
        max_speed_mps double,
        ascent_m int,
        calories int,
        n_records int,
        loaded_at datetime
    )
    """,
    """
    create table if not exists records (
        activity_id varchar(32) not null,
        ts datetime not null,
        t_offset_s int,
        power int,
        cadence int,
        heart_rate int,
        speed_mps double,
        altitude_m double,
        distance_m double,
        lat double,
        lon double,
        primary key (activity_id, ts)
    )
    """,
]

ACT_COLS = [
    "id", "filename", "sport", "start_time", "elapsed_s", "timer_s",
    "distance_m", "avg_power", "max_power", "norm_power", "avg_hr",
    "max_hr", "avg_cadence", "max_cadence", "avg_speed_mps",
    "max_speed_mps", "ascent_m", "calories", "n_records", "loaded_at",
]


def naive(ts):
    return ts.replace(tzinfo=None) if ts and ts.tzinfo else ts


def activity_row(doc):
    s = doc.get("session") or {}
    recs = doc.get("records") or []
    ts = [r["timestamp"] for r in recs if r.get("timestamp")]
    powers = [r["power"] for r in recs if r.get("power") is not None]
    dists = [r["distance"] for r in recs if r.get("distance") is not None]
    return {
        "id": str(doc["_id"]),
        "filename": doc["filename"],
        "sport": s.get("sport"),
        "start_time": naive(s.get("start_time")) or (naive(min(ts)) if ts else None),
        "elapsed_s": s.get("total_elapsed_time")
            or ((max(ts) - min(ts)).total_seconds() if len(ts) > 1 else None),
        "timer_s": s.get("total_timer_time"),
        "distance_m": s.get("total_distance") or (dists[-1] if dists else None),
        "avg_power": s.get("avg_power")
            or (round(sum(powers) / len(powers)) if powers else None),
        "max_power": s.get("max_power") or (max(powers) if powers else None),
        "norm_power": None,
        "avg_hr": s.get("avg_heart_rate"),
        "max_hr": s.get("max_heart_rate"),
        "avg_cadence": s.get("avg_cadence"),
        "max_cadence": s.get("max_cadence"),
        "avg_speed_mps": s.get("avg_speed"),
        "max_speed_mps": s.get("max_speed"),
        "ascent_m": s.get("total_ascent"),
        "calories": s.get("total_calories"),
        "n_records": len(recs),
        "loaded_at": datetime.now().replace(microsecond=0),
    }


def record_rows(activity_id, recs):
    timed = [r for r in recs if r.get("timestamp")]
    if not timed:
        return []
    t0 = timed[0]["timestamp"]
    rows = []
    for r in timed:
        ts = r["timestamp"]
        rows.append((
            activity_id,
            naive(ts),
            int((ts - t0).total_seconds()),
            r.get("power"),
            r.get("cadence"),
            r.get("heart_rate"),
            r.get("enhanced_speed") or r.get("speed"),
            r.get("enhanced_altitude") or r.get("altitude"),
            r.get("distance"),
            r.get("position_lat"),
            r.get("position_long"),
        ))
    return rows


def run():
    db = mongo_db()
    conn = mysql_conn()
    cur = conn.cursor()
    for ddl in DDL:
        cur.execute(ddl)
    n_act = n_rec = 0
    upsert = (
        f"replace into activities ({', '.join(ACT_COLS)}) "
        f"values ({', '.join(['%s'] * len(ACT_COLS))})"
    )
    ins_rec = (
        "insert into records (activity_id, ts, t_offset_s, power, cadence, "
        "heart_rate, speed_mps, altitude_m, distance_m, lat, lon) "
        "values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)"
    )
    for doc in db.activities.find():
        row = activity_row(doc)
        cur.execute(upsert, tuple(row[c] for c in ACT_COLS))
        cur.execute("delete from records where activity_id = %s", (row["id"],))
        rows = record_rows(row["id"], doc.get("records") or [])
        if rows:
            cur.executemany(ins_rec, rows)
        n_act += 1
        n_rec += len(rows)
    conn.commit()
    cur.execute("select count(*), coalesce(sum(distance_m),0), "
                "coalesce(sum(elapsed_s),0) from activities")
    n, dist, secs = cur.fetchone()
    cur.execute("select count(*) from records")
    total_rec = cur.fetchone()[0]
    conn.close()
    print(f"elt: upserted {n_act} activities, {n_rec} record rows")
    print(f"warehouse now: {n} rides, {dist/1000:.1f} km, "
          f"{secs/3600:.1f} h, {total_rec:,} records")


if __name__ == "__main__":
    run()
