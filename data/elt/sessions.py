import hashlib
from datetime import timedelta

SESSION_GAP_S = 300

SESSION_DDL = """
create table if not exists sessions (
    id varchar(40) not null primary key,
    start_time datetime,
    end_time datetime,
    wall_s double,
    moving_s double,
    distance_m double,
    avg_power int,
    max_power int,
    n_files int,
    n_records int,
    recovered_records int,
    primary_activity_id varchar(32),
    source_filenames text,
    quality_flags varchar(255),
    loaded_at datetime
)
"""

SESSION_COLS = [
    "id", "start_time", "end_time", "wall_s", "moving_s", "distance_m",
    "avg_power", "max_power", "n_files", "n_records", "recovered_records",
    "primary_activity_id", "source_filenames", "quality_flags", "loaded_at",
]


def naive(ts):
    return ts.replace(tzinfo=None) if ts and ts.tzinfo else ts


def doc_times(doc):
    s = doc.get("session") or {}
    recs = doc.get("records") or []
    ts = [r["timestamp"] for r in recs if r.get("timestamp")]
    start = naive(s.get("start_time")) or (naive(min(ts)) if ts else None)
    elapsed = s.get("total_elapsed_time")
    if elapsed is None and len(ts) > 1:
        elapsed = (max(ts) - min(ts)).total_seconds()
    end = start + timedelta(seconds=elapsed or 0) if start else None
    return start, end, elapsed or 0


def doc_distance(doc):
    s = doc.get("session") or {}
    if s.get("total_distance") is not None:
        return s.get("total_distance")
    dists = [r["distance"] for r in (doc.get("records") or [])
             if r.get("distance") is not None]
    return dists[-1] if dists else 0


def session_groups(docs, gap_s=SESSION_GAP_S):
    timed = []
    for doc in docs:
        start, end, _ = doc_times(doc)
        if start and end:
            timed.append((start, end, doc))
    timed.sort(key=lambda x: x[0])
    groups = []
    current = []
    current_end = None
    for start, end, doc in timed:
        if not current:
            current = [doc]
            current_end = end
            continue
        gap = (start - current_end).total_seconds()
        if gap <= gap_s:
            current.append(doc)
            current_end = max(current_end, end)
        else:
            groups.append(current)
            current = [doc]
            current_end = end
    if current:
        groups.append(current)
    return groups


def summarize_group(group, loaded_at):
    starts = []
    ends = []
    powers = []
    filenames = []
    moving_s = 0
    distance_m = 0
    n_records = 0
    recovered_records = 0
    primary = None
    primary_n = -1
    for doc in group:
        start, end, elapsed = doc_times(doc)
        starts.append(start)
        ends.append(end)
        moving_s += elapsed or 0
        distance_m += doc_distance(doc) or 0
        recs = [r for r in (doc.get("records") or []) if r.get("timestamp")]
        n_records += len(recs)
        if len(recs) > primary_n:
            primary_n = len(recs)
            primary = doc
        if doc.get("decode_errors"):
            recovered_records += len(recs)
        powers.extend(r["power"] for r in recs if r.get("power") is not None)
        filenames.append(doc["filename"])
    start = min(starts) if starts else None
    end = max(ends) if ends else None
    flags = []
    if len(group) > 1:
        flags.append("stitched")
    if recovered_records:
        flags.append("recovered")
    if moving_s < 600 or distance_m < 1000:
        flags.append("tiny_fragment")
    key = f"{filenames[0]}|{start.isoformat() if start else 'unknown'}"
    return {
        "id": hashlib.sha1(key.encode()).hexdigest()[:32],
        "start_time": start,
        "end_time": end,
        "wall_s": (end - start).total_seconds() if start and end else None,
        "moving_s": moving_s,
        "distance_m": distance_m,
        "avg_power": round(sum(powers) / len(powers)) if powers else None,
        "max_power": max(powers) if powers else None,
        "n_files": len(group),
        "n_records": n_records,
        "recovered_records": recovered_records,
        "primary_activity_id": str(primary["_id"]) if primary else None,
        "source_filenames": "\n".join(filenames),
        "quality_flags": ",".join(flags),
        "loaded_at": loaded_at,
    }


def rebuild_sessions(cur, docs, loaded_at):
    cur.execute(SESSION_DDL)
    cur.execute(
        "select count(*) from information_schema.columns "
        "where table_schema = database() and table_name = 'activities' "
        "and column_name = 'session_id'"
    )
    if cur.fetchone()[0] == 0:
        cur.execute("alter table activities add column session_id varchar(40) null")
    groups = session_groups(docs)
    rows = [summarize_group(g, loaded_at) for g in groups]
    ids = [r["id"] for r in rows]
    if ids:
        marks = ", ".join(["%s"] * len(ids))
        cur.execute(f"select id from sessions where id not in ({marks})", ids)
    else:
        cur.execute("select id from sessions")
    stale = [r[0] for r in cur.fetchall()]
    for sid in stale:
        cur.execute("delete from sessions where id = %s", (sid,))
    sql = (
        f"replace into sessions ({', '.join(SESSION_COLS)}) "
        f"values ({', '.join(['%s'] * len(SESSION_COLS))})"
    )
    for row in rows:
        cur.execute(sql, tuple(row[c] for c in SESSION_COLS))
    for row, group in zip(rows, groups):
        for doc in group:
            cur.execute(
                "update activities set session_id = %s where id = %s",
                (row["id"], str(doc["_id"])),
            )
    return rows, len(stale)
